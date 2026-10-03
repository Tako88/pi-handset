// History: `history-request` → `snapshot` rebuilds the transcript baseline, and
// a `resync-required` must re-request history rather than leave it truncated.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/client/tool_view.dart';

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

  test(
    'a history-request is sent and a snapshot becomes the baseline',
    () async {
      client.subscribe('s1');
      client.requestHistory('s1');

      final request = factory.last.lastSent;
      expect(request['type'], 'history-request');
      expect(request['sessionId'], 's1');

      factory.last.receive({
        'protocolVersion': 1,
        'type': 'snapshot',
        'sessionId': 's1',
        'lastSeq': 7,
        'agentState': 'settled',
        'entries': [
          {'type': 'user', 'text': 'hi'},
          {'type': 'assistant', 'text': 'hello'},
        ],
        'truncated': false,
      });
      await pumpEventQueue();

      final transcript = client.transcript('s1')!;
      expect(transcript.entries.length, 2);
      expect(transcript.historyLoaded, isTrue);
      expect(transcript.lastSeq, 7);
      expect(transcript.agentState, 'settled');
      expect(transcript.truncated, isFalse);
    },
  );

  test('resync-required re-requests history for the session', () async {
    client.subscribe('s1');
    await pumpEventQueue();

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'resync-required',
      'sessionId': 's1',
      'reason': 'backpressure',
    });
    await pumpEventQueue();

    final request = factory.last.lastSent;
    expect(request['type'], 'history-request');
    expect(request['sessionId'], 's1');
  });

  void resync() => factory.last.receive({
    'protocolVersion': 1,
    'type': 'resync-required',
    'sessionId': 's1',
    'reason': 'backpressure',
  });

  // Counts every history-request the client sent, including the one opening a
  // session now issues; the resync cap adds to that baseline.
  int historyRequests() => factory.last.sentFrames
      .where((frame) => frame['type'] == 'history-request')
      .length;

  test('consecutive resyncs are capped and surface an error', () async {
    client.subscribe('s1');
    await pumpEventQueue();

    for (var i = 0; i < HubClient.maxConsecutiveResyncs + 5; i++) {
      resync();
    }
    await pumpEventQueue();

    expect(historyRequests(), HubClient.maxConsecutiveResyncs + 1);
    expect(client.state.lastError, isNotNull);
  });

  test('a snapshot breaks the consecutive-resync streak', () async {
    client.subscribe('s1');
    await pumpEventQueue();

    for (var i = 0; i < HubClient.maxConsecutiveResyncs; i++) {
      resync();
    }
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'snapshot',
      'sessionId': 's1',
      'lastSeq': 1,
      'agentState': 'idle',
      'entries': <Object?>[],
      'truncated': false,
    });
    await pumpEventQueue();
    for (var i = 0; i < HubClient.maxConsecutiveResyncs; i++) {
      resync();
    }
    await pumpEventQueue();

    expect(historyRequests(), HubClient.maxConsecutiveResyncs * 2 + 1);
    expect(client.state.lastError, isNull);
  });

  test('a throwing send does not escape requestHistory', () {
    factory.last.throwOnSend = true;
    expect(() => client.requestHistory('s1'), returnsNormally);
  });

  test('a non-positive sinceSeq is clamped before it is forwarded', () async {
    client.subscribe('s1');

    client.requestHistory('s1', sinceSeq: 0);
    expect(factory.last.lastSent['sinceSeq'], 1);

    client.requestHistory('s1', sinceSeq: -5);
    expect(factory.last.lastSent['sinceSeq'], 1);
  });

  test('a resync snapshot re-attaches a tool view the stream dropped', () async {
    // The live stream carried the call and its result, but the bridge's `done`
    // annotation frame was dropped under backlog, so the block has no view.
    Object toolCall() => {
      'type': 'message',
      'message': {
        'role': 'assistant',
        'content': [
          {
            'type': 'toolCall',
            'id': 'call-1',
            'name': 'read',
            'arguments': {'path': 'faux-tool.txt'},
          },
        ],
      },
    };
    Object toolResult() => {
      'type': 'message',
      'message': {
        'role': 'toolResult',
        'toolCallId': 'call-1',
        'toolName': 'read',
        'content': [
          {'type': 'text', 'text': 'body'},
        ],
      },
    };
    const Object toolFrame = {
      'kind': 'tool',
      'toolCallId': 'call-1',
      'name': 'read',
      'status': 'done',
      'view': {'type': 'file', 'path': 'faux-tool.txt', 'content': 'body'},
    };
    Map<String, Object?> snapshot(List<Object?> entries) => {
      'protocolVersion': 1,
      'type': 'snapshot',
      'sessionId': 's1',
      'lastSeq': 2,
      'agentState': 'settled',
      'entries': entries,
      'truncated': false,
    };

    client.subscribe('s1');
    await pumpEventQueue();
    factory.last.receive(snapshot([toolCall(), toolResult()]));
    await pumpEventQueue();
    expect(
      client.transcript('s1')!.blocks.single.toolView,
      isNull,
      reason: 'without the annotation frame there is no structured view',
    );

    // The hub announces the drop; the client re-requests history.
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'resync-required',
      'sessionId': 's1',
      'reason': 'backpressure',
    });
    await pumpEventQueue();
    expect(factory.last.lastSent['type'], 'history-request');

    // The unbudgeted snapshot carries the annotated frame, so the view comes
    // back — collapsed, because the transcript now comes from history.
    factory.last.receive(snapshot([toolCall(), toolFrame, toolResult()]));
    await pumpEventQueue();
    final block = client.transcript('s1')!.blocks.single;
    expect(block.toolView, isA<FileView>());
    expect(block.toolResult, isNotNull);
  });

  test(
    'a second snapshot replaces the transcript entries rather than appending',
    () async {
      Map<String, Object?> snapshot(String text) => {
        'protocolVersion': 1,
        'type': 'snapshot',
        'sessionId': 's1',
        'lastSeq': 1,
        'agentState': 'settled',
        'entries': [
          {'type': 'user', 'text': text},
        ],
        'truncated': false,
      };

      client.subscribe('s1');
      await pumpEventQueue();
      factory.last.receive(snapshot('a'));
      await pumpEventQueue();
      factory.last.receive(snapshot('b'));
      await pumpEventQueue();

      final entries = client.transcript('s1')!.entries;
      expect(entries.length, 1);
      expect((entries.first as Map)['text'], 'b');
    },
  );
}
