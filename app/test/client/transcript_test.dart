// The transcript block model: one ordered list derived from raw relayed
// entries, used identically for the live relay and a snapshot.
//
// The two paths carry the same pi *message* shape in different *entry* shapes:
// live is a bare `{role, content}`; a snapshot entry is wrapped
// `{type: 'message', message: {…}}` and interleaved with bookkeeping rows. The
// unwrap and the ignore list are therefore load-bearing, each with its own
// test.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/tool_view.dart';
import 'package:pi_droid/client/transcript.dart';

Map<String, Object?> textBlock(String text) => {'type': 'text', 'text': text};
Map<String, Object?> thinkingBlock(String thinking, {bool redacted = false}) => {
  'type': 'thinking',
  'thinking': thinking,
  if (redacted) 'redacted': true,
};
Map<String, Object?> toolCallBlock({
  required String id,
  String name = 'read',
  Map<String, Object?> arguments = const {'path': '/etc/hostname'},
}) => {
  'type': 'toolCall',
  'id': id,
  'name': name,
  'arguments': arguments,
};
Map<String, Object?> toolResultMessage({
  required String toolCallId,
  String toolName = 'read',
  Object? content,
  bool isError = false,
}) => {
  'role': 'toolResult',
  'toolCallId': toolCallId,
  'toolName': toolName,
  'content': content ?? [textBlock('file body')],
  'isError': isError,
};

Map<String, Object?> toolFrame({
  required String toolCallId,
  String name = 'read',
  String status = 'done',
  Object? view,
}) => {
  'kind': 'tool',
  'toolCallId': toolCallId,
  'name': name,
  'status': status,
  'view': ?view,
};

Map<String, Object?> assistantWith(Object? content) => {
  'role': 'assistant',
  'content': content,
};

