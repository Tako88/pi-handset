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

  testWidgets('only visible rows build — a long transcript is lazy', (
    tester,
  ) async {
    final blocks = CountingBlocks(
      List<TranscriptBlock>.generate(
        200,
        (i) => textBlock('b$i', 'message $i'),
      ),
    );

    await tester.pumpWidget(wrap(SessionTranscript(blocks: blocks)));
    await tester.pump();

    // A non-lazy view walks all 200 blocks every build (and rebuilds them on
    // every coalesced frame); a lazy one reads only the rows it shows.
    expect(blocks.reads, lessThan(blocks.length));
    expect(find.textContaining('message 0', findRichText: true), findsOneWidget);
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
