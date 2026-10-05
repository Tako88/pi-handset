// Find-in-transcript: the rows that match the query are tinted, and the
// current match is tinted more strongly than the others. The highlight is a
// surface on the row, so it must not disturb selection or copy.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_models.dart';
import 'package:pi_droid/client/stick_to_bottom.dart';
import 'package:pi_droid/client/transcript.dart';
import 'package:pi_droid/ui/theme.dart';
import 'package:pi_droid/ui/transcript_view.dart';

/// A genuine 1×1 PNG; the widget tests' own Image decode is the validator.
final pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

void main() {
  final copied = <String>[];
  setUp(() => copied.clear());

  Widget wrap(
    SessionTranscript transcript, {
    TranscriptSearch search = TranscriptSearch.none,
  }) => MaterialApp(
    theme: piTheme(Brightness.dark),
    home: Scaffold(
      body: TranscriptView(
        transcript: transcript,
        onLoadOlder: () {},
        onCopyText: copied.add,
        search: search,
      ),
    ),
  );

  TranscriptBlock textBlock(String id, String text) => TranscriptBlock(
    kind: TranscriptBlockKind.text,
    id: id,
    text: text,
  );

  TranscriptBlock imageBlock(String id) => TranscriptBlock(
    kind: TranscriptBlockKind.image,
    id: id,
    imageBytes: pngBytes,
  );

  TranscriptBlock toolBlock(String id) => TranscriptBlock(
    kind: TranscriptBlockKind.tool,
    id: id,
    toolName: 'read',
    toolArgs: const {'path': 'foo.txt'},
    toolResult: const {'content': 'file body'},
    text: 'file body',
  );

  TranscriptBlock thinkingBlock(String id) => TranscriptBlock(
    kind: TranscriptBlockKind.thinking,
    id: id,
    text: 'a thought',
  );

  TranscriptBlock noticeBlock(String id) => TranscriptBlock(
    kind: TranscriptBlockKind.notice,
    id: id,
    text: 'a note',
  );

  /// The [DocumentRow] rendered inside the row keyed by [id].
  DocumentRow rowFor(WidgetTester tester, String id) => tester.widget<DocumentRow>(
    find.descendant(
      of: find.byKey(ValueKey(id)),
      matching: find.byType(DocumentRow),
    ),
  );

  /// Uniform-height text rows, ids `b0..b{count-1}` — taller than the 600px
  /// test viewport.
  SessionTranscript tall(int count) => SessionTranscript(
    blocks: [
      for (var i = 0; i < count; i++)
        TranscriptBlock(
          kind: TranscriptBlockKind.text,
          id: 'b$i',
          text: 'message $i',
        ),
    ],
  );

  /// Variable-height rows: every fifth is a tall multiline block. Copied from
  /// `scroll_test.dart`, where it proves a one-shot jump targets an estimate
  /// and lands short — the shape the convergent seek must handle.
  SessionTranscript mixed(int count) => SessionTranscript(
    blocks: [
      for (var i = 0; i < count; i++)
        TranscriptBlock(
          kind: TranscriptBlockKind.text,
          id: 'b$i',
          text: i % 5 == 4
              ? List.generate(30, (l) => 'tall $i line $l').join('\n')
              : 'message $i',
        ),
    ],
  );

  double scrollOffset(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;

  /// Uses the app's own definition of "following the bottom" (the
  /// [atBottomThreshold] slack the follow-jump rests within), not exact pixels.
  bool atBottom(WidgetTester tester) {
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    return isAtBottom(position.pixels, position.maxScrollExtent);
  }

  /// Whether the row keyed by [id] is built and its rect intersects the list's.
  bool rowVisible(WidgetTester tester, String id) {
    final row = find.byKey(ValueKey(id));
    if (row.evaluate().isEmpty) return false;
    return tester.getRect(row).overlaps(tester.getRect(find.byType(ListView)));
  }

  testWidgets('a view with no search tints no row', (tester) async {
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: [textBlock('t1', 'one'), textBlock('t2', 'two')],
        ),
      ),
    );

    final rows = tester.widgetList<DocumentRow>(find.byType(DocumentRow));
    expect(rows, isNotEmpty);
    expect(rows.every((row) => row.highlight == null), isTrue);
  });

  testWidgets('a matching row is tinted and a non-match is not', (
    tester,
  ) async {
    final t1 = textBlock('t1', 'hello world');
    final t2 = textBlock('t2', 'nothing here');
    await tester.pumpWidget(
      wrap(
        SessionTranscript(blocks: [t1, t2]),
        search: TranscriptSearch(open: true, matches: [t1], current: 0),
      ),
    );

    expect(rowFor(tester, 't1').highlight, isNotNull);
    expect(rowFor(tester, 't2').highlight, isNull);
  });

  testWidgets('the current match is tinted more strongly than the other hits', (
    tester,
  ) async {
    final t1 = textBlock('t1', 'hello one');
    final t2 = textBlock('t2', 'hello two');
    await tester.pumpWidget(
      wrap(
        SessionTranscript(blocks: [t1, t2]),
        search: TranscriptSearch(open: true, matches: [t1, t2], current: 0),
      ),
    );

    final current = rowFor(tester, 't1').highlight!;
    final other = rowFor(tester, 't2').highlight!;
    expect(current.a, TranscriptView.currentHitHighlightAlpha);
    expect(other.a, TranscriptView.hitHighlightAlpha);
    expect(current.a, greaterThan(other.a));
  });

  testWidgets('an image block is never tinted', (tester) async {
    final image = imageBlock('i1');
    final t1 = textBlock('t1', 'hello');
    await tester.pumpWidget(
      wrap(
        SessionTranscript(blocks: [image, t1]),
        search: TranscriptSearch(open: true, matches: [image, t1], current: 0),
      ),
    );

    expect(rowFor(tester, 'i1').highlight, isNull);
    expect(rowFor(tester, 't1').highlight, isNotNull);
  });

  testWidgets('a tool hit keeps its state rule under the tint', (
    tester,
  ) async {
    // The tint wins the tool row's surface, so the running/succeeded/failed
    // signal survives only via the rule. Deleting `rule: state` from the tool
    // branch, or `highlight: highlight` here, must redden this test; every
    // other highlight test pumps only text/image rows.
    final tool = toolBlock('tool1');
    await tester.pumpWidget(
      wrap(
        SessionTranscript(blocks: [tool]),
        search: TranscriptSearch(open: true, matches: [tool], current: 0),
      ),
    );

    final row = rowFor(tester, 'tool1');
    expect(row.highlight, isNotNull);
    expect(row.rule, isNotNull, reason: 'the state rule must survive the tint');
  });

  testWidgets('a thinking hit forwards the tint to its row', (tester) async {
    final thinking = thinkingBlock('th1');
    await tester.pumpWidget(
      wrap(
        SessionTranscript(blocks: [thinking]),
        search: TranscriptSearch(open: true, matches: [thinking], current: 0),
      ),
    );

    expect(rowFor(tester, 'th1').highlight, isNotNull);
  });

  testWidgets('a notice hit forwards the tint to its row', (tester) async {
    final notice = noticeBlock('n1');
    await tester.pumpWidget(
      wrap(
        SessionTranscript(blocks: [notice]),
        search: TranscriptSearch(open: true, matches: [notice], current: 0),
      ),
    );

    expect(rowFor(tester, 'n1').highlight, isNotNull);
  });

  testWidgets('selection still works on a highlighted row', (tester) async {
    final block = textBlock('t1', 'copy me please');
    await tester.pumpWidget(
      wrap(
        SessionTranscript(blocks: [block]),
        search: TranscriptSearch(open: true, matches: [block], current: 0),
      ),
    );

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('t1')),
        matching: find.byType(SelectionArea),
      ),
      findsOneWidget,
    );

    await tester.longPress(
      find.textContaining('copy me please', findRichText: true).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(TranscriptView.copyMessageLabel));
    await tester.pumpAndSettle();

    expect(copied, [copyTextForBlock(block)]);
  });

  testWidgets(
    'a late match is revealed, and stepping to another moves the view',
    (tester) async {
      final transcript = tall(60);
      final late = transcript.blocks[55];
      await tester.pumpWidget(
        wrap(
          transcript,
          search: TranscriptSearch(open: true, matches: [late], current: 0),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        rowVisible(tester, 'b55'),
        isTrue,
        reason: 'the current match must be scrolled into view',
      );

      final early = transcript.blocks[5];
      final revealed = scrollOffset(tester);
      await tester.pumpWidget(
        wrap(
          transcript,
          search: TranscriptSearch(
            open: true,
            matches: [late, early],
            current: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        rowVisible(tester, 'b5'),
        isTrue,
        reason: 'stepping to another match must reveal it',
      );
      expect(
        scrollOffset(tester),
        isNot(revealed),
        reason: 'the view must move to the new match',
      );
    },
  );

  testWidgets('the seek converges on a variable-height transcript', (
    tester,
  ) async {
    final transcript = mixed(60);
    final late = transcript.blocks[50];
    await tester.pumpWidget(
      wrap(
        transcript,
        search: TranscriptSearch(open: true, matches: [late], current: 0),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      rowVisible(tester, 'b50'),
      isTrue,
      reason:
          'the bounded, convergent seek must reach a match in a variable-height '
          'transcript (a one-shot estimate lands short)',
    );
    expect(
      rowFor(tester, 'b50').highlight,
      isNotNull,
      reason: 'a built current-match row must carry the tint',
    );
  });

  testWidgets('an open search pauses following, and closing it resumes', (
    tester,
  ) async {
    final transcript = tall(60);
    final match = transcript.blocks[10];

    await tester.pumpWidget(wrap(transcript));
    await tester.pump();
    expect(atBottom(tester), isTrue);

    // Open the search on a match away from the bottom.
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: transcript.blocks,
          streaming: true,
          streamingText: 'partial one',
        ),
        search: TranscriptSearch(open: true, matches: [match], current: 0),
      ),
    );
    await tester.pumpAndSettle();
    final revealed = scrollOffset(tester);
    expect(find.byIcon(Icons.arrow_downward), findsNothing);

    // A stream delta must not yank the view while the search is open.
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: transcript.blocks,
          streaming: true,
          streamingText: 'partial one\npartial two',
        ),
        search: TranscriptSearch(open: true, matches: [match], current: 0),
      ),
    );
    await tester.pump();

    expect(
      scrollOffset(tester),
      revealed,
      reason: 'streaming while searching must not move the view',
    );
    expect(find.byIcon(Icons.arrow_downward), findsNothing);

    // Closing the search restores following and returns to the bottom.
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: transcript.blocks,
          streaming: true,
          streamingText: 'partial one\npartial two',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(atBottom(tester), isTrue);
  });
}
