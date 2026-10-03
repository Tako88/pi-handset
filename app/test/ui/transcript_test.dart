// Transcript view: the block renderer. A streaming message renders as plain
// `Text` (cheap to rebuild per frame); a completed text block renders through
// `MarkdownBody`. Every block is wrapped in a `RepaintBoundary` keyed by its
// stable block id, and the list is lazy — a long transcript must not build (or
// markdown-parse) every row.

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/client/tool_view.dart';
import 'package:pi_droid/client/transcript.dart';
import 'package:pi_droid/ui/tool_views.dart';
import 'package:pi_droid/ui/transcript_blocks.dart';
import 'package:pi_droid/ui/transcript_view.dart';

/// A `List` that records how many elements the view read. A non-lazy view walks
/// every block on every build; a lazy one reads only what it is asked to show.
class CountingBlocks extends ListBase<TranscriptBlock> {
  CountingBlocks(this._inner);

  final List<TranscriptBlock> _inner;
  int reads = 0;

  @override
  int get length => _inner.length;

  @override
  set length(int value) => _inner.length = value;

  @override
  TranscriptBlock operator [](int index) {
    reads++;
    return _inner[index];
  }

  @override
  void operator []=(int index, TranscriptBlock value) => _inner[index] = value;
}

Widget wrap(SessionTranscript transcript, {VoidCallback? onLoadOlder}) =>
    MaterialApp(
      home: Scaffold(
        body: TranscriptView(
          transcript: transcript,
          onLoadOlder: onLoadOlder ?? () {},
        ),
      ),
    );

TranscriptBlock textBlock(
  String id,
  String text, {
  bool fromUser = false,
  bool complete = true,
}) => TranscriptBlock(
  kind: TranscriptBlockKind.text,
  id: id,
  text: text,
  fromUser: fromUser,
  complete: complete,
);

/// A genuine 1×1 PNG; the widget tests' own `Image` decode is the validator.
final Uint8List pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

TranscriptBlock imageBlock(
  String id,
  Uint8List bytes, {
  bool fromUser = false,
}) => TranscriptBlock(
  kind: TranscriptBlockKind.image,
  id: id,
  imageBytes: bytes,
  fromUser: fromUser,
);

