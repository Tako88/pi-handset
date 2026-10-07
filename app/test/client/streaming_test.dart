// Streaming: deltas accumulate synchronously, observers are notified at most
// once per scheduled frame, and streaming stops on `agent_settled` — never on a
// message-level completion.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/hub_client.dart';
import 'package:pi_handset/client/transcript.dart';

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

/// A reasoning chunk: a `stream` frame that carries both its phase and its text.
Map<String, Object?> thinkingDelta(int seq, String text) => {
  'protocolVersion': 1,
  'type': 'event',
  'payload': {'kind': 'stream', 'seq': seq, 'phase': 'thinking', 'text': text},
};

/// A committed assistant message carrying a thinking block and a reply.
Map<String, Object?> messageWithThinking(String thinking, String text) => {
  'protocolVersion': 1,
  'type': 'event',
  'payload': {
    'kind': 'message',
    'message': {
      'role': 'assistant',
      'content': [
        {'type': 'thinking', 'thinking': thinking},
        {'type': 'text', 'text': text},
      ],
    },
  },
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

/// A committed message whose oversized image part was replaced in place: the
/// message keeps its top-level `role` and text, so it must not be mistaken for
/// the whole-message `{truncated, bytes}` marker.
Map<String, Object?> partTrimmedFrame(String role) => {
  'protocolVersion': 1,
  'type': 'event',
  'payload': {
    'kind': 'message',
    'message': {
      'role': role,
      'content': [
        {'type': 'text', 'text': 'hi'},
        {'type': 'image', 'truncated': true, 'bytes': 999},
      ],
    },
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

  test('a part-trimmed user message does not clear the in-flight buffer', () async {
    factory.last.receive(agent('running'));
    factory.last.receive(stream(1, 'partial'));
    await pumpEventQueue();
    expect(client.transcript('s1')!.streamingText, 'partial');
    expect(client.transcript('s1')!.streaming, isTrue);

    // A mid-stream user steer whose image part was trimmed: no top-level
    // `truncated`, so it appends without wiping the reply still arriving.
    final before = client.transcript('s1')!.entries.length;
    factory.last.receive(partTrimmedFrame('user'));
    await pumpEventQueue();

    final transcript = client.transcript('s1')!;
    // Two-sided: the frame must both append a row AND leave the buffer alone,
    // or an ignored frame would pass this test vacuously.
    expect(transcript.entries, hasLength(before + 1));
    expect(transcript.streamingText, 'partial');
    expect(transcript.streaming, isTrue);
  });

  test('a part-trimmed assistant message still commits the reply', () async {
    factory.last.receive(agent('running'));
    factory.last.receive(stream(1, 'partial'));
    factory.last.receive(phase(2));
    await pumpEventQueue();
    expect(client.transcript('s1')!.thinking, isTrue);
    expect(client.transcript('s1')!.streaming, isTrue);

    factory.last.receive(partTrimmedFrame('assistant'));
    await pumpEventQueue();

    final transcript = client.transcript('s1')!;
    expect(transcript.streamingText, isEmpty);
    expect(transcript.streaming, isFalse);
    expect(transcript.thinking, isFalse);
  });

  test('reasoning deltas accumulate in their own buffer, not the reply', () async {
    factory.last.receive(agent('running'));
    factory.last.receive(phase(1));
    factory.last.receive(thinkingDelta(2, 'why '));
    factory.last.receive(thinkingDelta(3, 'so'));
    await pumpEventQueue();

    final transcript = client.transcript('s1')!;
    expect(transcript.streamingThinking, 'why so');
    expect(transcript.streamingText, isEmpty);
    expect(transcript.thinking, isTrue);
  });

  test('the first reply delta does not clear the live reasoning', () async {
    factory.last.receive(agent('running'));
    factory.last.receive(thinkingDelta(1, 'why'));
    factory.last.receive(stream(2, 'hi'));
    await pumpEventQueue();

    // The commit is the only thing that retires the live row mid-turn: clearing
    // it here would make the reasoning vanish mid-answer and reappear at commit.
    final transcript = client.transcript('s1')!;
    expect(transcript.streamingThinking, 'why');
    expect(transcript.streamingText, 'hi');
    expect(transcript.thinking, isFalse);
  });

  test('a second liveness frame after text does not reset the buffer', () async {
    factory.last.receive(agent('running'));
    factory.last.receive(thinkingDelta(1, 'first'));
    factory.last.receive(stream(2, 'hi'));
    // thinking -> text -> thinking within one turn.
    factory.last.receive(phase(3));
    await pumpEventQueue();

    expect(client.transcript('s1')!.streamingThinking, 'first');
  });

  test(
    'the committed assistant message replaces the live reasoning with one block',
    () async {
      factory.last.receive(agent('running'));
      factory.last.receive(thinkingDelta(1, 'why'));
      factory.last.receive(messageWithThinking('why', 'done'));
      await pumpEventQueue();

      final transcript = client.transcript('s1')!;
      expect(
        transcript.streamingThinking,
        isEmpty,
        reason: 'the live buffer must clear in the same update that commits',
      );
      final thinking = transcript.blocks
          .where((block) => block.kind == TranscriptBlockKind.thinking)
          .toList();
      expect(thinking, hasLength(1), reason: 'two producers must not render twice');
      expect(thinking.single.text, 'why');
    },
  );

  test('a tool-turn commit clears the reasoning buffer too', () async {
    factory.last.receive(agent('running'));
    factory.last.receive(thinkingDelta(1, 'why'));
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {
        'kind': 'message',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'thinking', 'thinking': 'why'},
            {
              'type': 'toolCall',
              'id': 't1',
              'name': 'bash',
              'arguments': <String, Object?>{},
            },
          ],
        },
      },
    });
    // The next turn's reasoning starts fresh rather than appending to the old.
    factory.last.receive(thinkingDelta(2, 'and'));
    await pumpEventQueue();

    final transcript = client.transcript('s1')!;
    expect(transcript.streamingThinking, 'and');
    final thinking = transcript.blocks
        .where((b) => b.kind == TranscriptBlockKind.thinking)
        .toList();
    expect(thinking, hasLength(1));
    expect(thinking.single.text, 'why');
  });

  test('a mid-turn snapshot drops the live reasoning, as it drops live text', () async {
    factory.last.receive(agent('running'));
    factory.last.receive(thinkingDelta(1, 'why'));
    factory.last.receive(stream(2, 'hi'));
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'snapshot',
      'sessionId': 's1',
      'lastSeq': 2,
      'agentState': 'running',
      'entries': <Object?>[],
      'truncated': false,
    });
    await pumpEventQueue();

    // Deliberate, not accidental: a snapshot is a wholesale replacement of the
    // baseline, and the live reply text is dropped with it today.
    final transcript = client.transcript('s1')!;
    expect(transcript.streamingThinking, isEmpty);
    expect(transcript.streamingText, isEmpty);
  });

  test('settling clears an unterminated reasoning buffer', () async {
    factory.last.receive(agent('running'));
    factory.last.receive(thinkingDelta(1, 'why'));
    factory.last.receive(agent('settled'));
    await pumpEventQueue();

    expect(client.transcript('s1')!.streamingThinking, isEmpty);
  });

  test('an error status clears an unterminated reasoning buffer', () async {
    factory.last.receive(agent('running'));
    factory.last.receive(thinkingDelta(1, 'why'));
    factory.last.receive(statusFrame('error', 'boom'));
    await pumpEventQueue();

    expect(client.transcript('s1')!.streamingThinking, isEmpty);
  });

  test('an assistant message commits and clears the reply; a steer does not', () async {
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
