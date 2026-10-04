// History paging (M4): `loadOlder` sends at most one older-page request per
// session at a time, and `_onSnapshot` prepends only the page it asked for.
// A baseline always replaces, invalidates any page in flight, and a page that
// never arrives is bounded by the injected scheduler's page timeout.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/client/transcript.dart';

import 'support/fakes.dart';
import 'transcript_incremental_test.dart' show expectBlocksEqual;

const String testToken =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Map<String, Object?> msg(String text) => {'type': 'user', 'text': text};

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

  Map<String, Object?> snapshot({
    List<Object?>? entries,
    bool truncated = true,
    String? olderCursor,
    String? cursor,
    bool older = false,
    bool includeOlder = false,
  }) {
    final frame = <String, Object?>{
      'protocolVersion': 1,
      'type': 'snapshot',
      'sessionId': 's1',
      'lastSeq': 1,
      'agentState': 'settled',
      'entries': entries ?? [msg('b')],
      'truncated': truncated,
    };
    if (olderCursor != null) frame['olderCursor'] = olderCursor;
    if (cursor != null) frame['cursor'] = cursor;
    if (includeOlder) frame['older'] = older;
    return frame;
  }

  /// Subscribes, then delivers a baseline whose `olderCursor` (when given)
  /// offers a page.
  Future<void> baseline({String? olderCursor, List<Object?>? entries}) async {
    client.subscribe('s1');
    await pumpEventQueue();
    factory.last.receive(snapshot(olderCursor: olderCursor, entries: entries));
    await pumpEventQueue();
  }

  List<String> entryTexts() => client
      .transcript('s1')!
      .entries
      .map((entry) => (entry as Map)['text'] as String)
      .toList();

  int cursorRequests() => factory.last.sentFrames
      .where(
        (frame) =>
            frame['type'] == 'history-request' &&
            frame['cursor'] != null,
      )
      .length;

  test('A1 a matching older page prepends and stays derivation-equivalent', () async {
    await baseline(olderCursor: '2:x');
    client.loadOlder('s1');
    expect(factory.last.lastSent['cursor'], '2:x');

    factory.last.receive(
      snapshot(cursor: '2:x', older: true, includeOlder: true, entries: [msg('a')]),
    );
    await pumpEventQueue();

    final transcript = client.transcript('s1')!;
    expect(entryTexts(), ['a', 'b']);
    expectBlocksEqual(transcript.blocks, deriveBlocks(transcript.entries));
  });

  test('A2 a mismatched cursor older page is discarded, not prepended', () async {
    await baseline(olderCursor: '2:x');
    client.loadOlder('s1');

    factory.last.receive(
      snapshot(cursor: 'z', older: true, includeOlder: true, entries: [msg('z')]),
    );
    await pumpEventQueue();

    expect(entryTexts(), ['b']);
  });

  test('A3 a baseline landing while a page is in flight discards the late page', () async {
    await baseline(olderCursor: '2:x');
    client.loadOlder('s1');

    factory.last.receive(snapshot(truncated: false, entries: [msg('c')]));
    await pumpEventQueue();
    factory.last.receive(
      snapshot(cursor: '2:x', older: true, includeOlder: true, entries: [msg('a')]),
    );
    await pumpEventQueue();

    expect(entryTexts(), ['c']);
  });

  test('A4 a second loadOlder while one is in flight sends nothing', () async {
    await baseline(olderCursor: '2:x');
    client.loadOlder('s1');
    client.loadOlder('s1');

    expect(cursorRequests(), 1);
  });

  test('A5 a page preserves the in-flight stream and ambient state', () async {
    await baseline(olderCursor: '2:x');

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {'kind': 'stream', 'seq': 1, 'text': 'partial'},
    });
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {
        'kind': 'usage',
        'tokens': 100,
        'contextWindow': 1000,
        'thinkingLevel': 'high',
        'model': {'provider': 'anthropic', 'id': 'm', 'name': 'M'},
      },
    });
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {'kind': 'status', 'event': 'compacting', 'active': true},
    });
    await pumpEventQueue();

    client.loadOlder('s1');
    factory.last.receive(
      snapshot(cursor: '2:x', older: true, includeOlder: true, entries: [msg('a')]),
    );
    await pumpEventQueue();

    final transcript = client.transcript('s1')!;
    expect(transcript.streamingText, 'partial');
    expect(transcript.contextUsage!.contextWindow, 1000);
    expect(transcript.thinkingLevel, 'high');
    expect(transcript.currentModel!.id, 'm');
    expect(transcript.compacting, isTrue);
  });

  test('A6 a page reaching the beginning clears olderCursor and merges entries', () async {
    await baseline(olderCursor: '2:x');
    client.loadOlder('s1');

    factory.last.receive(
      snapshot(
        cursor: '2:x',
        older: true,
        includeOlder: true,
        truncated: false,
        entries: [msg('a')],
      ),
    );
    await pumpEventQueue();

    final transcript = client.transcript('s1')!;
    expect(transcript.olderCursor, isNull);
    expect(transcript.truncated, isFalse);
    expect(entryTexts(), ['a', 'b']);
  });

  test('A7 a throwing send does not leave the control loading', () async {
    await baseline(olderCursor: '2:x');
    factory.last.throwOnSend = true;

    client.loadOlder('s1');
    await pumpEventQueue();
    expect(client.transcript('s1')!.historyLoading, isFalse);
    // The throwing write never reached the wire, so nothing was recorded.
    expect(cursorRequests(), 0);

    factory.last.throwOnSend = false;
    client.loadOlder('s1');
    expect(cursorRequests(), 1);
  });

  test('A7b a tap with no live socket does nothing and does not hang', () async {
    await baseline(olderCursor: '2:x');
    factory.last.remoteClose(1006);
    // `_onSocketDone` nulls `_socket` only after `await socket.closed`, so one
    // pump is what bridges that microtask hop; a second is unnecessary.
    await pumpEventQueue();

    client.loadOlder('s1');
    await pumpEventQueue();

    expect(client.transcript('s1')!.historyLoading, isFalse);
    expect(cursorRequests(), 0);
  });

  test('A8 a cursor is forwarded and a non-positive sinceSeq is still clamped', () async {
    client.requestHistory('s1', sinceSeq: 0, cursor: 'abc');

    final sent = factory.last.lastSent;
    expect(sent['cursor'], 'abc');
    expect(sent['sinceSeq'], 1);
  });

  test('A9 a stale older page does not reset the resync streak', () async {
    await baseline(olderCursor: '2:x');

    void resync() => factory.last.receive({
      'protocolVersion': 1,
      'type': 'resync-required',
      'sessionId': 's1',
      'reason': 'backpressure',
    });

    for (var i = 0; i < HubClient.maxConsecutiveResyncs; i++) {
      resync();
    }
    await pumpEventQueue();
    expect(client.state.lastError, isNull);

    client.loadOlder('s1');
    // Well-formed and stale: only an applied frame is decoded, so the discard
    // path must tolerate a real entries payload without clearing the streak.
    factory.last.receive(
      snapshot(cursor: 'z', older: true, includeOlder: true, entries: []),
    );
    await pumpEventQueue();

    resync();
    await pumpEventQueue();

    expect(client.state.lastError, contains('gave up resyncing'));
  });

  test('A10 an unanswered page request times out and re-enables the control', () async {
    await baseline(olderCursor: '2:x');
    client.loadOlder('s1');
    expect(client.transcript('s1')!.historyLoading, isTrue);

    scheduler.fireHistoryPageTimeouts();
    await pumpEventQueue();
    expect(client.transcript('s1')!.historyLoading, isFalse);

    // The pending key is gone, so the request's own late reply cannot match.
    factory.last.receive(
      snapshot(cursor: '2:x', older: true, includeOlder: true, entries: [msg('a')]),
    );
    await pumpEventQueue();
    expect(entryTexts(), ['b']);

    // ...and the control is usable again.
    client.loadOlder('s1');
    expect(cursorRequests(), 2);
  });

  test('A11 a second start drops an in-flight page and re-enables the control', () async {
    await baseline(olderCursor: '2:x');
    client.loadOlder('s1');
    expect(client.transcript('s1')!.historyLoading, isTrue);
    expect(cursorRequests(), 1);

    // The default fake factory auto-answers a dial (fakes.dart call -> fresh
    // FakeHubSocket), so this completes without firing a connect deadline; the
    // timeout is a guard against a future harness change, not a driver.
    await client.start('127.0.0.1').timeout(const Duration(seconds: 5));
    await pumpEventQueue();

    expect(client.transcript('s1')!.historyLoading, isFalse);
    expect(scheduler.historyPageTimers.where((t) => !t.cancelled), isEmpty);

    // Usable again immediately, not after the page timeout.
    client.loadOlder('s1');
    expect(cursorRequests(), 1); // on the new socket
  });
}
