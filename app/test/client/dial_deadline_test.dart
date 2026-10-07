// The dial deadline: a socket factory that never completes must not hang the
// client forever, and a dial the user has superseded must be disposed rather
// than orphaned. The scheduler is injected, so the deadline is fired by the
// test and nothing ever sleeps.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/hub_client.dart';
import 'package:pi_handset/client/hub_socket.dart';

import 'support/fakes.dart';

const String testToken =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  late FakeSocketFactory factory;
  late FakeScheduler scheduler;
  late HubClient client;

  setUp(() {
    factory = FakeSocketFactory();
    scheduler = FakeScheduler();
    client = HubClient(
      socketFactory: factory.call,
      scheduler: scheduler,
      tokenStore: InMemoryTokenStore(initial: testToken),
      rng: () => 0.5,
    );
  });

  test('start closes the live socket a new attempt displaces', () async {
    // First attempt: a live, authenticating socket.
    await client.start('10.0.0.9');
    await pumpEventQueue();
    final displaced = factory.last;
    expect(client.state.status, HubConnectionStatus.authenticating);
    expect(displaced.closedByClient, isFalse);

    // A re-submit. The second dial is held open, so the disposal is the only
    // thing that can close the displaced socket.
    final held = Completer<HubSocket>();
    factory.onDialFuture = (_) => held.future;
    unawaited(client.start('10.0.0.9'));
    await pumpEventQueue();

    // The hub has no idle reaper, so an orphaned socket leaks on both sides.
    expect(displaced.closedByClient, isTrue);

    // The new socket is adopted, never closed.
    final fresh = FakeHubSocket();
    held.complete(fresh);
    await pumpEventQueue();
    expect(fresh.closedByClient, isFalse);
    expect(fresh.lastSent['type'], 'hello');
  });

  test(
    'a dial that never completes fails after the deadline, naming the endpoint',
    () async {
      factory.onDialFuture = (_) => Completer<HubSocket>().future;
      unawaited(client.start('10.0.0.9'));
      await pumpEventQueue();

      expect(scheduler.connectTimers, hasLength(1));
      expect(scheduler.connectTimers.single.delay, const Duration(seconds: 10));

      scheduler.fireConnectDeadline();
      await pumpEventQueue();

      expect(client.state.lastError, contains('10.0.0.9:8787'));
      expect(client.state.lastError, contains('within 10 seconds'));
      expect(client.state.status, HubConnectionStatus.connecting);
      expect(scheduler.reconnectTimers, isNotEmpty);
    },
  );

  test('a socket arriving after the deadline is closed and never used', () async {
    final held = Completer<HubSocket>();
    factory.onDialFuture = (_) => held.future;
    unawaited(client.start('10.0.0.9'));
    await pumpEventQueue();

    scheduler.fireConnectDeadline();
    await pumpEventQueue();
    expect(client.state.lastError, isNotNull);

    final late = FakeHubSocket();
    held.complete(late);
    await pumpEventQueue();

    expect(late.closedByClient, isTrue);
    expect(late.sent, isEmpty);
  });

  test('a superseded dial cannot clobber a newer, connected client', () async {
    final dials = <Completer<HubSocket>>[];
    factory.onDialFuture = (_) {
      final completer = Completer<HubSocket>();
      dials.add(completer);
      return completer.future;
    };

    unawaited(client.start('10.0.0.9'));
    await pumpEventQueue();
    unawaited(client.start('10.0.0.9'));
    await pumpEventQueue();
    expect(dials, hasLength(2));

    // The current dial wins and authenticates.
    final fresh = FakeHubSocket();
    dials[1].complete(fresh);
    await pumpEventQueue();
    fresh.receive({'protocolVersion': 1, 'type': 'sessions', 'sessions': <Object?>[]});
    await pumpEventQueue();
    expect(client.state.status, HubConnectionStatus.connected);

    // The stale dial finally produces a socket. It must be closed, never
    // adopted over the connected one.
    final stale = FakeHubSocket();
    dials[0].complete(stale);
    await pumpEventQueue();

    expect(stale.closedByClient, isTrue);
    expect(stale.sent, isEmpty);
    expect(fresh.closedByClient, isFalse);
    expect(client.state.status, HubConnectionStatus.connected);
  });

  test('stop cancels the connect deadline', () async {
    factory.onDialFuture = (_) => Completer<HubSocket>().future;
    unawaited(client.start('10.0.0.9'));
    await pumpEventQueue();
    final deadline = scheduler.connectTimers.single;

    await client.stop();

    expect(deadline.cancelled, isTrue);
    scheduler.fireConnectDeadline();
    await pumpEventQueue();
    expect(client.state.lastError, isNull);

    // A later attempt arms its own deadline; the stopped one must not still be
    // live to fire onto it.
    unawaited(client.start('10.0.0.9'));
    await pumpEventQueue();
    expect(scheduler.connectTimers.where((t) => !t.cancelled), hasLength(1));
  });

  test('disconnect cancels the connect deadline', () async {
    factory.onDialFuture = (_) => Completer<HubSocket>().future;
    unawaited(client.start('10.0.0.9'));
    await pumpEventQueue();
    final deadline = scheduler.connectTimers.single;

    await client.disconnect();

    expect(deadline.cancelled, isTrue);
    scheduler.fireConnectDeadline();
    await pumpEventQueue();
    expect(client.state.lastError, isNull);

    // As above: changing hub must leave no deadline armed for the old attempt.
    unawaited(client.start('10.0.0.9'));
    await pumpEventQueue();
    expect(scheduler.connectTimers.where((t) => !t.cancelled), hasLength(1));
  });

  test("a re-submit cancels the previous attempt's auth watchdog", () async {
    // First attempt: a live socket, authenticating, its watchdog armed.
    await client.start('10.0.0.9');
    await pumpEventQueue();
    expect(scheduler.authTimers, hasLength(1));
    final staleWatchdog = scheduler.authTimers.single;

    // Re-submit while the second dial is held open, so only `start()` can
    // cancel the stale watchdog. `_armAuthWatchdog` would cancel it too, but it
    // is never reached.
    final held = Completer<HubSocket>();
    factory.onDialFuture = (_) => held.future;
    unawaited(client.start('10.0.0.9'));
    await pumpEventQueue();

    expect(staleWatchdog.cancelled, isTrue);
    // Nothing is left armed for the displaced attempt. The second dial is still
    // pending, so `_armAuthWatchdog` has not run — only `start()` can have
    // cancelled it.
    expect(scheduler.authTimers.where((t) => !t.cancelled), isEmpty);

    // Even if it fired it must not report a spurious stale-token error.
    scheduler.fireAuthWatchdog();
    await pumpEventQueue();
    expect(client.state.lastError, isNull);

    // The fresh socket is adopted and left untouched.
    final fresh = FakeHubSocket();
    held.complete(fresh);
    await pumpEventQueue();
    expect(fresh.closedByClient, isFalse);
    expect(fresh.lastSent['type'], 'hello');
    expect(client.state.lastError, isNull);
  });
}