void main() {
  test('a bare user message with string content is one own-message block', () {
    final blocks = deriveBlocks([
      {'role': 'user', 'content': 'hello'},
    ]);

    expect(blocks, hasLength(1));
    expect(blocks.single.kind, TranscriptBlockKind.text);
    expect(blocks.single.text, 'hello');
    expect(blocks.single.fromUser, isTrue);
  });

  test('a user message with block content is one own-message block', () {
    final blocks = deriveBlocks([
      {
        'role': 'user',
        'content': [textBlock('part one'), textBlock(' part two')],
      },
    ]);

    expect(blocks, hasLength(2));
    expect(blocks.every((block) => block.fromUser), isTrue);
    expect(blocks.map((block) => block.text), ['part one', ' part two']);
  });

  test('assistant text, consecutive thinking and a tool call become one each', () {
    final blocks = deriveBlocks([
      {
        'role': 'assistant',
        'content': [
          textBlock('the answer'),
          thinkingBlock('first thought'),
          thinkingBlock('second thought'),
          {
            'type': 'toolCall',
            'id': 'call-1',
            'name': 'read',
            'arguments': {'path': '/etc/hostname'},
          },
        ],
      },
    ]);

    expect(blocks.map((block) => block.kind), [
      TranscriptBlockKind.text,
      TranscriptBlockKind.thinking,
      TranscriptBlockKind.tool,
    ]);
    // The thinking BODY is asserted, not merely that a thinking block exists:
    // reading the wrong field would render an empty row and still pass the
    // latter.
    expect(blocks[1].text, 'first thought\n\nsecond thought');
    expect(blocks[2].toolName, 'read');
    expect(blocks[2].toolArgs, {'path': '/etc/hostname'});
    expect(blocks[2].toolResult, isNull);
  });

  test('a flattened {type, text} entry becomes a text block with the right origin', () {
    // The history/snapshot projection can flatten a message to this shape.
    final blocks = deriveBlocks([
      {'type': 'user', 'text': 'hello there'},
      {'type': 'assistant', 'text': 'hi back'},
    ]);

    expect(blocks.map((block) => block.kind), [
      TranscriptBlockKind.text,
      TranscriptBlockKind.text,
    ]);
    expect(blocks[0].text, 'hello there');
    expect(blocks[0].fromUser, isTrue);
    expect(blocks[1].text, 'hi back');
    expect(blocks[1].fromUser, isFalse);
  });

  test('a wrapped snapshot entry derives the same blocks as the bare live shape', () {
    final message = {
      'role': 'assistant',
      'content': [textBlock('the answer')],
    };
    final wrapped = {
      'type': 'message',
      'id': '9',
      'parentId': '8',
      'message': message,
    };

    final wrappedBlocks = deriveBlocks([wrapped]);
    final bareBlocks = deriveBlocks([message]);
    expect(
      wrappedBlocks.map((block) => block.kind),
      bareBlocks.map((block) => block.kind),
    );
    expect(
      wrappedBlocks.map((block) => block.text),
      bareBlocks.map((block) => block.text),
    );
    expect(wrappedBlocks.first.kind, TranscriptBlockKind.text);
  });

  test('a wrapped snapshot entry unwraps text, thinking and a tool call', () {
    final wrapped = {
      'type': 'message',
      'id': '9',
      'parentId': '8',
      'message': {
        'role': 'assistant',
        'content': [
          textBlock('the answer'),
          thinkingBlock('a thought'),
          {
            'type': 'toolCall',
            'id': 'call-1',
            'name': 'read',
            'arguments': {'path': '/etc/hostname'},
          },
        ],
      },
    };

    final blocks = deriveBlocks([wrapped]);

    // A renderer that unwraps only for text would drop the wrapped thinking and
    // tool call; assert the full shape, not just the text row.
    expect(blocks.map((block) => block.kind), [
      TranscriptBlockKind.text,
      TranscriptBlockKind.thinking,
      TranscriptBlockKind.tool,
    ]);
    expect(blocks[0].text, 'the answer');
    expect(blocks[1].text, 'a thought');
    expect(blocks[2].toolName, 'read');
    expect(blocks[2].toolArgs, {'path': '/etc/hostname'});
  });

  test('bookkeeping and non-message roles derive no blocks', () {
    final blocks = deriveBlocks(const [
      {'type': 'model_change', 'provider': 'faux', 'modelId': 'faux-1'},
      {'type': 'thinking_level_change', 'thinkingLevel': 'off'},
      {'type': 'label', 'label': 'work'},
      {'type': 'session', 'id': 's1'},
      {
        'type': 'message',
        'message': {'role': 'system', 'content': 'the system prompt'},
      },
      {
        'type': 'message',
        'message': {'role': 'custom', 'content': 'extension note'},
      },
    ]);

    expect(blocks, isEmpty);
  });

  test('empty text and empty thinking content derive no blocks', () {
    final blocks = deriveBlocks([
      {
        'role': 'assistant',
        'content': [textBlock(''), thinkingBlock('   ')],
      },
    ]);

    expect(blocks, isEmpty);
  });

  test('redacted thinking renders a placeholder, never the opaque body', () {
    final blocks = deriveBlocks([
      {
        'role': 'assistant',
        'content': [thinkingBlock('ABASE64BLOB', redacted: true)],
      },
    ]);

    expect(blocks, hasLength(1));
    expect(blocks.single.kind, TranscriptBlockKind.thinking);
    expect(blocks.single.text, '[reasoning redacted]');
  });

  test('an image content block becomes an [image] placeholder', () {
    final blocks = deriveBlocks([
      {
        'role': 'assistant',
        'content': [
          textBlock('look:'),
          {'type': 'image', 'data': 'BASE64', 'mimeType': 'image/png'},
        ],
      },
    ]);

    expect(blocks.map((block) => block.text), ['look:', '[image]']);
  });

  test('a truncated relay message becomes a notice naming the byte count', () {
    final blocks = deriveBlocks([
      {'truncated': true, 'bytes': 123456},
    ]);

    expect(blocks, hasLength(1));
    expect(blocks.single.kind, TranscriptBlockKind.notice);
    expect(blocks.single.text, contains('123456'));
  });

  test('an oversize toolResult marker becomes a notice, never a paired result', () {
    // `boundMessage` replaces a >256 KB toolResult whole with `{truncated,bytes}`.
    // The call still relayed, so its block stays unresolved; the marker is an
    // honest notice, not a tool block carrying the raw output.
    final blocks = deriveBlocks([
      assistantWith([toolCallBlock(id: 'call-1')]),
      {'truncated': true, 'bytes': 300000},
    ]);

    final notices = blocks
        .where((block) => block.kind == TranscriptBlockKind.notice)
        .toList();
    expect(notices, hasLength(1));
    expect(notices.single.text, contains('300000'));
    final tools = blocks
        .where((block) => block.kind == TranscriptBlockKind.tool)
        .toList();
    expect(tools, hasLength(1), reason: 'the call itself still renders');
    expect(tools.single.toolResult, isNull, reason: 'the result was dropped whole');
    expect(
      blocks.any(
        (block) =>
            block.kind == TranscriptBlockKind.tool && block.toolResult != null,
      ),
      isFalse,
    );
  });

  test('a relayed status payload becomes a notice', () {
    final blocks = deriveBlocks([
      {'kind': 'status', 'event': 'error', 'message': 'model overloaded'},
    ]);

    expect(blocks, hasLength(1));
    expect(blocks.single.kind, TranscriptBlockKind.notice);
    expect(blocks.single.text, 'model overloaded');
  });

  test('a tool call and a later result pair into one block at the call', () {
    final blocks = deriveBlocks([
      assistantWith([toolCallBlock(id: 'call-1')]),
      toolResultMessage(toolCallId: 'call-1', content: [textBlock('file body')]),
    ]);

    expect(blocks, hasLength(1), reason: 'the result must not also render standalone');
    expect(blocks.single.kind, TranscriptBlockKind.tool);
    expect(blocks.single.toolName, 'read');
    expect(blocks.single.toolResult, isNotNull);
    expect(blocks.single.isError, isFalse);
    expect(blocks.single.text, contains('file body'));
  });

  test('a tool call with no result keeps a null result', () {
    final blocks = deriveBlocks([
      assistantWith([toolCallBlock(id: 'call-1')]),
    ]);

    expect(blocks, hasLength(1));
    expect(blocks.single.kind, TranscriptBlockKind.tool);
    expect(blocks.single.toolResult, isNull);
  });

  test('a result with no matching call becomes a standalone tool block', () {
    final blocks = deriveBlocks([
      toolResultMessage(
        toolCallId: 'orphan-1',
        toolName: 'grep',
        content: [textBlock('orphan output')],
      ),
    ]);

    expect(blocks, hasLength(1), reason: 'an orphan result must not vanish');
    expect(blocks.single.kind, TranscriptBlockKind.tool);
    expect(blocks.single.toolName, 'grep');
    expect(blocks.single.toolResult, isNotNull);
    expect(blocks.single.text, contains('orphan output'));
  });

  test('a duplicate toolCallId pairs the first result and drops the second', () {
    final blocks = deriveBlocks([
      assistantWith([toolCallBlock(id: 'call-1')]),
      toolResultMessage(toolCallId: 'call-1', content: [textBlock('first result')]),
      toolResultMessage(toolCallId: 'call-1', content: [textBlock('second result')]),
    ]);

    // A last-wins implementation passes every obvious case; only this one
    // distinguishes it from first-wins.
    expect(blocks, hasLength(1), reason: 'the duplicate result must not add a block');
    expect(blocks.single.kind, TranscriptBlockKind.tool);
    expect(blocks.single.text, contains('first result'));
    expect(blocks.single.text, isNot(contains('second result')));
  });

  test('a result that arrives before its call still pairs', () {
    // Pass 1 indexes the whole list before pass 2 emits, so order must not
    // matter; a single-pass implementation fails this.
    final blocks = deriveBlocks([
      toolResultMessage(toolCallId: 'call-1', content: [textBlock('file body')]),
      assistantWith([toolCallBlock(id: 'call-1')]),
    ]);

    expect(blocks, hasLength(1), reason: 'the early result must not render standalone');
    expect(blocks.single.kind, TranscriptBlockKind.tool);
    expect(blocks.single.toolResult, isNotNull);
    expect(blocks.single.text, contains('file body'));
  });

  test('two calls with one result leave the unresolved call null', () {
    final blocks = deriveBlocks([
      assistantWith([toolCallBlock(id: 'call-1'), toolCallBlock(id: 'call-2')]),
      toolResultMessage(toolCallId: 'call-1'),
    ]);

    expect(blocks, hasLength(2));
    expect(blocks[0].toolResult, isNotNull);
    expect(blocks[1].toolResult, isNull, reason: 'call-2 got no result');
  });

  test('a result whose id does not match the call stays an orphan', () {
    // An index-based pairing (n-th result to n-th call) passes every obvious
    // case and would wrongly attach this result to call-1.
    final blocks = deriveBlocks([
      assistantWith([toolCallBlock(id: 'call-1')]),
      toolResultMessage(
        toolCallId: 'call-2',
        toolName: 'grep',
        content: [textBlock('other output')],
      ),
    ]);

    expect(blocks, hasLength(2), reason: 'a mismatched result must not pair');
    expect(blocks[0].kind, TranscriptBlockKind.tool);
    expect(blocks[0].toolName, 'read');
    expect(blocks[0].toolResult, isNull, reason: 'call-1 has no matching result');
    expect(blocks[1].kind, TranscriptBlockKind.tool);
    expect(blocks[1].toolName, 'grep');
    expect(blocks[1].text, contains('other output'));
  });

  test('two assistant messages with the same call id get distinct block ids', () {
    // A forked branch can surface the same call twice; two blocks with the same
    // `id` make the view's ValueKey collide and attach state to the wrong row.
    final blocks = deriveBlocks([
      assistantWith([toolCallBlock(id: 'call-1')]),
      assistantWith([toolCallBlock(id: 'call-1')]),
    ]);

    expect(blocks, hasLength(2));
    expect(blocks.map((block) => block.id).toSet(), hasLength(2));
    expect(blocks.first.id, 'tool:call-1', reason: 'the first keeps the canonical id');
  });

  test('two orphan results with the same call id get distinct block ids', () {
    final blocks = deriveBlocks([
      toolResultMessage(toolCallId: 'orphan-1'),
      toolResultMessage(toolCallId: 'orphan-1'),
    ]);

    expect(blocks, hasLength(2));
    expect(blocks.map((block) => block.id).toSet(), hasLength(2));
    expect(blocks.first.id, 'tool:orphan-1');
  });

  test('an error result marks the paired block as an error', () {
    final blocks = deriveBlocks([
      assistantWith([toolCallBlock(id: 'call-1')]),
      toolResultMessage(toolCallId: 'call-1', isError: true, content: [textBlock('boom')]),
    ]);

    expect(blocks.single.isError, isTrue);
  });

  test('an image in a tool result becomes an [image] placeholder', () {
    final blocks = deriveBlocks([
      assistantWith([toolCallBlock(id: 'call-1')]),
      toolResultMessage(
        toolCallId: 'call-1',
        content: [
          textBlock('see:'),
          {'type': 'image', 'data': 'BASE64', 'mimeType': 'image/png'},
        ],
      ),
    ]);

    expect(blocks.single.text, contains('[image]'));
  });

  test('two text parts in a tool result join on a newline', () {
    // `[a, b]` concatenated without a separator renders `ab`, welding words
    // together; the parts are separate lines of output.
    final blocks = deriveBlocks([
      assistantWith([toolCallBlock(id: 'call-1')]),
      toolResultMessage(
        toolCallId: 'call-1',
        content: [textBlock('a'), textBlock('b')],
      ),
    ]);

    expect(blocks.single.text, 'a\nb');
  });

  test('a tool result preview caps at the generic line limit and counts the rest', () {
    final lines = List.generate(12, (i) => 'line $i');
    final preview = previewToolResult(lines.join('\n'));

    expect(preview.isTruncated, isTrue);
    expect(preview.shown.split('\n'), hasLength(toolResultPreviewLines));
    expect(preview.hiddenLines, 12 - toolResultPreviewLines);
  });

  test('a short tool result preview is not truncated', () {
    final preview = previewToolResult('one\ntwo');

    expect(preview.isTruncated, isFalse);
    expect(preview.shown, 'one\ntwo');
    expect(preview.hiddenLines, 0);
  });

  test('an empty tool result preview is empty and not truncated', () {
    final preview = previewToolResult('');

    expect(preview.shown, '');
    expect(preview.isTruncated, isFalse);
    expect(preview.hiddenLines, 0);
  });

  test('a tool result of exactly the cap is not truncated', () {
    // The off-by-one (`<` vs `<=`) is visible only at exactly the cap.
    final text = List.generate(
      toolResultPreviewLines,
      (i) => 'line $i',
    ).join('\n');
    final preview = previewToolResult(text);

    expect(preview.isTruncated, isFalse);
    expect(preview.shown, text);
    expect(preview.hiddenLines, 0);
  });

  test('a tool result one over the cap hides exactly one line', () {
    final lines = List.generate(toolResultPreviewLines + 1, (i) => 'line $i');
    final preview = previewToolResult(lines.join('\n'));

    expect(preview.isTruncated, isTrue);
    expect(preview.shown, lines.take(toolResultPreviewLines).join('\n'));
    expect(preview.hiddenLines, 1);
  });

  test('block ids are distinct and stable across derivation calls', () {
    final entries = <Object?>[
      {'role': 'user', 'content': 'hello'},
      {
        'role': 'assistant',
        'content': [textBlock('a'), textBlock('b')],
      },
    ];

    final first = deriveBlocks(entries).map((block) => block.id).toList();
    final second = deriveBlocks(entries).map((block) => block.id).toList();

    expect(first, hasLength(3));
    expect(first.toSet(), hasLength(3));
    expect(second, first);
  });

  test('a kind:tool frame attaches its view to the paired call block', () {
    final blocks = deriveBlocks([
      assistantWith([toolCallBlock(id: 'call-1', name: 'edit')]),
      toolFrame(
        toolCallId: 'call-1',
        name: 'edit',
        view: {
          'type': 'diff',
          'path': 'app/foo.dart',
          'lines': [
            {'kind': 'add', 'text': 'x'},
          ],
        },
      ),
    ]);

    expect(blocks, hasLength(1), reason: 'the annotation is not its own row');
    expect(blocks.single.kind, TranscriptBlockKind.tool);
    expect(blocks.single.toolView, isA<DiffView>());
    expect((blocks.single.toolView as DiffView).path, 'app/foo.dart');
  });

  test('the later of two kind:tool frames for one id wins', () {
    // running→done: the done frame carries the real view and must replace the
    // input-only one the running frame showed.
    final blocks = deriveBlocks([
      toolFrame(
        toolCallId: 'call-1',
        name: 'edit',
        status: 'running',
        view: {'type': 'diff', 'path': 'running.dart', 'lines': <Object?>[]},
      ),
      toolFrame(
        toolCallId: 'call-1',
        name: 'edit',
        status: 'done',
        view: {'type': 'diff', 'path': 'done.dart', 'lines': <Object?>[]},
      ),
      assistantWith([toolCallBlock(id: 'call-1', name: 'edit')]),
    ]);

    expect(blocks, hasLength(1));
    expect((blocks.single.toolView as DiffView).path, 'done.dart');
  });

  test('a viewless later frame does not erase an earlier view', () {
    // A done frame may carry no view at all; the running frame's view must
    // survive it. Only the presence of a view replaces a view.
    final blocks = deriveBlocks([
      toolFrame(
        toolCallId: 'call-1',
        name: 'edit',
        status: 'running',
        view: {'type': 'diff', 'path': 'running.dart', 'lines': <Object?>[]},
      ),
      toolFrame(toolCallId: 'call-1', name: 'edit', status: 'done'),
      assistantWith([toolCallBlock(id: 'call-1', name: 'edit')]),
    ]);

    expect(blocks, hasLength(1));
    expect((blocks.single.toolView as DiffView).path, 'running.dart');
  });

  test('a bare kind:tool frame emits no block of its own', () {
    final blocks = deriveBlocks([
      assistantWith([toolCallBlock(id: 'call-1')]),
      toolFrame(toolCallId: 'call-1', view: {'type': 'generic'}),
    ]);

    expect(blocks, hasLength(1), reason: 'only the call renders');
    expect(blocks.single.toolName, 'read');
  });

  test('a paired call and result with no kind:tool frame leaves toolView null', () {
    // Version skew: an older bridge emits no view, and the block still renders
    // (through the generic preview) rather than being dropped.
    final blocks = deriveBlocks([
      assistantWith([toolCallBlock(id: 'call-1')]),
      toolResultMessage(toolCallId: 'call-1'),
    ]);

    expect(blocks, hasLength(1));
    expect(blocks.single.toolResult, isNotNull);
    expect(blocks.single.toolView, isNull);
  });

  test('a snapshot history entry list attaches an injected view', () {
    final blocks = deriveBlocks([
      {
        'type': 'message',
        'message': assistantWith([toolCallBlock(id: 'call-1')]),
      },
      toolFrame(
        toolCallId: 'call-1',
        name: 'read',
        view: {'type': 'file', 'path': 'a.dart', 'content': 'x'},
      ),
    ]);

    expect(blocks, hasLength(1));
    expect(blocks.single.toolView, isA<FileView>());
    expect((blocks.single.toolView as FileView).path, 'a.dart');
  });

  test('a standalone orphan result also gets its view attached', () {
    final blocks = deriveBlocks([
      toolResultMessage(
        toolCallId: 'orphan-1',
        toolName: 'grep',
        content: [textBlock('No matches found')],
      ),
      toolFrame(
        toolCallId: 'orphan-1',
        name: 'grep',
        view: {'type': 'matches', 'matches': <Object?>[]},
      ),
    ]);

    expect(blocks, hasLength(1));
    expect(blocks.single.toolView, isA<MatchesView>());
    expect((blocks.single.toolView as MatchesView).matches, isEmpty);
  });

  test('a result first-wins while a view last-wins — the two rules are opposite', () {
    // Two opposite rules in one test so neither can be "simplified" into the
    // other: resultsById keeps the first duplicate (fork semantics), viewsById
    // keeps the last (running→done).
    final blocks = deriveBlocks([
      toolFrame(
        toolCallId: 'call-1',
        name: 'edit',
        status: 'running',
        view: {'type': 'diff', 'path': 'first.dart', 'lines': <Object?>[]},
      ),
      toolResultMessage(toolCallId: 'call-1', content: [textBlock('first result')]),
      toolResultMessage(toolCallId: 'call-1', content: [textBlock('second result')]),
      toolFrame(
        toolCallId: 'call-1',
        name: 'edit',
        status: 'done',
        view: {'type': 'diff', 'path': 'last.dart', 'lines': <Object?>[]},
      ),
      assistantWith([toolCallBlock(id: 'call-1', name: 'edit')]),
    ]);

    expect(blocks, hasLength(1));
    expect(blocks.single.text, contains('first result'));
    expect(blocks.single.text, isNot(contains('second result')));
    expect((blocks.single.toolView as DiffView).path, 'last.dart');
  });
}
