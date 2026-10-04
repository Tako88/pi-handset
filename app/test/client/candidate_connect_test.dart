// The parallel candidate race: dial every stored candidate at once, adopt the
// first (or the preferred) socket that opens, and close every loser. The
// scheduler is injected, so every deadline is fired by the test and nothing
// ever sleeps.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/endpoint_store.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/client/hub_socket.dart';
import 'package:pi_droid/client/scheduler.dart';

import 'support/fakes.dart';

const String testToken =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

const HubEndpoint lan = HubEndpoint(host: '10.0.0.9', port: 8787);
const HubEndpoint ts = HubEndpoint(host: '100.64.0.1', port: 8787);
const HubEndpoint wan = HubEndpoint(host: '192.168.1.50', port: 8787);

/// A per-URL completer the test completes to make a dial answer. Keyed by
/// `host:port` so a test can address one candidate without relying on order.
Map<String, Completer<HubSocket>> holdingDials(FakeSocketFactory factory) {
  final dials = <String, Completer<HubSocket>>{};
  factory.onDialFuture = (url) {
    final completer = Completer<HubSocket>();
    dials['${url.host}:${url.port}'] = completer;
    return completer.future;
  };
  return dials;
}

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

  test('first answer wins and later losers are closed without a hello', () async {
    final dials = holdingDials(factory);
    unawaited(client.startCandidates([lan, ts]));
    await pumpEventQueue();
    expect(
      dials.keys,
      containsAll(<String>['10.0.0.9:8787', '100.64.0.1:8787']),
    );

    final lanSocket = FakeHubSocket();
    dials['10.0.0.9:8787']!.complete(lanSocket);
    await pumpEventQueue();

    expect(
      lanSocket.sentFrames.where((frame) => frame['type'] == 'hello'),
      hasLength(1),
    );
    expect(lanSocket.closedByClient, isFalse);

    final tsSocket = FakeHubSocket();
    dials['100.64.0.1:8787']!.complete(tsSocket);
    await pumpEventQueue();

    expect(tsSocket.closedByClient, isTrue);
    expect(tsSocket.sent, isEmpty);
    expect(lanSocket.closedByClient, isFalse);
  });

  test('an all-failed race names both addresses and re-races on reconnect', () async {
    factory.onDial = () => Exception('connection refused');

    await client.startCandidates([lan, ts]);

    expect(client.state.lastError, contains('10.0.0.9:8787'));
    expect(client.state.lastError, contains('100.64.0.1:8787'));
    expect(client.state.lastError, contains('within 2 seconds'));
    expect(factory.urls, hasLength(2));
    expect(scheduler.reconnectTimers, isNotEmpty);

    // The reconnect must fire a *reconnect* timer and dial the list again.
    scheduler.reconnectTimers.last.fire();
    await pumpEventQueue();

    expect(factory.urls, hasLength(4));
  });

  test("the winner's deadline is cancelled and its loser never dials on", () async {
    final dials = holdingDials(factory);
    unawaited(client.startCandidates([lan, ts]));
    await pumpEventQueue();

    final lanSocket = FakeHubSocket();
    dials['10.0.0.9:8787']!.complete(lanSocket);
    await pumpEventQueue();

    expect(scheduler.connectTimers, hasLength(2));
    // Dials are armed in list order: LAN first, tailnet second.
    expect(scheduler.connectTimers[0].cancelled, isTrue);
    expect(scheduler.connectTimers[1].cancelled, isFalse);
    expect(
      lanSocket.sentFrames.where((frame) => frame['type'] == 'hello'),
      hasLength(1),
    );

    // Firing the surviving loser deadline must not adopt anything or error.
    scheduler.fireConnectDeadline();
    await pumpEventQueue();

    expect(client.state.lastError, isNull);
    expect(client.state.status, HubConnectionStatus.authenticating);
  });

  test('a superseded race closes its sockets and adopts nothing', () async {
    final first = holdingDials(factory);
    unawaited(client.startCandidates([lan, ts]));
    await pumpEventQueue();

    final second = <String, Completer<HubSocket>>{};
    factory.onDialFuture = (url) {
      final completer = Completer<HubSocket>();
      second['${url.host}:${url.port}'] = completer;
      return completer.future;
    };
    unawaited(client.startCandidates([lan, ts]));
    await pumpEventQueue();
    expect(second.keys, hasLength(2));

    final staleLan = FakeHubSocket();
    final staleTs = FakeHubSocket();
    first['10.0.0.9:8787']!.complete(staleLan);
    first['100.64.0.1:8787']!.complete(staleTs);
    await pumpEventQueue();

    expect(staleLan.closedByClient, isTrue);
    expect(staleLan.sent, isEmpty);
    expect(staleTs.closedByClient, isTrue);
    expect(staleTs.sent, isEmpty);

    // The second race is unaffected.
    final liveLan = FakeHubSocket();
    second['10.0.0.9:8787']!.complete(liveLan);
    await pumpEventQueue();
    expect(
      liveLan.sentFrames.where((frame) => frame['type'] == 'hello'),
      hasLength(1),
    );
    expect(client.state.status, HubConnectionStatus.authenticating);
  });

  test('a reconnect re-races the stored candidate list', () async {
    await client.startCandidates([lan, ts]);
    expect(factory.urls, hasLength(2));
    expect(client.state.status, HubConnectionStatus.authenticating);

    factory.sockets.first.remoteClose(1001);
    await pumpEventQueue();
    expect(scheduler.reconnectTimers, isNotEmpty);

    scheduler.reconnectTimers.last.fire();
    await pumpEventQueue();

    expect(factory.urls, hasLength(4));
  });

  test('prefer adopts the preferred and closes a held non-preferred', () async {
    final dials = holdingDials(factory);
    unawaited(client.startCandidates([lan, ts], prefer: ts));
    await pumpEventQueue();

    final lanSocket = FakeHubSocket();
    dials['10.0.0.9:8787']!.complete(lanSocket);
    await pumpEventQueue();

    // Held: no hello, not closed, still waiting on the preferred candidate.
    expect(lanSocket.sent, isEmpty);
    expect(lanSocket.closedByClient, isFalse);

    final tsSocket = FakeHubSocket();
    dials['100.64.0.1:8787']!.complete(tsSocket);
    await pumpEventQueue();

    expect(
      tsSocket.sentFrames.where((frame) => frame['type'] == 'hello'),
      hasLength(1),
    );
    expect(lanSocket.closedByClient, isTrue);
    expect(lanSocket.sent, isEmpty);
  });

  test('prefer falls back to a held socket when the preferred times out', () async {
    final dials = holdingDials(factory);
    unawaited(client.startCandidates([lan, ts], prefer: ts));
    await pumpEventQueue();

    // The hold bound is the 2 s candidate timeout.
    expect(
      scheduler.connectTimers.every(
        (timer) => timer.delay == const Duration(seconds: 2),
      ),
      isTrue,
    );
    expect(scheduler.connectTimers, hasLength(2));

    final lanSocket = FakeHubSocket();
    dials['10.0.0.9:8787']!.complete(lanSocket);
    await pumpEventQueue();
    expect(lanSocket.sent, isEmpty);

    // The preferred dial's deadline elapses: fall back to the held socket.
    scheduler.fireConnectDeadline();
    await pumpEventQueue();

    expect(
      lanSocket.sentFrames.where((frame) => frame['type'] == 'hello'),
      hasLength(1),
    );
    expect(client.state.lastError, isNull);
  });

  test('a single candidate keeps the 10 second deadline and exact error', () async {
    factory.onDialFuture = (_) => Completer<HubSocket>().future;
    unawaited(client.startCandidates([lan]));
    await pumpEventQueue();

    expect(factory.urls, hasLength(1));
    expect(scheduler.connectTimers, hasLength(1));
    expect(scheduler.connectTimers.single.delay, const Duration(seconds: 10));
    expect(scheduler.connectTimers.single.kind, HubTimerKind.connect);

    scheduler.fireConnectDeadline();
    await pumpEventQueue();

    expect(
      client.state.lastError,
      'TimeoutException: could not reach 10.0.0.9:8787 within 10 seconds',
    );
    expect(scheduler.reconnectTimers, isNotEmpty);
  });

  test('an empty candidate list is a StateError', () async {
    await expectLater(client.startCandidates(const []), throwsStateError);
  });

  test('a prefer outside the list is treated as absent', () async {
    final dials = holdingDials(factory);
    unawaited(client.startCandidates([lan, ts], prefer: wan));
    await pumpEventQueue();

    final tsSocket = FakeHubSocket();
    dials['100.64.0.1:8787']!.complete(tsSocket);
    await pumpEventQueue();

    // First answer wins: ts is adopted immediately, with no hold.
    expect(
      tsSocket.sentFrames.where((frame) => frame['type'] == 'hello'),
      hasLength(1),
    );

    final lanSocket = FakeHubSocket();
    dials['10.0.0.9:8787']!.complete(lanSocket);
    await pumpEventQueue();
    expect(lanSocket.closedByClient, isTrue);
    expect(lanSocket.sent, isEmpty);
  });

  test('prefer holds one success and closes a second non-preferred', () async {
    final dials = holdingDials(factory);
    unawaited(client.startCandidates([lan, ts, wan], prefer: wan));
    await pumpEventQueue();
    expect(dials.keys, hasLength(3));

    final lanSocket = FakeHubSocket();
    dials['10.0.0.9:8787']!.complete(lanSocket);
    await pumpEventQueue();
    expect(lanSocket.closedByClient, isFalse);
    expect(lanSocket.sent, isEmpty);

    final tsSocket = FakeHubSocket();
    dials['100.64.0.1:8787']!.complete(tsSocket);
    await pumpEventQueue();
    expect(tsSocket.closedByClient, isTrue);
    expect(tsSocket.sent, isEmpty);

    final wanSocket = FakeHubSocket();
    dials['192.168.1.50:8787']!.complete(wanSocket);
    await pumpEventQueue();
    expect(
      wanSocket.sentFrames.where((frame) => frame['type'] == 'hello'),
      hasLength(1),
    );
    expect(lanSocket.closedByClient, isTrue);
    expect(lanSocket.sent, isEmpty);
  });

  test('a superseded prefer hold is closed and its race settled', () async {
    final firstDials = holdingDials(factory);
    var raceSettled = false;
    unawaited(
      client
          .startCandidates([lan, ts], prefer: ts)
          .then((_) => raceSettled = true),
    );
    await pumpEventQueue();

    final heldLan = FakeHubSocket();
    firstDials['10.0.0.9:8787']!.complete(heldLan);
    await pumpEventQueue();
    expect(heldLan.sent, isEmpty);
    expect(heldLan.closedByClient, isFalse);

    // The preferred dial never resolves; a second start supersedes the race.
    final secondDials = holdingDials(factory);
    unawaited(client.startCandidates([lan, ts], prefer: ts));
    await pumpEventQueue();

    expect(heldLan.closedByClient, isTrue);
    expect(heldLan.sent, isEmpty);
    expect(raceSettled, isTrue);

    final liveLan = FakeHubSocket();
    secondDials['10.0.0.9:8787']!.complete(liveLan);
    await pumpEventQueue();
    // The second race is unaffected: its non-preferred success is held, not
    // adopted, and the first race's held socket is already gone.
    expect(liveLan.closedByClient, isFalse);
    expect(liveLan.sent, isEmpty);
    expect(heldLan.closedByClient, isTrue);

    final liveTs = FakeHubSocket();
    secondDials['100.64.0.1:8787']!.complete(liveTs);
    await pumpEventQueue();
    expect(
      liveTs.sentFrames.where((frame) => frame['type'] == 'hello'),
      hasLength(1),
    );
    expect(liveLan.closedByClient, isTrue);
  });

  test('a stop during a prefer hold closes it and settles the race', () async {
    final dials = holdingDials(factory);
    var raceSettled = false;
    unawaited(
      client
          .startCandidates([lan, ts], prefer: ts)
          .then((_) => raceSettled = true),
    );
    await pumpEventQueue();

    final heldLan = FakeHubSocket();
    dials['10.0.0.9:8787']!.complete(heldLan);
    await pumpEventQueue();
    expect(heldLan.closedByClient, isFalse);

    await client.stop();
    await pumpEventQueue();

    expect(heldLan.closedByClient, isTrue);
    expect(heldLan.sent, isEmpty);
    expect(raceSettled, isTrue);
  });
}
