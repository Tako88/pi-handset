// Incremental transcript derivation (#21): appending one entry must extend the
// existing block list instead of re-deriving every block, and the result must
// stay identical to a whole-list `deriveBlocks`.
//
// Two oracles live here. The golden tests (E1–E13, E15–E19) assert the
// incremental output against hand-written expected blocks, so a fault in shared
// emission code reddens them even though the differential cannot see it. The
// differential (E14) compares the incremental result to `deriveBlocks` over
// generated sequences — the broad guard for the equivalence specification. The
// client-level tests (I1, W1–W3) drive the real HubClient.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/client/tool_view.dart';
import 'package:pi_droid/client/transcript.dart';

import 'support/fakes.dart';

const String testToken =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

/// A genuine 1×1 PNG. `base64Decode` is the validator here; a bad literal would
/// still decode and only the widget tests would notice.
const String pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

final pngBytes = base64Decode(pngBase64);

// ---------------------------------------------------------------------------
// Entry builders (always allocate a fresh map).
// ---------------------------------------------------------------------------

Map<String, Object?> textPart(String text) => {'type': 'text', 'text': text};

Map<String, Object?> thinkingPart(String thinking) => {
  'type': 'thinking',
  'thinking': thinking,
};

Map<String, Object?> imagePart(String data) => {
  'type': 'image',
  'data': data,
  'mimeType': 'image/png',
};

Map<String, Object?> toolCallPart(String id) => {
  'type': 'toolCall',
  'id': id,
  'name': 'read',
  'arguments': {'path': '/etc/hostname'},
};

Map<String, Object?> userText(String text) => {'role': 'user', 'content': text};

Map<String, Object?> assistantText(String text) => {
  'role': 'assistant',
  'content': text,
};

Map<String, Object?> assistantParts(List<Object?> parts) => {
  'role': 'assistant',
  'content': parts,
};

Map<String, Object?> toolResultMsg(
  String callId, {
  Object? content,
  String toolName = 'read',
  bool isError = false,
}) => {
  'role': 'toolResult',
  'toolCallId': callId,
  'toolName': toolName,
  'content': content ?? [textPart('body')],
  'isError': isError,
};

Map<String, Object?> toolFrame(
  String callId, {
  String status = 'done',
  Object? view,
}) => {
  'kind': 'tool',
  'toolCallId': callId,
  'name': 'read',
  'status': status,
  'view': ?view,
};

Map<String, Object?> fileView(String path, String content) => {
  'type': 'file',
  'path': path,
  'content': content,
};

// ---------------------------------------------------------------------------
// Comparison helpers (ToolView overrides no ==, so compare structurally).
// ---------------------------------------------------------------------------

void expectToolView(ToolView? actual, ToolView? expected, [int? i]) {
  final where = i == null ? '' : ' (block $i)';
  if (expected == null) {
    expect(actual, isNull, reason: 'toolView$where');
    return;
  }
  expect(actual, isNotNull, reason: 'toolView$where');
  expect(actual!.truncated, expected.truncated, reason: 'view.truncated$where');
  switch (expected) {
    case FileView():
      expect(actual, isA<FileView>(), reason: 'view type$where');
      final a = actual as FileView;
      expect(a.path, expected.path, reason: 'path$where');
      expect(a.content, expected.content, reason: 'content$where');
      expect(a.startLine, expected.startLine, reason: 'startLine$where');
      expect(a.endLine, expected.endLine, reason: 'endLine$where');
    case CommandView():
      expect(actual, isA<CommandView>(), reason: 'view type$where');
      final a = actual as CommandView;
      expect(a.command, expected.command, reason: 'command$where');
      expect(a.output, expected.output, reason: 'output$where');
      expect(a.exitCode, expected.exitCode, reason: 'exitCode$where');
    case DiffView():
      expect(actual, isA<DiffView>(), reason: 'view type$where');
      final a = actual as DiffView;
      expect(a.path, expected.path, reason: 'path$where');
      expect(a.lines.length, expected.lines.length, reason: 'lines$where');
      for (var n = 0; n < expected.lines.length; n++) {
        expect(a.lines[n].kind, expected.lines[n].kind);
        expect(a.lines[n].text, expected.lines[n].text);
      }
    case MatchesView():
      expect(actual, isA<MatchesView>(), reason: 'view type$where');
      final a = actual as MatchesView;
      expect(a.matches.length, expected.matches.length, reason: 'matches$where');
      for (var n = 0; n < expected.matches.length; n++) {
        expect(a.matches[n].file, expected.matches[n].file);
        expect(a.matches[n].line, expected.matches[n].line);
        expect(a.matches[n].text, expected.matches[n].text);
      }
    case TableView():
      expect(actual, isA<TableView>(), reason: 'view type$where');
      final a = actual as TableView;
      expect(a.columns, expected.columns, reason: 'columns$where');
      expect(a.rows, expected.rows, reason: 'rows$where');
    case GenericView():
      expect(actual, isA<GenericView>(), reason: 'view type$where');
      final a = actual as GenericView;
      expect(a.target, expected.target, reason: 'target$where');
  }
}

