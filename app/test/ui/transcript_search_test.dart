// Find-in-transcript: the rows that match the query are tinted, and the
// current match is tinted more strongly than the others. The highlight is a
// surface on the row, so it must not disturb selection or copy.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/hub_models.dart';
import 'package:pi_handset/client/stick_to_bottom.dart';
import 'package:pi_handset/client/transcript.dart';
import 'package:pi_handset/ui/theme.dart';
import 'package:pi_handset/ui/transcript_view.dart';

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

  /// Pumps the transcript with no search, settles it at the bottom, THEN opens
  /// the search — the on-device ordering (`app_shell._openSearch` → rebuild →
  /// didUpdateWidget). Opening on the first pump takes `initState`, which
  /// skips `_jumpToBottom` and starts at the top, hiding this bug.
  Future<void> pumpSearching(
    WidgetTester tester,
    SessionTranscript transcript, {
    required List<TranscriptBlock> matches,
    int current = 0,
  }) async {
    await tester.pumpWidget(wrap(transcript));
    await tester.pumpAndSettle();
    expect(atBottom(tester), isTrue, reason: 'warm-up must reach the bottom');
    await tester.pumpWidget(
      wrap(
        transcript,
        search: TranscriptSearch(
          open: true,
          matches: matches,
          current: current,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Warm up at the bottom, scroll back to the top, THEN open the search — a
  /// user who scrolled up and searched. The reveal must work in the *downward*
  /// direction too: the target is reached from above, where the extent estimate
  /// is 16% short (measured: 25511 vs 30476).
  Future<void> pumpSearchingFromTop(
    WidgetTester tester,
    SessionTranscript transcript, {
    required List<TranscriptBlock> matches,
    int current = 0,
  }) async {
    await tester.pumpWidget(wrap(transcript));
    await tester.pumpAndSettle();
    tester.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(0);
    await tester.pump();
    expect(
      scrollOffset(tester),
      0,
      reason: 'the transcript must start at the top',
    );
    await tester.pumpWidget(
      wrap(
        transcript,
        search: TranscriptSearch(
          open: true,
          matches: matches,
          current: current,
        ),
      ),
    );
    await tester.pumpAndSettle();
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
    'the first block is revealed from the bottom of a long variable-height transcript',
    (tester) async {
      final transcript = mixed(400);
      await pumpSearching(tester, transcript, matches: [transcript.blocks[0]]);

      expect(
        rowVisible(tester, 'b0'),
        isTrue,
        reason: 'the first block must be scrolled into view from the bottom',
      );
      expect(
        rowFor(tester, 'b0').highlight,
        isNotNull,
        reason: 'a built current-match row must carry the tint',
      );
    },
  );

  testWidgets('a mid-transcript match is revealed from the bottom', (
    tester,
  ) async {
    final transcript = mixed(400);
    await pumpSearching(tester, transcript, matches: [transcript.blocks[200]]);

    expect(
      rowVisible(tester, 'b200'),
      isTrue,
      reason: 'a mid-transcript match must be reached from the bottom',
    );
  });

  testWidgets('stepping between two far matches reveals the new one', (
    tester,
  ) async {
    final transcript = mixed(400);
    // b395 is inside the measured bottom window (blocks 394..399), so it takes
    // the fast path; stepping to b5 then forces a far upward seek.
    await pumpSearching(
      tester,
      transcript,
      matches: [transcript.blocks[395], transcript.blocks[5]],
    );
    expect(rowVisible(tester, 'b395'), isTrue);

    final before = scrollOffset(tester);
    await tester.pumpWidget(
      wrap(
        transcript,
        search: TranscriptSearch(
          open: true,
          matches: [transcript.blocks[395], transcript.blocks[5]],
          current: 1,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      rowVisible(tester, 'b5'),
      isTrue,
      reason: 'stepping to a far match must reveal it',
    );
    expect(rowFor(tester, 'b5').highlight, isNotNull);
    expect(
      scrollOffset(tester),
      isNot(before),
      reason: 'the view must move to the new match',
    );
  });

  testWidgets(
    'a late match is revealed, and stepping to another moves the view',
    (tester) async {
      final transcript = tall(60);
      final first = transcript.blocks[5];
      await pumpSearching(tester, transcript, matches: [first]);
      expect(
        rowVisible(tester, 'b5'),
        isTrue,
        reason: 'the current match must be scrolled into view',
      );

      final revealed = scrollOffset(tester);
      await tester.pumpWidget(
        wrap(
          transcript,
          search: TranscriptSearch(
            open: true,
            matches: [first, transcript.blocks[0]],
            current: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        rowVisible(tester, 'b0'),
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
    await pumpSearching(tester, transcript, matches: [transcript.blocks[0]]);

    expect(
      rowVisible(tester, 'b0'),
      isTrue,
      reason:
          'the anchored binary search must reach a match in a variable-height '
          'transcript (a one-shot estimate lands short)',
    );
    expect(
      rowFor(tester, 'b0').highlight,
      isNotNull,
      reason: 'a built current-match row must carry the tint',
    );
  });

  testWidgets('an empty transcript with a match does not throw', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const SessionTranscript(),
        search: TranscriptSearch(
          open: true,
          matches: [textBlock('ghost', 'x')],
          current: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(TranscriptView.emptyMessage), findsOneWidget);
  });

  testWidgets(
    'a current match whose row has left the transcript leaves the view alone',
    (tester) async {
      final transcript = tall(60);
      final ghost = textBlock('ghost', 'hello');
      await tester.pumpWidget(wrap(transcript));
      await tester.pumpAndSettle();
      expect(atBottom(tester), isTrue);
      final before = scrollOffset(tester);
      await tester.pumpWidget(
        wrap(
          transcript,
          search: TranscriptSearch(
            open: true,
            matches: [transcript.blocks[59], ghost],
            current: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(scrollOffset(tester), before); // no reveal, no jump
      expect(rowFor(tester, 'b59').highlight, isNotNull); // tint is build-time
    },
  );

  testWidgets('a far match below the top of a long transcript is revealed', (
    tester,
  ) async {
    final transcript = mixed(400);
    await pumpSearchingFromTop(
      tester,
      transcript,
      matches: [transcript.blocks[300]],
    );

    expect(
      rowVisible(tester, 'b300'),
      isTrue,
      reason: 'a downward seek must reach a mid-transcript target from the '
          'top, not merely the bottom row',
    );
    expect(rowFor(tester, 'b300').highlight, isNotNull);
  });

  testWidgets('a match above a truncated history is revealed', (tester) async {
    final transcript = SessionTranscript(
      blocks: mixed(400).blocks,
      truncated: true,
    );
    await pumpSearching(tester, transcript, matches: [transcript.blocks[0]]);

    expect(
      rowVisible(tester, 'b0'),
      isTrue,
      reason: 'the truncated notice row must not shift the seek off the target',
    );
  });

  test('the list index accounts for the truncated-history notice row', () {
    final b0 = textBlock('b0', 'zero');
    final b1 = textBlock('b1', 'one');
    expect(
      transcriptListIndexOf(
        SessionTranscript(blocks: [b0, b1], truncated: true),
        'b1',
      ),
      2,
    );
    expect(transcriptListIndexOf(SessionTranscript(blocks: [b0, b1]), 'b1'), 1);
  });

  testWidgets(
    'stepping to a new match before the previous seek settles reveals the new one',
    (tester) async {
      final transcript = mixed(400);
      await tester.pumpWidget(wrap(transcript));
      await tester.pumpAndSettle();
      expect(atBottom(tester), isTrue);

      await tester.pumpWidget(
        wrap(
          transcript,
          search: TranscriptSearch(
            open: true,
            matches: [transcript.blocks[380], transcript.blocks[5]],
            current: 0,
          ),
        ),
      );
      // One frame only: A's seek has probed and scheduled its next frame.
      await tester.pump();
      await tester.pumpWidget(
        wrap(
          transcript,
          search: TranscriptSearch(
            open: true,
            matches: [transcript.blocks[380], transcript.blocks[5]],
            current: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        rowVisible(tester, 'b5'),
        isTrue,
        reason: 'the newest seek must win the shared execution slot',
      );
    },
  );

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
