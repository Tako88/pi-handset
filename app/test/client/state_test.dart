// Client state fed by the hub: the `sessions` push and `session-gone`.

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
    // Drain the connection-status notification so later counts are about the
    // state under test.
    await pumpEventQueue();
    scheduler.flushNotifications();
    scheduler.clear();
  });

  test('a sessions push replaces the session list', () async {
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'sessions',
      'sessions': [
        {'sessionId': 's1', 'label': 'one', 'agentState': 'idle'},
        {'sessionId': 's2', 'label': 'two', 'agentState': 'running'},
      ],
    });
    await pumpEventQueue();

    expect(client.state.sessions.map((s) => s.sessionId), ['s1', 's2']);
    expect(client.state.sessions.map((s) => s.label), ['one', 'two']);
    expect(client.state.sessions.map((s) => s.agentState), ['idle', 'running']);
    expect(client.state.status, HubConnectionStatus.connected);
  });

  test('session-gone removes the session and its transcript', () async {
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'sessions',
      'sessions': [
        {'sessionId': 's1', 'label': 'one', 'agentState': 'idle'},
        {'sessionId': 's2', 'label': 'two', 'agentState': 'idle'},
      ],
    });
    await pumpEventQueue();
    client.subscribe('s1');
    expect(client.transcript('s1'), isNotNull);

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'session-gone',
      'sessionId': 's1',
    });
    await pumpEventQueue();

    expect(client.state.sessions.map((s) => s.sessionId), ['s2']);
    expect(client.transcript('s1'), isNull);
    expect(client.state.activeSessionId, isNull);
  });

  test('stop emits a terminal disconnected state', () async {
    final states = <HubClientState>[];
    client.changes.listen(states.add);

    await client.stop();

    expect(states, isNotEmpty);
    expect(states.last.status, HubConnectionStatus.disconnected);
  });

  test('disconnect resets the state and allows a later start', () async {
    await client.disconnect();

    expect(client.state.status, HubConnectionStatus.disconnected);
    expect(client.state.lastError, isNull);

    // `stop()` closes `changes`; a disconnect must leave it open so the app can
    // point at a different hub and connect again.
    final states = <HubClientState>[];
    client.changes.listen(states.add);
    await client.start('127.0.0.1');
    await pumpEventQueue();
    scheduler.flushNotifications();

    expect(factory.sockets, hasLength(2));
    expect(states, isNotEmpty);
  });
}