void expectBlock(TranscriptBlock actual, TranscriptBlock expected, int i) {
  expect(actual.kind, expected.kind, reason: 'kind (block $i)');
  expect(actual.id, expected.id, reason: 'id (block $i)');
  expect(actual.text, expected.text, reason: 'text (block $i)');
  expect(actual.fromUser, expected.fromUser, reason: 'fromUser (block $i)');
  expect(actual.complete, expected.complete, reason: 'complete (block $i)');
  expect(actual.toolName, expected.toolName, reason: 'toolName (block $i)');
  expect(actual.toolArgs, expected.toolArgs, reason: 'toolArgs (block $i)');
  expect(actual.toolResult, expected.toolResult, reason: 'toolResult (block $i)');
  expect(actual.isError, expected.isError, reason: 'isError (block $i)');
  final expectedBytes = expected.imageBytes;
  expect(
    actual.imageBytes,
    expectedBytes == null ? isNull : orderedEquals(expectedBytes.toList()),
    reason: 'imageBytes (block $i)',
  );
  expectToolView(actual.toolView, expected.toolView, i);
}

void expectBlocksEqual(
  List<TranscriptBlock> actual,
  List<TranscriptBlock> expected, {
  String? reason,
}) {
  expect(
    actual.length,
    expected.length,
    reason: reason == null ? 'block count' : 'block count ($reason)',
  );
  for (var i = 0; i < expected.length; i++) {
    expectBlock(actual[i], expected[i], i);
  }
}

String goldenId(Object entry, int sub) => '${identityHashCode(entry)}:$sub';

/// Feeds [entries] into a fresh derivation one at a time and returns its blocks.
List<TranscriptBlock> incremental(List<Object?> entries) {
  final derivation = TranscriptDerivation();
  for (final entry in entries) {
    derivation.append(entry);
  }
  return List<TranscriptBlock>.of(derivation.blocks);
}

// ---------------------------------------------------------------------------
// The fixed-seed generator alphabet for E14.
// ---------------------------------------------------------------------------

