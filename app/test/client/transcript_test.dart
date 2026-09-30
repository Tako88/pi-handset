// The transcript block model: one ordered list derived from raw relayed
// entries, used identically for the live relay and a snapshot.
//
// The two paths carry the same pi *message* shape in different *entry* shapes:
// live is a bare `{role, content}`; a snapshot entry is wrapped
// `{type: 'message', message: {…}}` and interleaved with bookkeeping rows. The
// unwrap and the ignore list are therefore load-bearing, each with its own
// test.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/transcript.dart';

Map<String, Object?> textBlock(String text) => {'type': 'text', 'text': text};
Map<String, Object?> thinkingBlock(String thinking, {bool redacted = false}) => {
  'type': 'thinking',
  'thinking': thinking,
  if (redacted) 'redacted': true,
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

  test('a relayed status payload becomes a notice', () {
    final blocks = deriveBlocks([
      {'kind': 'status', 'event': 'error', 'message': 'model overloaded'},
    ]);

    expect(blocks, hasLength(1));
    expect(blocks.single.kind, TranscriptBlockKind.notice);
    expect(blocks.single.text, 'model overloaded');
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
}
