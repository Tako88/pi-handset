// History: `history-request` → `snapshot` rebuilds the transcript baseline, and
// a `resync-required` must re-request history rather than leave it truncated.

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
}
