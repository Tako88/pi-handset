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

/// A content-free liveness phase: `kind: 'stream'`, no `text`.
Map<String, Object?> phase(int seq) => {
  'protocolVersion': 1,
  'type': 'event',
  'payload': {'kind': 'stream', 'seq': seq, 'phase': 'thinking'},
};

/// A committed message with a single text block.
Map<String, Object?> messageFrame(String role, String text) => {
  'protocolVersion': 1,
  'type': 'event',
  'payload': {
    'kind': 'message',
    'message': {
      'role': role,
      'content': [
        {'type': 'text', 'text': text},
      ],
    },
  },
};

/// A relayed status payload (e.g. an error), relayed raw to the renderer.
Map<String, Object?> statusFrame(String event, String message) => {
  'protocolVersion': 1,
  'type': 'event',
  'payload': {'kind': 'status', 'event': event, 'message': message},
};

/// The marker the bridge substitutes for an oversized message.
Map<String, Object?> truncatedFrame(int bytes) => {
  'protocolVersion': 1,
  'type': 'event',
  'payload': {
    'kind': 'message',
    'message': {'truncated': true, 'bytes': bytes},
  },
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

  test(
    'a phase-only stream frame sets thinking and does not crash on the missing text',
    () async {
      factory.last.receive(agent('running'));
      factory.last.receive(phase(1));
      await pumpEventQueue();

      final transcript = client.transcript('s1')!;
      expect(transcript.thinking, isTrue);
      expect(transcript.streamingText, isEmpty);
      expect(transcript.lastSeq, 1);
    },
  );

  test('the first text delta clears the thinking phase', () async {
    factory.last.receive(agent('running'));
    factory.last.receive(phase(1));
    factory.last.receive(stream(2, 'hello'));
    await pumpEventQueue();

    final transcript = client.transcript('s1')!;
    expect(transcript.thinking, isFalse);
    expect(transcript.streamingText, 'hello');
  });

  test('agent_settled clears the thinking phase', () async {
    factory.last.receive(agent('running'));
    factory.last.receive(phase(1));
    await pumpEventQueue();
    expect(client.transcript('s1')!.thinking, isTrue);

    factory.last.receive(agent('settled'));
    await pumpEventQueue();
    expect(client.transcript('s1')!.thinking, isFalse);
  });

  test('agent running alone does not set the thinking phase', () async {
    // The phase is signalled by the bridge, never guessed from `running`: a
    // slow first token must say `Working…`, not `Thinking…`.
    factory.last.receive(agent('running'));
    await pumpEventQueue();

    expect(client.transcript('s1')!.thinking, isFalse);
  });

  test('an error status clears the thinking phase', () async {
    factory.last.receive(agent('running'));
    factory.last.receive(phase(1));
    await pumpEventQueue();
    expect(client.transcript('s1')!.thinking, isTrue);

    // A model error ends the turn without a settle; nothing else clears the
    // phase, so `Thinking…` would otherwise stick forever.
    factory.last.receive(statusFrame('error', 'model overloaded'));
    await pumpEventQueue();

    expect(client.transcript('s1')!.thinking, isFalse);
  });

  test('a truncated assistant marker clears the thinking phase', () async {
    factory.last.receive(agent('running'));
    factory.last.receive(phase(1));
    await pumpEventQueue();
    expect(client.transcript('s1')!.thinking, isTrue);

    // The oversized message is replaced by `{truncated:true, bytes}`, which has
    // no `role`; it still commits the reply and must clear the phase.
    factory.last.receive(truncatedFrame(123456));
    await pumpEventQueue();

    final transcript = client.transcript('s1')!;
    expect(transcript.thinking, isFalse);
    expect(transcript.streaming, isFalse);
  });

  test(
    'a relayed user message appends without wiping the in-flight reply; an assistant message commits and clears it',
    () async {
      factory.last.receive(agent('running'));
      factory.last.receive(stream(1, 'partial'));
      factory.last.receive(messageFrame('user', 'a steer'));
      await pumpEventQueue();

      var transcript = client.transcript('s1')!;
      // The steer appended a block-producing entry, but the reply still in
      // flight must not be wiped.
      expect(transcript.entries, hasLength(1));
      expect(transcript.streamingText, 'partial');
      expect(transcript.streaming, isTrue);

      factory.last.receive(messageFrame('assistant', 'complete'));
      await pumpEventQueue();

      transcript = client.transcript('s1')!;
      expect(transcript.entries, hasLength(2));
      expect(transcript.streamingText, isEmpty);
      expect(transcript.streaming, isFalse);
    },
  );
}