void main() {
  TranscriptBlock toolBlock({
    String id = 'tool:call-1',
    String? toolName = 'read',
    Object? toolArgs = const {'path': '/etc/hostname'},
    Object? toolResult,
    ToolView? toolView,
    bool isError = false,
    String text = '',
  }) => TranscriptBlock(
    kind: TranscriptBlockKind.tool,
    id: id,
    toolName: toolName,
    toolArgs: toolArgs,
    toolResult: toolResult,
    toolView: toolView,
    isError: isError,
    text: text,
  );

  // A file-view tool block with distinguishable per-line bodies, used by the
  // single-expanded-row tests below.
  TranscriptBlock viewTool(
    String id,
    String prefix, {
    bool hasResult = false,
  }) => toolBlock(
    id: id,
    toolName: 'read',
    toolResult: hasResult ? const {'role': 'toolResult'} : null,
    toolView: FileView(
      path: '$prefix.txt',
      content: List.generate(12, (i) => '$prefix$i').join('\n'),
    ),
  );

  testWidgets('a tool block is collapsed with a capped preview and a more-lines count', (
    tester,
  ) async {
    final result = List.generate(12, (i) => 'line $i').join('\n');
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [toolBlock(toolResult: const {'role': 'toolResult'}, text: result)],
        ),
      ),
    );

    expect(find.byType(ToolBlock), findsOneWidget);
    expect(find.text('read'), findsOneWidget);
    expect(find.textContaining('/etc/hostname'), findsOneWidget);
    expect(find.textContaining('line 0'), findsOneWidget);
    expect(
      find.textContaining('line $toolResultPreviewLines'),
      findsNothing,
      reason: 'lines past the cap must stay collapsed',
    );
    expect(
      find.textContaining('(${12 - toolResultPreviewLines} more lines)'),
      findsOneWidget,
    );
  });

  testWidgets('tapping a tool block expands the full result', (tester) async {
    final result = List.generate(12, (i) => 'line $i').join('\n');
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [toolBlock(toolResult: const {'role': 'toolResult'}, text: result)],
        ),
      ),
    );

    await tester.tap(find.byType(ToolBlock));
    await tester.pump();

    expect(find.textContaining('line 11'), findsOneWidget);
    expect(find.textContaining('more lines'), findsNothing);
  });

  testWidgets('an error tool block is styled as an error', (tester) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            toolBlock(
              toolResult: const {'role': 'toolResult', 'isError': true},
              isError: true,
              text: 'boom',
            ),
          ],
        ),
      ),
    );

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.build), findsNothing);
  });

  testWidgets('the TUI full-output note renders verbatim', (tester) async {
    const note =
        '[Showing lines 1-2 of 100. Full output: /tmp/pi-tool-abc.log]';
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            toolBlock(
              toolResult: const {'role': 'toolResult'},
              text: note,
            ),
          ],
        ),
      ),
    );

    expect(find.textContaining('Full output: /tmp/pi-tool-abc.log'), findsOneWidget);
  });

  testWidgets('an [image] placeholder renders on the tool path', (tester) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            toolBlock(
              toolResult: const {'role': 'toolResult'},
              text: '[image]',
            ),
          ],
        ),
      ),
    );

    expect(find.text('[image]'), findsOneWidget);
  });

  test('tool arguments are capped in the header row', () {
    // A `write`/`edit` call carries the whole file body in its arguments; the
    // header must not hand kilobytes of it to layout.
    final huge = 'x' * (toolArgumentsLabelMaxChars * 3);
    final label = argumentsLabel({'path': '/tmp/f', 'content': huge});

    expect(label.length, lessThanOrEqualTo(toolArgumentsLabelMaxChars + 1));
    expect(label.endsWith('…'), isTrue);
    expect(label, isNot(contains('x' * (toolArgumentsLabelMaxChars + 1))));
  });

  test('small tool arguments are shown whole', () {
    expect(argumentsLabel({'path': '/etc/hostname'}), '{"path":"/etc/hostname"}');
    expect(argumentsLabel('raw string'), 'raw string');
    expect(argumentsLabel(null), '');
  });

  testWidgets('a streaming message renders as plain text, not markdown', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const SessionTranscript(streamingText: '**bold**', streaming: true),
      ),
    );

    expect(find.text('**bold**'), findsOneWidget);
    expect(find.byType(MarkdownBody), findsNothing);
  });

  testWidgets('a completed text block renders as markdown', (tester) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(blocks: [textBlock('b1', '**bold**')]),
      ),
    );

    // The raw markdown source must be gone and the parsed content present: a
    // stub that renders the raw text would also satisfy `MarkdownBody exists`.
    expect(find.text('**bold**'), findsNothing);
    expect(find.textContaining('bold', findRichText: true), findsOneWidget);
  });

  testWidgets('an image block renders one Image with its bytes', (tester) async {
    await tester.pumpWidget(
      wrap(SessionTranscript(blocks: [imageBlock('i1', pngBytes)])),
    );

    expect(find.byType(Image), findsOneWidget);
    // `cacheWidth` makes the provider a ResizeImage wrapping the MemoryImage,
    // so the bytes live one level in.
    final provider = tester.widget<Image>(find.byType(Image)).image;
    expect(provider, isA<ResizeImage>());
    expect(((provider as ResizeImage).imageProvider as MemoryImage).bytes, pngBytes);
    expect(find.text('[image]'), findsNothing);
  });

  testWidgets('the decode request preserves the aspect ratio (only the width is capped)', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(SessionTranscript(blocks: [imageBlock('i1', pngBytes)])),
    );

    // With `cacheHeight` also set, ResizeImage defaults to
    // ResizeImagePolicy.exact (BoxFit.fill) and squashes every image into a
    // square. `height == null` is the regression pin for that defect.
    final provider = tester.widget<Image>(find.byType(Image)).image;
    expect(provider, isA<ResizeImage>());
    final resize = provider as ResizeImage;
    expect(resize.width, imageDecodeMaxExtent);
    expect(resize.height, isNull);
  });

  testWidgets('a text block and an image block both render', (tester) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [textBlock('t1', 'hello'), imageBlock('i1', pngBytes)],
        ),
      ),
    );

    expect(find.byType(TextBlock), findsOneWidget);
    expect(find.byType(ImageBlock), findsOneWidget);
  });

  testWidgets('an image derived from a tool result renders an Image', (
    tester,
  ) async {
    // The derivation-to-render path, not just a hand-built image block: a raw
    // tool result goes through `deriveBlocks` and the result must paint.
    final blocks = deriveBlocks([
      {
        'role': 'assistant',
        'content': [
          {
            'type': 'toolCall',
            'id': 'call-1',
            'name': 'read',
            'arguments': {'path': '/tmp/pic.png'},
          },
        ],
      },
      {
        'role': 'toolResult',
        'toolCallId': 'call-1',
        'toolName': 'read',
        'content': [
          {'type': 'text', 'text': 'the picture:'},
          {
            'type': 'image',
            'data':
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
            'mimeType': 'image/png',
          },
        ],
      },
    ]);

    await tester.pumpWidget(wrap(SessionTranscript(blocks: blocks)));

    expect(find.byType(ToolBlock), findsOneWidget);
    expect(find.byType(ImageBlock), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('an image row after a result-less tool row is not expanded', (
    tester,
  ) async {
    // The single-expanded-row derivation keys on the block KIND, not merely a
    // null result: an image row carries no tool result either, and treating it
    // as the in-flight call would collapse the real one.
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          agentState: 'running',
          blocks: [
            viewTool('t1', 'a'),
            imageBlock('tool:t1:img0', pngBytes),
          ],
        ),
      ),
    );

    expect(find.text('a11'), findsOneWidget, reason: 'the tool row expands');
    expect(find.byType(ImageBlock), findsOneWidget);
  });

  testWidgets('a delta does not re-read the whole transcript', (
    tester,
  ) async {
    final blocks = CountingBlocks(
      List<TranscriptBlock>.generate(
        200,
        (i) => textBlock('b$i', 'message $i'),
      ),
    );

    // Opening a tall transcript pins to the newest row; the one-time layout
    // cost of finding the bottom is not what this guards. Laziness that matters
    // is per-frame, so the counter is reset after the open. Deliberate change
    // (M3): the plan restored a natural-order list, whose initial jump to
    // `maxScrollExtent` lays out the rows above the bottom once.
    await tester.pumpWidget(wrap(SessionTranscript(blocks: blocks)));
    await tester.pump();
    expect(
      find.textContaining('message 199', findRichText: true),
      findsOneWidget,
      reason: 'the view opens at the newest row',
    );

    blocks.reads = 0;
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: blocks,
          streaming: true,
          streamingText: 'partial',
        ),
      ),
    );
    await tester.pump();

    // A non-lazy view walks all 200 blocks on every build (and rebuilds them on
    // every coalesced frame); this surface reads ~17 rows for the visible
    // window on a deterministic test layout. The bound is deliberately far
    // below a full walk (200) so a regression that starts reading every block
    // fails while ordinary slack in row count passes. Note it counts
    // `operator[]` reads only, not markdown-parse cost.
    expect(blocks.reads, lessThan(50));
    expect(
      find.textContaining('message 199', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('a truncated history says so above the oldest row it kept', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          truncated: true,
          blocks: [textBlock('a1', 'the oldest row kept')],
        ),
      ),
    );

    // The window is a suffix, so the cut is at the TOP: without this the
    // transcript looks like the session simply began there.
    expect(find.text(TranscriptView.truncatedNotice), findsOneWidget);
    final notice = tester.getTopLeft(find.text(TranscriptView.truncatedNotice));
    final oldest = tester.getTopLeft(find.text('the oldest row kept'));
    expect(notice.dy, lessThan(oldest.dy));
  });

  testWidgets('a complete history carries no truncation notice', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(SessionTranscript(blocks: [textBlock('a1', 'the only row')])),
    );

    expect(find.text(TranscriptView.truncatedNotice), findsNothing);
  });

  testWidgets('a truncated empty history shows the notice, not "no messages"', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const SessionTranscript(truncated: true)));

    expect(find.text(TranscriptView.truncatedNotice), findsOneWidget);
    expect(find.text(TranscriptView.emptyMessage), findsNothing);
  });

  testWidgets('a truncated history with a live stream keeps the stream last', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          truncated: true,
          streaming: true,
          streamingText: 'still arriving',
          blocks: [textBlock('a1', 'kept')],
        ),
      ),
    );

    final notice = tester.getTopLeft(find.text(TranscriptView.truncatedNotice));
    final kept = tester.getTopLeft(find.text('kept'));
    final stream = tester.getTopLeft(find.text('still arriving'));
    expect(notice.dy, lessThan(kept.dy));
    expect(kept.dy, lessThan(stream.dy));
  });

  testWidgets(
    'a truncated history with an older cursor shows the load-older control',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          SessionTranscript(
            truncated: true,
            olderCursor: '2:x',
            blocks: [textBlock('a1', 'the oldest row kept')],
          ),
        ),
      );

      expect(find.byKey(TranscriptView.loadOlderKey), findsOneWidget);
      expect(find.text(TranscriptView.truncatedNotice), findsNothing);
    },
  );

  testWidgets(
    'truncated with no older cursor keeps the static notice and no control',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          SessionTranscript(
            truncated: true,
            blocks: [textBlock('a1', 'the oldest row kept')],
          ),
        ),
      );

      expect(find.text(TranscriptView.truncatedNotice), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
    },
  );

  testWidgets(
    'tapping load-older calls onLoadOlder once, and a loading control ignores taps',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        wrap(
          SessionTranscript(
            truncated: true,
            olderCursor: '2:x',
            blocks: [textBlock('a1', 'the oldest row kept')],
          ),
          onLoadOlder: () => taps++,
        ),
      );

      await tester.tap(find.byKey(TranscriptView.loadOlderKey));
      await tester.pump();
      expect(taps, 1);

      await tester.pumpWidget(
        wrap(
          SessionTranscript(
            truncated: true,
            olderCursor: '2:x',
            historyLoading: true,
            blocks: [textBlock('a1', 'the oldest row kept')],
          ),
          onLoadOlder: () => taps++,
        ),
      );

      expect(find.text(TranscriptView.loadingOlderLabel), findsOneWidget);
      await tester.tap(find.byKey(TranscriptView.loadOlderKey));
      await tester.pump();
      expect(taps, 1, reason: 'a loading control must ignore taps');
    },
  );

  testWidgets('a live reasoning row renders above the in-flight reply', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const SessionTranscript(
          streamingThinking: 'why it works',
          streaming: true,
          streamingText: 'the answer',
        ),
      ),
    );

    expect(find.text('why it works'), findsOneWidget);
    expect(find.text('the answer'), findsOneWidget);
    final reasoning = tester.getTopLeft(find.text('why it works'));
    final reply = tester.getTopLeft(find.text('the answer'));
    expect(reasoning.dy, lessThan(reply.dy));
  });

  testWidgets('the live reasoning row is not a tap target', (tester) async {
    await tester.pumpWidget(
      wrap(const SessionTranscript(streamingThinking: 'why it works')),
    );

    // A control that vanishes (or whose expansion resets) mid-turn is a control
    // changing under the user, so the live row cannot be collapsed.
    await tester.tap(find.text('why it works'));
    await tester.pump();

    expect(find.text('why it works'), findsOneWidget);
  });

  testWidgets('a committed message replaces the live reasoning row', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const SessionTranscript(streamingThinking: 'why it works')),
    );
    expect(find.byKey(TranscriptView.liveThinkingKey), findsOneWidget);

    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            const TranscriptBlock(
              kind: TranscriptBlockKind.thinking,
              id: 't1',
              text: 'why it works',
            ),
            textBlock('a1', 'the answer'),
          ],
        ),
      ),
    );

    // One producer at a time: the live row is gone, and exactly one committed
    // block carries the text.
    expect(find.byKey(TranscriptView.liveThinkingKey), findsNothing);
    expect(find.text('why it works'), findsOneWidget);
  });

  testWidgets('each block is wrapped in a RepaintBoundary keyed by block id', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            textBlock('u1', 'hello', fromUser: true),
            textBlock('a1', 'world'),
          ],
        ),
      ),
    );

    expect(find.byType(TextBlock), findsNWidgets(2));
    for (final id in ['u1', 'a1']) {
      final boundary = find.byKey(ValueKey(id));
      expect(boundary, findsOneWidget);
      expect(
        find.descendant(of: boundary, matching: find.byType(TextBlock)),
        findsOneWidget,
      );
    }
  });

  testWidgets('a row key is stable when a block is prepended', (tester) async {
    final a = textBlock('a', 'a');

    await tester.pumpWidget(wrap(SessionTranscript(blocks: [a])));
    expect(find.byKey(const ValueKey('a')), findsOneWidget);

    // A block id is stable across a prepend; a positional key would renumber
    // every row and defeat the state/boundary stability the keys exist for.
    await tester.pumpWidget(
      wrap(SessionTranscript(blocks: [textBlock('b', 'b'), a])),
    );
    expect(find.byKey(const ValueKey('a')), findsOneWidget);
    expect(find.byKey(const ValueKey('b')), findsOneWidget);
  });

  testWidgets('user and assistant text blocks are aligned apart', (tester) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            textBlock('u1', 'mine', fromUser: true),
            textBlock('a1', 'theirs'),
          ],
        ),
      ),
    );

    final mine = tester.widget<Align>(
      find.ancestor(of: find.text('mine'), matching: find.byType(Align)).first,
    );
    final theirs = tester.widget<Align>(
      find.ancestor(of: find.text('theirs'), matching: find.byType(Align)).first,
    );
    expect(mine.alignment, Alignment.centerRight);
    expect(theirs.alignment, Alignment.centerLeft);
  });

  testWidgets('a thinking block shows its body and collapses on tap', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: const [
            TranscriptBlock(
              kind: TranscriptBlockKind.thinking,
              id: 't1',
              text: 'the private thought',
            ),
          ],
        ),
      ),
    );

    // Visible by default: the body is the point of rendering thinking at all.
    expect(find.textContaining('the private thought'), findsOneWidget);

    await tester.tap(find.byType(ThinkingBlock));
    await tester.pump();

    expect(find.textContaining('the private thought'), findsNothing);
  });

  // -------------------------------------------------------------------------
  // Per-kind bodies (M4 step 19)
  // -------------------------------------------------------------------------

  testWidgets('a diff view renders added and removed lines distinctly', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            toolBlock(
              toolName: 'edit',
              toolArgs: const {'path': 'app/foo.dart'},
              toolResult: const {'role': 'toolResult'},
              toolView: const DiffView(
                path: 'app/foo.dart',
                lines: [
                  DiffLine(diffLineCtx, 'unchanged'),
                  DiffLine(diffLineAdd, 'added line'),
                  DiffLine(diffLineDel, 'removed line'),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    expect(find.text('app/foo.dart +1 −1'), findsOneWidget);
    expect(find.text('+ added line'), findsOneWidget);
    expect(find.text('- removed line'), findsOneWidget);

    Color? colorOf(String text) => tester
        .widget<Container>(
          find.ancestor(of: find.text(text), matching: find.byType(Container)).first,
        )
        .color;
    expect(
      colorOf('+ added line'),
      isNot(colorOf('- removed line')),
      reason: 'an addition and a removal must be distinguishable, not one colour',
    );
  });

  testWidgets('a file view shows its path, range and body', (tester) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            toolBlock(
              toolResult: const {'role': 'toolResult'},
              toolView: const FileView(
                path: 'lib/foo.dart',
                content: 'alpha\nbeta',
                startLine: 10,
                endLine: 11,
              ),
            ),
          ],
        ),
      ),
    );

    expect(find.text('lib/foo.dart:10-11'), findsOneWidget);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
  });

  testWidgets('a command view shows the command and its output', (tester) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            toolBlock(
              toolName: 'bash',
              toolResult: const {'role': 'toolResult'},
              toolView: const CommandView(
                command: 'ls -la',
                output: 'total 0\nfoo.txt',
              ),
            ),
          ],
        ),
      ),
    );

    expect(find.text('ls -la'), findsOneWidget, reason: 'the header summary');
    expect(find.text('\$ ls -la'), findsOneWidget, reason: 'the body pane');
    expect(find.text('foo.txt'), findsOneWidget);
  });

  testWidgets('a matches view groups hits by file with line numbers', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            toolBlock(
              toolName: 'grep',
              toolResult: const {'role': 'toolResult'},
              toolView: const MatchesView(
                matches: [
                  Match(file: 'lib/a.dart', line: 12, text: 'hello'),
                  Match(file: 'lib/b.dart', line: 3, text: 'world'),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    expect(find.text('lib/a.dart'), findsOneWidget);
    expect(find.text('12: hello'), findsOneWidget);
    expect(find.text('lib/b.dart'), findsOneWidget);
    expect(find.text('3: world'), findsOneWidget);
  });

  testWidgets('a path-only match renders the path without a line number', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            toolBlock(
              toolName: 'find',
              toolResult: const {'role': 'toolResult'},
              toolView: const MatchesView(
                matches: [Match(file: 'lib/c.dart', line: 0, text: '')],
              ),
            ),
          ],
        ),
      ),
    );

    expect(find.text('lib/c.dart'), findsOneWidget);
    expect(
      find.textContaining('0:'),
      findsNothing,
      reason: 'a find match carries no line number and must not invent one',
    );
  });

  testWidgets('a table view renders columns and rows', (tester) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            toolBlock(
              toolName: 'ls',
              toolResult: const {'role': 'toolResult'},
              toolView: const TableView(
                columns: ['name', 'type'],
                rows: [
                  ['src', 'directory'],
                  ['a.txt', 'file'],
                ],
              ),
            ),
          ],
        ),
      ),
    );

    expect(find.textContaining('src'), findsOneWidget);
    expect(find.textContaining('a.txt'), findsOneWidget);
    expect(find.textContaining('directory'), findsOneWidget);
  });

  testWidgets('an empty matches view says so, it does not crash', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            toolBlock(
              toolName: 'grep',
              toolResult: const {'role': 'toolResult'},
              toolView: const MatchesView(matches: []),
            ),
          ],
        ),
      ),
    );

    expect(find.text('no matches'), findsWidgets);
  });

  testWidgets('an empty table view says so, it does not crash', (tester) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            toolBlock(
              toolName: 'ls',
              toolResult: const {'role': 'toolResult'},
              toolView: const TableView(columns: ['name', 'type'], rows: []),
            ),
          ],
        ),
      ),
    );

    expect(find.text('empty directory'), findsWidgets);
  });

  testWidgets('a generic view falls back to the result-text preview', (
    tester,
  ) async {
    final result = List.generate(12, (i) => 'line $i').join('\n');
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            toolBlock(
              toolName: 'mytool',
              toolResult: const {'role': 'toolResult'},
              toolView: const GenericView(target: 'target'),
              text: result,
            ),
          ],
        ),
      ),
    );

    expect(find.text('target'), findsOneWidget);
    expect(find.textContaining('line 0'), findsOneWidget);
    expect(find.textContaining('line $toolResultPreviewLines'), findsNothing);
    expect(
      find.textContaining('(${12 - toolResultPreviewLines} more lines)'),
      findsOneWidget,
    );
  });

  // -------------------------------------------------------------------------
  // Truncation marker + capped preview (M4 step 21)
  // -------------------------------------------------------------------------

  testWidgets('a truncated view renders an explicit marker', (tester) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            toolBlock(
              toolResult: const {'role': 'toolResult'},
              toolView: const FileView(
                path: 'a.txt',
                content: 'only line',
                truncated: true,
              ),
            ),
          ],
        ),
      ),
    );

    expect(find.text(ToolViewBody.truncationMarker), findsOneWidget);
  });

  testWidgets('a truncated generic view renders the marker too', (tester) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            toolBlock(
              toolResult: const {'role': 'toolResult'},
              toolView: const GenericView(target: 'blob', truncated: true),
              text: 'payload',
            ),
          ],
        ),
      ),
    );

    expect(find.text(ToolViewBody.truncationMarker), findsOneWidget);
  });

  testWidgets('a long non-truncated view renders a capped preview', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [
            toolBlock(
              toolResult: const {'role': 'toolResult'},
              toolView: FileView(
                path: 'long.txt',
                content: List.generate(12, (i) => 'row $i').join('\n'),
              ),
            ),
          ],
        ),
      ),
    );

    expect(find.text('row 0'), findsOneWidget);
    expect(find.text('row $toolResultPreviewLines'), findsNothing);
    expect(
      find.textContaining('(${12 - toolResultPreviewLines} more lines)'),
      findsOneWidget,
    );
  });

  // -------------------------------------------------------------------------
  // Single-expanded-row derivation (M4 step 20)
  // -------------------------------------------------------------------------

  testWidgets('while running, only the last result-less tool expands', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          agentState: 'running',
          blocks: [viewTool('t1', 'a'), viewTool('t2', 'b')],
        ),
      ),
    );

    expect(find.text('b11'), findsOneWidget, reason: 'the last call is expanded');
    expect(find.text('a11'), findsNothing, reason: 'the earlier call is collapsed');
    expect(
      find.text('a0'),
      findsOneWidget,
      reason: 'a collapsed row still shows its capped preview',
    );
  });

  testWidgets('a completed last tool collapses once no result-less call remains', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          agentState: 'running',
          blocks: [viewTool('t1', 'a', hasResult: true), viewTool('t2', 'b')],
        ),
      ),
    );
    expect(find.text('b11'), findsOneWidget);

    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          agentState: 'running',
          blocks: [viewTool('t1', 'a', hasResult: true), viewTool('t2', 'b', hasResult: true)],
        ),
      ),
    );
    expect(find.text('b11'), findsNothing);
    expect(find.text('a11'), findsNothing);
  });

  testWidgets('a new result-less block expands the newest one', (tester) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          agentState: 'running',
          blocks: [viewTool('t1', 'a', hasResult: true), viewTool('t2', 'b', hasResult: true)],
        ),
      ),
    );
    expect(find.text('c11'), findsNothing);

    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          agentState: 'running',
          blocks: [
            viewTool('t1', 'a', hasResult: true),
            viewTool('t2', 'b', hasResult: true),
            viewTool('t3', 'c'),
          ],
        ),
      ),
    );
    expect(find.text('c11'), findsOneWidget);
    expect(find.text('a11'), findsNothing);
    expect(find.text('b11'), findsNothing);
  });

  testWidgets('a settle collapses every tool row', (tester) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          agentState: 'running',
          blocks: [viewTool('t1', 'a'), viewTool('t2', 'b')],
        ),
      ),
    );
    expect(find.text('b11'), findsOneWidget);

    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          agentState: 'settled',
          blocks: [viewTool('t1', 'a'), viewTool('t2', 'b')],
        ),
      ),
    );
    expect(find.text('a11'), findsNothing);
    expect(find.text('b11'), findsNothing);
  });

  testWidgets('a tap expands exactly one tool row', (tester) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          agentState: 'running',
          blocks: [viewTool('t1', 'a'), viewTool('t2', 'b')],
        ),
      ),
    );
    expect(find.text('b11'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('t1')));
    await tester.pump();

    expect(find.text('a11'), findsOneWidget);
    expect(find.text('b11'), findsNothing, reason: 'only one row may be expanded');
  });

  testWidgets(
    'a view attached to a dropped result row does not expand while another runs',
    (tester) async {
      // The `done` annotation frame arrived (so a view is attached) but the
      // `toolResult` message was dropped, leaving the row result-less. It must
      // not be mistaken for the in-flight call.
      await tester.pumpWidget(
        wrap(
          SessionTranscript(
            agentState: 'running',
            blocks: [viewTool('t1', 'a'), viewTool('t2', 'b')],
          ),
        ),
      );

      expect(find.text('a11'), findsNothing, reason: 'the dropped-result row stays collapsed');
      expect(find.text('b11'), findsOneWidget);
    },
  );

  testWidgets('running expands an earlier outstanding call past a completed one', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          agentState: 'running',
          blocks: [viewTool('t1', 'a'), viewTool('t2', 'b', hasResult: true)],
        ),
      ),
    );

    expect(
      find.text('a11'),
      findsOneWidget,
      reason: 'the last result-less call is earlier in the row list',
    );
    expect(find.text('b11'), findsNothing);
  });

  testWidgets('tapping the expanded row collapses it', (tester) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          agentState: 'running',
          blocks: [viewTool('t1', 'a'), viewTool('t2', 'b')],
        ),
      ),
    );
    expect(find.text('b11'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('t2')));
    await tester.pump();

    expect(find.text('b11'), findsNothing);
    expect(find.text('a11'), findsNothing, reason: 'no other row was expanded');
  });

  testWidgets('a tap survives an unrelated rebuild of the same transcript', (
    tester,
  ) async {
    final blocks = [viewTool('t1', 'a'), viewTool('t2', 'b')];
    await tester.pumpWidget(
      wrap(SessionTranscript(agentState: 'running', blocks: blocks)),
    );
    expect(find.text('b11'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('t1')));
    await tester.pump();
    expect(find.text('a11'), findsOneWidget);

    // A fresh widget with the same content rebuilds TranscriptView. The
    // derivation is unchanged, so it must not stomp the manual tap.
    await tester.pumpWidget(
      wrap(SessionTranscript(agentState: 'running', blocks: blocks)),
    );
    expect(find.text('a11'), findsOneWidget);
    expect(find.text('b11'), findsNothing);
  });
}
