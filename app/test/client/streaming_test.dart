// Streaming: deltas accumulate synchronously, observers are notified at most
// once per scheduled frame, and streaming stops on `agent_settled` — never on a
// message-level completion.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';

import 'support/fakes.dart';

const String testToken =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Map<String, Object?> stream(int seq, String text) => {
  'protocolVersion': 1,
  'type': 'event',
  'payload': {'kind': 'stream', 'seq': seq, 'text': text},
};

Map<String, Object?> agent(String state) => {
  'protocolVersion': 1,
  'type': 'event',
  'payload': {'kind': 'agent', 'state': state},
};

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
    scheduler.flushNotifications();
    scheduler.clear();
    client.subscribe('s1');
    await pumpEventQueue();
    scheduler.flushNotifications();
    scheduler.clear();
  });

  test('stream deltas accumulate into the active transcript', () async {
    factory.last.receive(agent('running'));
    factory.last.receive(stream(1, 'hel'));
    factory.last.receive(stream(2, 'lo '));
    factory.last.receive(stream(3, 'world'));
    await pumpEventQueue();

    final transcript = client.transcript('s1')!;
    expect(transcript.streamingText, 'hello world');
    expect(transcript.streaming, isTrue);
    expect(transcript.lastSeq, 3);
  });

  test(
    'a burst of deltas produces one notification, not one per token',
    () async {
      final notifications = <HubClientState>[];
      client.changes.listen(notifications.add);

      for (var seq = 1; seq <= 50; seq++) {
        factory.last.receive(stream(seq, 'x'));
      }
      await pumpEventQueue();

      // Accumulation is immediate; notification waits for the frame.
      expect(client.transcript('s1')!.streamingText, 'x' * 50);
      expect(notifications, isEmpty);

      scheduler.flushNotifications();

      expect(notifications.length, 1);
      expect(client.transcript('s1')!.streamingText, 'x' * 50);
    },
  );

  test(
    'a nonzero frame interval still coalesces a burst into one notification',
    () async {
      final factory = FakeSocketFactory();
      final scheduler = FakeScheduler();
      final client = HubClient(
        socketFactory: factory.call,
        scheduler: scheduler,
        tokenStore: InMemoryTokenStore(initial: testToken),
        rng: () => 0.5,
        frameInterval: const Duration(milliseconds: 16),
      );
      await client.start('127.0.0.1');
      await pumpEventQueue();
      client.subscribe('s1');
      await pumpEventQueue();

      final notifications = <HubClientState>[];
      client.changes.listen(notifications.add);

      for (var seq = 1; seq <= 50; seq++) {
        factory.last.receive(stream(seq, 'x'));
      }
      await pumpEventQueue();
      expect(notifications, isEmpty);

      scheduler.flushNotifications();
      expect(notifications, hasLength(1));
      expect(client.transcript('s1')!.streamingText, 'x' * 50);
    },
  );

  test('a throwing send inside a frame callback does not escape', () async {
    factory.last.throwOnSend = true;

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'resync-required',
      'sessionId': 's1',
      'reason': 'backpressure',
    });
    await pumpEventQueue();

    expect(client.state.lastError, contains('closing'));
  });

  test('agent_settled stops streaming', () async {
    factory.last.receive(agent('running'));
    factory.last.receive(stream(1, 'partial'));
    await pumpEventQueue();
    expect(client.transcript('s1')!.streaming, isTrue);

    factory.last.receive(agent('settled'));
    await pumpEventQueue();

    expect(client.transcript('s1')!.streaming, isFalse);
    expect(client.transcript('s1')!.agentState, 'settled');
    // A settle with no `message` frame must not leave a stale buffer for the
    // next stream to append to.
    expect(client.transcript('s1')!.streamingText, isEmpty);
  });
}