Object? randomEntry(Random rng, List<String> ids) {
  final id = ids[rng.nextInt(ids.length)];
  switch (rng.nextInt(23)) {
    case 0:
      return {'role': 'user', 'content': 'u${rng.nextInt(10)}'};
    case 1:
      return {'role': 'assistant', 'content': 'a${rng.nextInt(10)}'};
    case 2:
      return assistantParts([toolCallPart(id)]);
    case 3:
      return assistantParts([toolCallPart(ids[0]), toolCallPart(ids[1])]);
    case 4:
      return assistantParts([
        {'type': 'toolCall', 'id': 7, 'name': 'read', 'arguments': {'path': '/x'}},
      ]);
    case 5:
      return assistantParts([
        textPart('t${rng.nextInt(3)}'),
        thinkingPart('th${rng.nextInt(3)}'),
        toolCallPart(id),
      ]);
    case 6:
      return assistantParts([thinkingPart('chunk${rng.nextInt(3)}')]);
    case 7:
      return toolFrame(id, status: 'running', view: fileView('p', 'v'));
    case 8:
      return toolFrame(id, status: 'done', view: fileView('p', 'v'));
    case 9:
      return toolFrame(id);
    case 10:
      return {
        ...toolFrame(id, view: fileView('p', 'v')),
        'truncated': true,
        'bytes': rng.nextInt(100),
      };
    case 11:
      return toolResultMsg(id);
    case 12:
      return toolResultMsg(id, content: 'string body ${rng.nextInt(5)}');
    case 13:
      return toolResultMsg(id, content: [textPart('with image'), imagePart(pngBase64)]);
    case 14:
      return toolResultMsg(id, content: [textPart('bad image'), imagePart('BASE64')]);
    case 15:
      return toolResultMsg(id, content: [
        {'type': 'image', 'truncated': true, 'bytes': 10},
        textPart('after'),
      ]);
    case 16:
      return toolResultMsg('orphan-${rng.nextInt(2)}');
    case 17:
      return {'kind': 'status', 'message': rng.nextBool() ? '' : 'notice ${rng.nextInt(3)}'};
    case 18:
      return {'truncated': true, 'bytes': rng.nextInt(1000)};
    case 19:
      return rng.nextBool()
          ? {'type': 'user', 'text': rng.nextBool() ? '' : 'flat user'}
          : {'type': 'assistant', 'text': rng.nextBool() ? '' : 'flat assistant'};
    case 20:
      switch (rng.nextInt(4)) {
        case 0:
          return {'type': 'message', 'message': {'role': 'user', 'content': 'wrapped'}};
        case 1:
          return {
            'type': 'message',
            'message': assistantParts([toolCallPart(id)]),
          };
        case 2:
          return {'type': 'label', 'text': 'bookkeeping'};
        default:
          return rng.nextInt(1000);
      }
    case 21:
      return {
        'type': 'compaction',
        'id': 'c${rng.nextInt(3)}',
        'summary': rng.nextBool() ? '' : 'gist ${rng.nextInt(3)}',
        'tokensBefore': rng.nextInt(1000),
      };
    default:
      return {
        'type': 'branch_summary',
        'id': 'b${rng.nextInt(3)}',
        'fromId': id,
        'summary': rng.nextBool() ? '' : 'branch gist ${rng.nextInt(3)}',
      };
  }
}

// ---------------------------------------------------------------------------
// Client-level framing helpers.
// ---------------------------------------------------------------------------

Map<String, Object?> snapshotFrame(String sessionId, List<Object?> entries) => {
  'protocolVersion': 1,
  'type': 'snapshot',
  'sessionId': sessionId,
  'lastSeq': 0,
  'agentState': 'idle',
  'entries': entries,
  'truncated': false,
};

Map<String, Object?> eventMessage(Object? message) => {
  'protocolVersion': 1,
  'type': 'event',
  'payload': {'kind': 'message', 'message': message},
};

Map<String, Object?> eventPayload(Map<String, Object?> payload) => {
  'protocolVersion': 1,
  'type': 'event',
  'payload': payload,
};

