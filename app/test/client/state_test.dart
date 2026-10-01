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

  // Regression: `_onSessions` mutated the list and then relied on
  // `_markConnected()`'s status change to notify. `_setStatus` early-returns
  // when the status is unchanged, so that only ever fires once per connection —
  // every later push updated the state and never told the widget. A session
  // could register or die and the visible list would not budge until some
  // unrelated action repainted it. Asserted on the change stream, not on
  // `state`, because `state` was always correct: only the notification was
  // missing, which is why the existing test above never caught it.
  test('a second sessions push notifies, not just the first', () async {
    final states = <HubClientState>[];
    client.changes.listen(states.add);

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'sessions',
      'sessions': [
        {'sessionId': 's1', 'label': 'one', 'agentState': 'idle'},
      ],
    });
    await pumpEventQueue();
    scheduler.flushNotifications();
    expect(states, isNotEmpty);
    expect(states.last.sessions.map((s) => s.sessionId), ['s1']);

    // The connection is `connected` now, so this push changes nothing about the
    // status: it must notify on its own or the widget never rebuilds.
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'sessions',
      'sessions': const [],
    });
    await pumpEventQueue();
    scheduler.flushNotifications();

    expect(
      states.last.sessions,
      isEmpty,
      reason: 'a later list must reach the UI, not only the first one',
    );
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

  test('a usage event sets the session context usage', () async {
    client.subscribe('s1');
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {'kind': 'usage', 'tokens': 23400, 'contextWindow': 128000},
    });
    await pumpEventQueue();

    final usage = client.transcript('s1')!.contextUsage!;
    expect(usage.tokens, 23400);
    expect(usage.contextWindow, 128000);
  });

  test('a usage event with an unknown count keeps the window', () async {
    client.subscribe('s1');
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {'kind': 'usage', 'tokens': null, 'contextWindow': 128000},
    });
    await pumpEventQueue();

    final usage = client.transcript('s1')!.contextUsage!;
    expect(usage.tokens, isNull);
    expect(usage.contextWindow, 128000);
  });

  test('a usage event is not appended to the transcript', () async {
    client.subscribe('s1');
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {'kind': 'usage', 'tokens': 1, 'contextWindow': 100},
    });
    await pumpEventQueue();

    // It is state, not a row: appending it would put an unrenderable payload in
    // the entry list and bloat the transcript.
    expect(client.transcript('s1')!.entries, isEmpty);
  });

  test('a snapshot keeps this session\'s usage and does not borrow another\'s', () async {
    client.subscribe('s1');
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {'kind': 'usage', 'tokens': 23400, 'contextWindow': 128000},
    });
    await pumpEventQueue();

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'snapshot',
      'sessionId': 's1',
      'lastSeq': 0,
      'agentState': 'idle',
      'entries': <Object?>[],
      'truncated': false,
    });
    await pumpEventQueue();
    expect(client.transcript('s1')!.contextUsage!.tokens, 23400);

    // A different session's snapshot must not inherit s1's reading.
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'snapshot',
      'sessionId': 's2',
      'lastSeq': 0,
      'agentState': 'idle',
      'entries': <Object?>[],
      'truncated': false,
    });
    await pumpEventQueue();
    expect(client.transcript('s2')!.contextUsage, isNull);
  });

  test('a usage event records the session thinking level', () async {
    client.subscribe('s1');
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {
        'kind': 'usage',
        'tokens': 23400,
        'contextWindow': 128000,
        'thinkingLevel': 'high',
      },
    });
    await pumpEventQueue();

    expect(client.transcript('s1')!.thinkingLevel, 'high');
  });

  test('a usage event without a level leaves the last one', () async {
    client.subscribe('s1');
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {
        'kind': 'usage',
        'tokens': 23400,
        'contextWindow': 128000,
        'thinkingLevel': 'high',
      },
    });
    await pumpEventQueue();

    // An older bridge omits the field; the menu must keep the level it had.
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {'kind': 'usage', 'tokens': 23400, 'contextWindow': 128000},
    });
    await pumpEventQueue();
    expect(client.transcript('s1')!.thinkingLevel, 'high');
  });

  test('a snapshot keeps this session\'s level and does not borrow another\'s', () async {
    client.subscribe('s1');
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {
        'kind': 'usage',
        'tokens': 23400,
        'contextWindow': 128000,
        'thinkingLevel': 'high',
      },
    });
    await pumpEventQueue();

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'snapshot',
      'sessionId': 's1',
      'lastSeq': 0,
      'agentState': 'idle',
      'entries': <Object?>[],
      'truncated': false,
    });
    await pumpEventQueue();
    expect(client.transcript('s1')!.thinkingLevel, 'high');

    // A different session's snapshot must not inherit s1's level.
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'snapshot',
      'sessionId': 's2',
      'lastSeq': 0,
      'agentState': 'idle',
      'entries': <Object?>[],
      'truncated': false,
    });
    await pumpEventQueue();
    expect(client.transcript('s2')!.thinkingLevel, isNull);
  });

  test('a compaction announcement is state, not a row', () async {
    client.subscribe('s1');
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {'kind': 'status', 'event': 'compacting', 'active': true},
    });
    await pumpEventQueue();

    expect(client.transcript('s1')!.compacting, isTrue);
    // A status payload is normally a notice row. This one carries no message and
    // would render nothing — and a row cannot be cleared when the compaction it
    // describes is over, so it would sit in the transcript forever.
    expect(client.transcript('s1')!.entries, isEmpty);
  });

  test('a completed compaction clears the announcement', () async {
    client.subscribe('s1');
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {'kind': 'status', 'event': 'compacting', 'active': true},
    });
    await pumpEventQueue();
    expect(client.transcript('s1')!.compacting, isTrue);

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {'kind': 'status', 'event': 'compacting', 'active': false},
    });
    await pumpEventQueue();
    expect(client.transcript('s1')!.compacting, isFalse);
  });

  test('a compaction failure clears the announcement and shows the notice', () async {
    client.subscribe('s1');
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {'kind': 'status', 'event': 'compacting', 'active': true},
    });
    await pumpEventQueue();

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {'kind': 'status', 'event': 'compacting', 'active': false},
    });
    await pumpEventQueue();
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {
        'kind': 'status',
        'event': 'error',
        'message': 'Compaction failed: no model',
      },
    });
    await pumpEventQueue();

    // The clear is state and the error is a row: the failure must both retire the
    // indicator and leave exactly one notice behind.
    expect(client.transcript('s1')!.compacting, isFalse);
    expect(client.transcript('s1')!.entries, hasLength(1));
  });

  test('a snapshot keeps the compaction indicator', () async {
    client.subscribe('s1');
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {'kind': 'status', 'event': 'compacting', 'active': true},
    });
    await pumpEventQueue();

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'snapshot',
      'sessionId': 's1',
      'lastSeq': 0,
      'agentState': 'idle',
      'entries': <Object?>[],
      'truncated': false,
    });
    await pumpEventQueue();

    // A snapshot says nothing about compaction, so resetting to false would drop
    // the indicator for the rest of a long compaction that emits no further frame.
    expect(client.transcript('s1')!.compacting, isTrue);
    expect(client.transcript('s1')!.contextUsage, isNull);
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
