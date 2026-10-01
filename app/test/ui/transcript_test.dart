// Transcript view: the block renderer. A streaming message renders as plain
// `Text` (cheap to rebuild per frame); a completed text block renders through
// `MarkdownBody`. Every block is wrapped in a `RepaintBoundary` keyed by its
// stable block id, and the list is lazy — a long transcript must not build (or
// markdown-parse) every row.

import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/client/transcript.dart';
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

Widget wrap(SessionTranscript transcript) => MaterialApp(
  home: Scaffold(body: TranscriptView(transcript: transcript)),
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

void main() {
  TranscriptBlock toolBlock({
    String id = 'tool:call-1',
    String? toolName = 'read',
    Object? toolArgs = const {'path': '/etc/hostname'},
    Object? toolResult,
    bool isError = false,
    String text = '',
  }) => TranscriptBlock(
    kind: TranscriptBlockKind.tool,
    id: id,
    toolName: toolName,
    toolArgs: toolArgs,
    toolResult: toolResult,
    isError: isError,
    text: text,
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
}
