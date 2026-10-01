// App-started sessions on the client: start and kill are request/result
// commands correlated by id, but their results are produced by the hub
// locally, so they are pending under the empty-session convention.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';

import 'support/fakes.dart';

const String testToken =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  late FakeSocketFactory factory;
  late FakeScheduler scheduler;
  late HubClient client;

  setUp(() async {
    factory = FakeSocketFactory();
    scheduler = FakeScheduler();
    client = HubClient(
      socketFactory: factory.call,
      scheduler: scheduler,
      tokenStore: InMemoryTokenStore(initial: testToken),
      rng: () => 0.5,
    );
    await client.start('127.0.0.1');
    await pumpEventQueue();
  });

  test('startSession sends start-session with a generated id', () async {
    final future = client.startSession();

    final frame = factory.last.lastSent;
    expect(frame['type'], 'start-session');
    expect(frame['id'], isNotEmpty);

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': frame['id'],
      'ok': true,
    });

    final result = await future;
    expect(result.ok, isTrue);
    expect(result.error, isNull);
  });

  test('killSession sends kill-session carrying the session id', () async {
    final future = client.killSession('s1');

    final frame = factory.last.lastSent;
    expect(frame['type'], 'kill-session');
    expect(frame['id'], isNotEmpty);
    expect(frame['sessionId'], 's1');

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': frame['id'],
      'ok': true,
    });

    final result = await future;
    expect(result.ok, isTrue);
  });

  test('a refused start surfaces the hub error verbatim', () async {
    final future = client.startSession();
    final id = factory.last.lastSent['id'];

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': id,
      'ok': false,
      'error': 'too many app sessions',
    });

    final result = await future;
    expect(result.ok, isFalse);
    expect(result.error, 'too many app sessions');
  });

  test('start and kill without a socket report not connected', () async {
    await client.stop();

    expect((await client.startSession()).error, 'not connected');
    expect((await client.killSession('s1')).error, 'not connected');
  });

  test('a session-gone does not cancel an in-flight kill of that session', () async {
    var completed = false;
    final future = client.killSession('s1');
    future.then((_) => completed = true);

    // The kill's effect is the session disappearing; the hub sends the result
    // first, but a racing session-gone must not fail the kill.
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'session-gone',
      'sessionId': 's1',
    });
    await pumpEventQueue();
    expect(completed, isFalse, reason: 'a session-gone must not fail a start/kill');

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': factory.last.sentFrames
          .firstWhere((frame) => frame['type'] == 'kill-session')['id'],
      'ok': true,
    });
    expect((await future).ok, isTrue);
  });

  test('each start and kill schedules its own 30s timeout', () async {
    final start = client.startSession();
    final kill = client.killSession('s1');
    await pumpEventQueue();

    expect(scheduler.commandTimers, hasLength(2));
    expect(scheduler.commandTimers.every(
      (timer) => timer.delay == const Duration(seconds: 30),
    ), isTrue);

    scheduler.fireCommandTimeouts();
    expect((await start).error, 'timed out');
    expect((await kill).error, 'timed out');
  });

  test('SessionSummary.fromJson reads origin and defaults to pc', () {
    final app = SessionSummary.fromJson({
      'sessionId': 's1',
      'label': 'one',
      'agentState': 'idle',
      'origin': 'app',
    });
    expect(app.origin, 'app');

    final legacy = SessionSummary.fromJson({
      'sessionId': 's1',
      'label': 'one',
      'agentState': 'idle',
    });
    expect(legacy.origin, 'pc');

    const constructed = SessionSummary(
      sessionId: 's1',
      label: 'one',
      agentState: 'idle',
    );
    expect(constructed.origin, 'pc');
  });
}