void main() {
  // -------------------------------------------------------------------------
  // Golden awkward-shape tests. Each asserts against hand-written expected
  // blocks, so a shared-code fault reddens it.
  // -------------------------------------------------------------------------

  test('E1: appending a user message yields the expected text block', () {
    final m = userText('hello');
    final d = TranscriptDerivation()..append(m);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.text,
        id: goldenId(m, 0),
        text: 'hello',
        fromUser: true,
      ),
    ]);
  });

  test('E2: appending an assistant message with a tool call yields the tool row', () {
    final m = assistantParts([toolCallPart('c1')]);
    final d = TranscriptDerivation()..append(m);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.tool,
        id: 'tool:c1',
        toolName: 'read',
        toolArgs: {'path': '/etc/hostname'},
      ),
    ]);
  });

  test('E3: appending a tool result after its call fills the existing row', () {
    final call = assistantParts([toolCallPart('c1')]);
    final result = toolResultMsg('c1');
    final d = TranscriptDerivation()
      ..append(call)
      ..append(result);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.tool,
        id: 'tool:c1',
        toolName: 'read',
        toolArgs: {'path': '/etc/hostname'},
        text: 'body',
        toolResult: result,
      ),
    ]);
  });

  test('E4: appending a tool result before its call collapses to one paired row', () {
    final result = toolResultMsg('c1');
    final call = assistantParts([toolCallPart('c1')]);
    final d = TranscriptDerivation()
      ..append(result)
      ..append(call);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.tool,
        id: 'tool:c1',
        toolName: 'read',
        toolArgs: {'path': '/etc/hostname'},
        text: 'body',
        toolResult: result,
      ),
    ]);
  });

  test('E5: appending a duplicate call id keeps both rows and pairs the first result', () {
    final a = assistantParts([toolCallPart('c1')]);
    final b = assistantParts([toolCallPart('c1')]);
    final r = toolResultMsg('c1');
    final d = TranscriptDerivation()
      ..append(a)
      ..append(b)
      ..append(r);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.tool,
        id: 'tool:c1',
        toolName: 'read',
        toolArgs: {'path': '/etc/hostname'},
        text: 'body',
        toolResult: r,
      ),
      TranscriptBlock(
        kind: TranscriptBlockKind.tool,
        id: 'tool:c1#1',
        toolName: 'read',
        toolArgs: {'path': '/etc/hostname'},
        text: 'body',
        toolResult: r,
      ),
    ]);
  });

  test('E6: appending a result with no call becomes a standalone row', () {
    final r = toolResultMsg('c9');
    final d = TranscriptDerivation()..append(r);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.tool,
        id: 'tool:c9',
        toolName: 'read',
        text: 'body',
        toolResult: r,
      ),
    ]);
  });

  test('E6b: a view frame attaches to a standalone orphan result row', () {
    final r = toolResultMsg('c9');
    final frame = toolFrame('c9', view: fileView('p', 'x'));
    final d = TranscriptDerivation()
      ..append(r)
      ..append(frame);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.tool,
        id: 'tool:c9',
        toolName: 'read',
        text: 'body',
        toolResult: r,
        toolView: const FileView(path: 'p', content: 'x'),
      ),
    ]);
  });

  test('E7: appending a paired result carrying an image gets its image row', () {
    final call = assistantParts([toolCallPart('c1')]);
    final result = toolResultMsg('c1', content: [textPart('x'), imagePart(pngBase64)]);
    final d = TranscriptDerivation()
      ..append(call)
      ..append(result);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.tool,
        id: 'tool:c1',
        toolName: 'read',
        toolArgs: {'path': '/etc/hostname'},
        text: 'x',
        toolResult: result,
      ),
      TranscriptBlock(
        kind: TranscriptBlockKind.image,
        id: 'tool:c1:img0',
        imageBytes: pngBytes,
      ),
    ]);
  });

  test('E8: appending consecutive thinking chunks merges into one row', () {
    final a1 = assistantParts([thinkingPart('first')]);
    final a2 = assistantParts([thinkingPart('second')]);
    final d = TranscriptDerivation()
      ..append(a1)
      ..append(a2);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.thinking,
        id: goldenId(a1, 0),
        text: 'first\n\nsecond',
      ),
    ]);
  });

  test('E9: appending a status notice yields a notice row', () {
    final s = {'kind': 'status', 'message': 'oops'};
    final d = TranscriptDerivation()..append(s);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.notice,
        id: goldenId(s, 0),
        text: 'oops',
      ),
    ]);
  });

  test('E21: appending a compaction entry yields the summary notice', () {
    final c = {'type': 'compaction', 'summary': 'gist', 'tokensBefore': 900};
    final d = TranscriptDerivation()..append(c);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.notice,
        id: goldenId(c, 0),
        text: 'Compacted from 900 tokens',
      ),
    ]);
  });

  test('E22: appending a branch summary yields the summary notice', () {
    final b = {'type': 'branch_summary', 'summary': 'gist', 'fromId': 'leaf'};
    final d = TranscriptDerivation()..append(b);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.notice,
        id: goldenId(b, 0),
        text: 'Branch summary',
      ),
    ]);
  });

  test('E10: appending a truncated marker yields a notice row', () {
    final t = {'truncated': true, 'bytes': 123};
    final d = TranscriptDerivation()..append(t);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.notice,
        id: goldenId(t, 0),
        text: 'reply too large to display (123 bytes)',
      ),
    ]);
  });

  test('E11: appending a wrapped snapshot entry matches the bare shape', () {
    final wrapped = {
      'type': 'message',
      'message': {'role': 'user', 'content': 'hi'},
    };
    final d = TranscriptDerivation()..append(wrapped);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.text,
        id: goldenId(wrapped, 0),
        text: 'hi',
        fromUser: true,
      ),
    ]);
  });

  test('E12: appending a view frame updates the existing tool row', () {
    final call = assistantParts([toolCallPart('c1')]);
    final frame = toolFrame('c1', view: fileView('p', 'x'));
    final d = TranscriptDerivation()
      ..append(call)
      ..append(frame);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.tool,
        id: 'tool:c1',
        toolName: 'read',
        toolArgs: {'path': '/etc/hostname'},
        toolView: const FileView(path: 'p', content: 'x'),
      ),
    ]);
  });

  test('E13: appending a viewless done frame keeps the running view', () {
    final call = assistantParts([toolCallPart('c1')]);
    final running = toolFrame('c1', status: 'running', view: fileView('p', 'x'));
    final done = toolFrame('c1');
    final d = TranscriptDerivation()
      ..append(call)
      ..append(running)
      ..append(done);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.tool,
        id: 'tool:c1',
        toolName: 'read',
        toolArgs: {'path': '/etc/hostname'},
        toolView: const FileView(path: 'p', content: 'x'),
      ),
    ]);
  });

  test('E15: a combined truncated tool frame patches the view and emits the notice', () {
    final call = assistantParts([toolCallPart('c1')]);
    final combined = {
      ...toolFrame('c1', view: fileView('p', 'x')),
      'truncated': true,
      'bytes': 42,
    };
    final d = TranscriptDerivation()
      ..append(call)
      ..append(combined);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.tool,
        id: 'tool:c1',
        toolName: 'read',
        toolArgs: {'path': '/etc/hostname'},
        toolView: const FileView(path: 'p', content: 'x'),
      ),
      TranscriptBlock(
        kind: TranscriptBlockKind.notice,
        id: goldenId(combined, 0),
        text: 'reply too large to display (42 bytes)',
      ),
    ]);
  });

  test('E16: a non-String toolCall id records an anchor a view frame patches', () {
    final call = assistantParts([
      {'type': 'toolCall', 'id': 42, 'name': 'read', 'arguments': {'path': '/x'}},
    ]);
    final synthetic = '${identityHashCode(call)}:0';
    final frame = toolFrame(synthetic, view: fileView('p', 'x'));
    final d = TranscriptDerivation()
      ..append(call)
      ..append(frame);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.tool,
        id: 'tool:$synthetic',
        toolName: 'read',
        toolArgs: {'path': '/x'},
        toolView: const FileView(path: 'p', content: 'x'),
      ),
    ]);
  });

  test('E17: a string-content toolResult yields the expected row', () {
    final call = assistantParts([toolCallPart('c1')]);
    final result = toolResultMsg('c1', content: 'raw text');
    final d = TranscriptDerivation()
      ..append(call)
      ..append(result);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.tool,
        id: 'tool:c1',
        toolName: 'read',
        toolArgs: {'path': '/etc/hostname'},
        text: 'raw text',
        toolResult: result,
      ),
    ]);
  });

  test('E18: appending empty texts emits no rows', () {
    final d = TranscriptDerivation()
      ..append(userText(''))
      ..append(assistantText(''))
      ..append(assistantParts([textPart('')]))
      ..append({'type': 'user', 'text': ''})
      ..append({'type': 'assistant', 'text': ''})
      ..append({'kind': 'status', 'message': ''});
    expect(d.blocks, isEmpty);
  });

  test('E20: rebuilding from the derivation\'s own entries list preserves it', () {
    final a = userText('a');
    final b = assistantParts([toolCallPart('c1')]);
    final d = TranscriptDerivation()
      ..append(a)
      ..append(b);
    final expected = List<TranscriptBlock>.of(d.blocks);

    d.rebuild(d.entries);

    expect(d.entries, orderedEquals([a, b]));
    expectBlocksEqual(d.blocks, expected);
  });

  test('E19: a multi-part assistant message emits rows in order', () {
    final m = assistantParts([
      textPart('a'),
      thinkingPart('t'),
      toolCallPart('c1'),
    ]);
    final d = TranscriptDerivation()..append(m);
    expectBlocksEqual(d.blocks, [
      TranscriptBlock(
        kind: TranscriptBlockKind.text,
        id: goldenId(m, 0),
        text: 'a',
      ),
      TranscriptBlock(
        kind: TranscriptBlockKind.thinking,
        id: goldenId(m, 1),
        text: 't',
      ),
      TranscriptBlock(
        kind: TranscriptBlockKind.tool,
        id: 'tool:c1',
        toolName: 'read',
        toolArgs: {'path': '/etc/hostname'},
      ),
    ]);
  });

  test('E14: the seeded-sequence differential holds', () {
    final rng = Random(0xA11CE);
    const ids = ['c1', 'c2', 'c3'];
    for (var seq = 0; seq < 500; seq++) {
      final length = rng.nextInt(14); // 0..13
      final entries = <Object?>[];
      for (var i = 0; i < length; i++) {
        entries.add(randomEntry(rng, ids));
      }
      final inc = incremental(entries);
      final full = deriveBlocks(entries);
      expectBlocksEqual(inc, full, reason: 'sequence $seq: ${jsonEncode(entries)}');
    }
  });

  // -------------------------------------------------------------------------
  // Client-level identity and wiring.
  // -------------------------------------------------------------------------

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

  test('I1: appending keeps the existing block objects', () async {
    client.subscribe('s1');
    await pumpEventQueue();

    factory.last.receive(
      snapshotFrame('s1', [
        {'type': 'user', 'text': 'a'},
        {'type': 'assistant', 'text': 'b'},
      ]),
    );
    await pumpEventQueue();

    final before = client.transcript('s1')!.blocks;
    expect(before, hasLength(2));

    factory.last.receive(eventMessage({'role': 'user', 'content': 'fresh'}));
    await pumpEventQueue();

    final after = client.transcript('s1')!.blocks;
    expect(after, hasLength(before.length + 1));
    for (var i = 0; i < before.length; i++) {
      expect(
        identical(after[i], before[i]),
        isTrue,
        reason: 'row $i must be the same block instance after one append',
      );
    }
  });

  test('W1: a snapshot replaces the derivation baseline', () async {
    client.subscribe('s1');
    await pumpEventQueue();

    factory.last.receive(
      snapshotFrame('s1', [userText('a'), assistantText('b')]),
    );
    await pumpEventQueue();

    // A second snapshot replaces the baseline outright.
    factory.last.receive(snapshotFrame('s1', [userText('c')]));
    await pumpEventQueue();

    final snapshot = client.transcript('s1')!;
    expectBlocksEqual(snapshot.blocks, deriveBlocks(snapshot.entries));

    final before = snapshot.blocks;
    factory.last.receive(eventMessage(userText('d')));
    await pumpEventQueue();

    final after = client.transcript('s1')!.blocks;
    expectBlocksEqual(after, deriveBlocks(client.transcript('s1')!.entries));
    for (var i = 0; i < before.length; i++) {
      expect(identical(after[i], before[i]), isTrue, reason: 'row $i reused');
    }
  });

  test('W2: the client relayed tool flow matches a whole-list derivation', () async {
    client.subscribe('s1');
    await pumpEventQueue();
    factory.last.receive(snapshotFrame('s1', []));
    await pumpEventQueue();

    factory.last.receive(eventMessage(assistantParts([toolCallPart('c1')])));
    factory.last.receive(
      eventPayload(toolFrame('c1', status: 'running', view: fileView('p', 'x'))),
    );
    factory.last.receive(eventMessage(toolResultMsg('c1')));
    factory.last.receive(
      eventPayload(toolFrame('c1', status: 'done', view: fileView('p', 'y'))),
    );
    await pumpEventQueue();

    final t = client.transcript('s1')!;
    expectBlocksEqual(t.blocks, deriveBlocks(t.entries));
    expect(t.blocks, hasLength(1));
    expectToolView(t.blocks.single.toolView, const FileView(path: 'p', content: 'y'));
  });

  test('W3: append -> snapshot -> append stays incremental and equivalent', () async {
    client.subscribe('s1');
    await pumpEventQueue();

    final e1 = userText('a');
    final e2 = assistantText('b');
    factory.last.receive(snapshotFrame('s1', [e1]));
    await pumpEventQueue();
    factory.last.receive(eventMessage(e2));
    await pumpEventQueue();

    // A snapshot with the same length and the SAME tail object as the live
    // derivation, but a different interior. Only the explicit replacement in
    // `_onSnapshot` can catch this; the length+tail net cannot.
    final e1p = userText('a-prime');
    factory.last.receive(snapshotFrame('s1', [e1p, e2]));
    await pumpEventQueue();

    final snapshot = client.transcript('s1')!;
    expectBlocksEqual(snapshot.blocks, deriveBlocks(snapshot.entries));
    final before = snapshot.blocks;

    final e3 = userText('c');
    factory.last.receive(eventMessage(e3));
    await pumpEventQueue();

    final after = client.transcript('s1')!.blocks;
    expectBlocksEqual(after, deriveBlocks(client.transcript('s1')!.entries));
    for (var i = 0; i < before.length; i++) {
      expect(identical(after[i], before[i]), isTrue, reason: 'row $i reused');
    }
  });
}