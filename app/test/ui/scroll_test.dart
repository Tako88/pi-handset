// Stick-to-bottom scrolling: the behaviours from the plan, each asserted
// through observable state (the scroll offset and the *visible rows*), not
// merely "the widget rebuilt". Content stability — the row a scrolled-away
// viewer sees does not move when the transcript grows — is asserted on the row's
// screen position, because a preserved pixel offset is not the same thing.
//
// Deliberately pumped WITHOUT a `Scaffold` ancestor: `TranscriptView` is used
// inside `app_shell`'s body, but the jump-to-latest affordance must not assume
// one that a widget test might not provide.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/hub_client.dart';
import 'package:pi_handset/client/transcript.dart';
import 'package:pi_handset/ui/theme.dart';
import 'package:pi_handset/ui/transcript_view.dart';

/// A transcript taller than the 600px test viewport.
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

/// A transcript of uniform, deliberately tall rows. A window growth inserts a
/// whole chunk — far more than `ListView.builder`'s cache — so the row the
/// correction captured is always unmounted and the growth takes its extent-delta
/// fallback path rather than the anchor path.
SessionTranscript tallRows(int count) => SessionTranscript(
  blocks: [
    for (var i = 0; i < count; i++)
      TranscriptBlock(
        kind: TranscriptBlockKind.text,
        id: 'b$i',
        text: 'message $i\nsecond line\nthird line\nfourth line',
      ),
  ],
);

/// A transcript with *variable* row heights: every fifth row is a tall
/// multiline block. `ListView.builder` estimates `maxScrollExtent` from the
/// rows laid out so far, so on a shape like this a one-shot jump targets an
/// estimate and lands short. The first rows are short, so the estimate built
/// before the jump under-reports the true extent.
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

/// A transcript whose newest window (blocks 70..99) is short but whose *next*
/// chunk (blocks 40..69) is uniformly tall. The open renders the newest 30 short
/// rows, so the growth's minimum-row seed is a short row; the additive cache then
/// falls far short of the tall chunk, and the settle exhausts its retry cap
/// without ever building the anchor.
SessionTranscript tallChunkAhead(int count) => SessionTranscript(
  blocks: [
    for (var i = 0; i < count; i++)
      TranscriptBlock(
        kind: TranscriptBlockKind.text,
        id: 'b$i',
        text: i >= 40 && i < 70
            ? List.generate(120, (l) => 'tall $i line $l').join('\n')
            : 'message $i',
      ),
  ],
);

Widget wrap(
  SessionTranscript transcript, {
  Key? key,
  TranscriptSearch search = TranscriptSearch.none,
  VoidCallback? onLoadOlder,
}) => MaterialApp(
  theme: piTheme(Brightness.dark),
  home: TranscriptView(
    key: key,
    transcript: transcript,
    onLoadOlder: onLoadOlder ?? () {},
    search: search,
  ),
);

/// The scroll offset of the transcript's list. In a natural-order list the
/// bottom is `maxScrollExtent`, not 0.
double scrollOffset(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;

bool atBottom(WidgetTester tester) {
  final position = tester.state<ScrollableState>(find.byType(Scrollable)).position;
  return position.pixels >= position.maxScrollExtent - 1;
}

/// The topmost visible `message N` row, as (text, screen-y). Growth must leave
/// a scrolled-away viewer's visible content exactly where it was; asserting
/// only that the offset is unchanged misses a list that repositions its rows.
(String, double) topmostMessage(WidgetTester tester) {
  String? text;
  var top = double.infinity;
  for (var i = 0; i < 60; i++) {
    final finder = find.text('message $i');
    if (finder.evaluate().isEmpty) continue;
    final dy = tester.getTopLeft(finder.first).dy;
    if (dy < top) {
      top = dy;
      text = 'message $i';
    }
  }
  return (text!, top);
}

/// Flattened `{type, text}` entries that render as uniform `message N` rows.
/// Building them (rather than a bare block list) gives the view the entry
/// object identity its prepend detector needs.
List<Object?> userEntries(int count, {String prefix = 'message'}) => [
  for (var i = 0; i < count; i++) {'type': 'user', 'text': '$prefix $i'},
];

/// A transcript whose blocks are derived from its entries, so a prepend is
/// detectable and the two stay consistent.
SessionTranscript fromEntries(List<Object?> entries) =>
    SessionTranscript(entries: entries, blocks: deriveBlocks(entries));

void main() {
  testWidgets('a tall transcript starts at the bottom', (tester) async {
    await tester.pumpWidget(wrap(tall(60)));
    await tester.pump();

    expect(find.text('message 59'), findsOneWidget);
    expect(
      find.text('message 0'),
      findsNothing,
      reason: 'a tall transcript must not start at the oldest row',
    );
    expect(atBottom(tester), isTrue);
    expect(
      find.byIcon(Icons.arrow_downward),
      findsNothing,
      reason: 'no affordance while already at the bottom',
    );
  });

  testWidgets('the list reserves clearance under the jump-to-latest button', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(tall(60)));
    await tester.pump();

    final list = tester.widget<ListView>(find.byType(ListView));
    final padding = list.padding! as EdgeInsets;
    expect(
      padding.bottom,
      greaterThanOrEqualTo(72),
      reason: 'the newest row must not sit under the FAB',
    );
  });

  testWidgets(
    'a different session key starts the new transcript at the bottom',
    (tester) async {
      await tester.pumpWidget(wrap(tall(60), key: const ValueKey('s1')));
      await tester.pump();

      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.arrow_downward), findsOneWidget);

      // A new session is a new view: its offset and following state must not be
      // inherited from the transcript that was open before it.
      await tester.pumpWidget(wrap(tall(60), key: const ValueKey('s2')));
      await tester.pump();

      expect(find.text('message 59'), findsOneWidget);
      expect(
        find.byIcon(Icons.arrow_downward),
        findsNothing,
        reason: 'a freshly opened session follows the bottom',
      );
    },
  );

  testWidgets('growth keeps the viewer pinned when at the bottom', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(tall(60)));
    await tester.pump();

    await tester.pumpWidget(wrap(tall(61)));
    await tester.pump();

    expect(
      find.text('message 60'),
      findsOneWidget,
      reason: 'the newest row must still be on screen after growth',
    );
    expect(atBottom(tester), isTrue);
  });

  testWidgets(
    'growth while scrolled away leaves the visible content where it was',
    (tester) async {
      await tester.pumpWidget(wrap(tall(60)));
      await tester.pump();

      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pumpAndSettle();

      final away = scrollOffset(tester);
      expect(away, greaterThan(0));
      final (anchorText, anchorTop) = topmostMessage(tester);

      await tester.pumpWidget(wrap(tall(61)));
      await tester.pump();

      expect(
        find.text(anchorText),
        findsOneWidget,
        reason: 'the same row must still be on screen',
      );
      expect(
        tester.getTopLeft(find.text(anchorText)).dy,
        anchorTop,
        reason: 'growth must not shift the content a scrolled-away viewer sees',
      );
      expect(scrollOffset(tester), away);
    },
  );

  testWidgets(
    'streaming growth while scrolled away does not move the viewport',
    (tester) async {
      await tester.pumpWidget(wrap(tall(60)));
      await tester.pump();

      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pumpAndSettle();

      final away = scrollOffset(tester);
      final (anchorText, anchorTop) = topmostMessage(tester);

      // The live turn opens a streaming row at the bottom and grows it; a
      // viewer who scrolled away must not be dragged along.
      await tester.pumpWidget(
        wrap(
          SessionTranscript(
            blocks: tall(60).blocks,
            streaming: true,
            streamingText: 'partial one\npartial two\npartial three',
          ),
        ),
      );
      await tester.pump();

      expect(
        tester.getTopLeft(find.text(anchorText)).dy,
        anchorTop,
        reason: 'streaming growth must not shift a scrolled-away viewer\'s content',
      );
      expect(scrollOffset(tester), away);
    },
  );

  testWidgets('streaming growth stays pinned at the bottom', (tester) async {
    await tester.pumpWidget(wrap(tall(60)));
    await tester.pump();

    // A live turn opens a plain-text streaming row at the bottom.
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: tall(60).blocks,
          streaming: true,
          streamingText: 'partial one\npartial two',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('partial one\npartial two'), findsOneWidget);

    // Deltas grow that row; the viewer must stay pinned to its newest line.
    await tester.pumpWidget(
      wrap(
        SessionTranscript(
          blocks: tall(60).blocks,
          streaming: true,
          streamingText: 'partial one\npartial two\npartial three',
        ),
      ),
    );
    await tester.pump();
    expect(
      find.text('partial one\npartial two\npartial three'),
      findsOneWidget,
    );
    expect(atBottom(tester), isTrue);
  });

  testWidgets(
    'dragging up shows the affordance and growth no longer moves the viewport',
    (tester) async {
      await tester.pumpWidget(wrap(tall(60)));
      await tester.pump();

      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pumpAndSettle();

      final away = scrollOffset(tester);
      expect(
        away,
        greaterThan(0),
        reason:
            'the drag must really leave the bottom before asserting the rest',
      );
      expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
      expect(
        find.byTooltip('Jump to latest'),
        findsOneWidget,
        reason: 'an icon-only button must be labelled for screen readers',
      );

      await tester.pumpWidget(wrap(tall(61)));
      await tester.pumpAndSettle();

      expect(
        scrollOffset(tester),
        away,
        reason: 'growth must not move a viewer who scrolled away',
      );
    },
  );

  testWidgets(
    'a variable-height transcript opens at the newest row and stays pinned',
    (tester) async {
      await tester.pumpWidget(wrap(mixed(60)));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('tall 59 line 29', findRichText: true),
        findsOneWidget,
        reason: 'a freshly opened session must show its newest row',
      );
      expect(
        find.byIcon(Icons.arrow_downward),
        findsNothing,
        reason: 'a freshly opened session follows the bottom',
      );
      expect(atBottom(tester), isTrue);

      await tester.pumpWidget(wrap(mixed(65)));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('tall 64 line 29', findRichText: true),
        findsOneWidget,
        reason: 'growth while at the bottom stays pinned',
      );
      expect(atBottom(tester), isTrue);
    },
  );

  testWidgets(
    'the affordance reaches the true bottom of a variable-height transcript',
    (tester) async {
      await tester.pumpWidget(wrap(mixed(60)));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.arrow_downward), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_downward));
      await tester.pumpAndSettle();

      expect(atBottom(tester), isTrue);
      expect(
        find.textContaining('tall 59 line 29', findRichText: true),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.arrow_downward), findsNothing);
    },
  );

  testWidgets(
    'growth during the jump-to-latest animation still lands at the bottom',
    (tester) async {
      await tester.pumpWidget(wrap(mixed(60)));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.arrow_downward), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_downward));
      // Advance into the 200ms flight, then grow the transcript before it
      // lands: the animation's target is now stale.
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpWidget(wrap(mixed(65)));
      await tester.pumpAndSettle();

      expect(atBottom(tester), isTrue);
      expect(
        find.textContaining('tall 64 line 29', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.byIcon(Icons.arrow_downward),
        findsNothing,
        reason: 'the FAB must not stick after the animation re-pins',
      );
    },
  );

  testWidgets(
    'tapping the affordance returns to the bottom and resumes following',
    (tester) async {
      await tester.pumpWidget(wrap(tall(60)));
      await tester.pump();

      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(scrollOffset(tester), greaterThan(0));
      expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
      expect(find.byTooltip('Jump to latest'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_downward));
      await tester.pumpAndSettle();

      expect(atBottom(tester), isTrue);
      expect(find.byIcon(Icons.arrow_downward), findsNothing);

      await tester.pumpWidget(wrap(tall(61)));
      await tester.pump();
      expect(
        find.text('message 60'),
        findsOneWidget,
        reason: 'following must resume after returning to the bottom',
      );
    },
  );

  testWidgets(
    'a prepend keeps the visible row anchored and does not follow-jump',
    (tester) async {
      final existing = userEntries(60);
      final older = userEntries(20, prefix: 'older');
      await tester.pumpWidget(wrap(fromEntries(existing)));
      await tester.pump();

      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pumpAndSettle();

      final away = scrollOffset(tester);
      expect(away, greaterThan(0));
      expect(atBottom(tester), isFalse);
      final (anchorText, anchorTop) = topmostMessage(tester);

      await tester.pumpWidget(wrap(fromEntries([...older, ...existing])));
      await tester.pump();

      expect(
        find.text(anchorText),
        findsOneWidget,
        reason: 'the anchored row must still be on screen after a prepend',
      );
      expect(
        tester.getTopLeft(find.text(anchorText)).dy,
        anchorTop,
        reason:
            'a prepend must not shift the content a scrolled-away viewer sees',
      );
      expect(
        atBottom(tester),
        isFalse,
        reason: 'a prepend must not jump to the bottom',
      );
    },
  );

  testWidgets(
    'a prepend to a short transcript does not yank to the bottom',
    (tester) async {
      // Fits the viewport, so `maxScrollExtent == 0` and the offset correction
      // is skipped (the formula cannot measure through viewport-absorbed
      // slack). It deliberately does NOT assert the page-top outcome: landing
      // on the new page's top is the documented seam-loss, not intended
      // behaviour.
      final existing = userEntries(3);
      final older = userEntries(60, prefix: 'older');
      await tester.pumpWidget(wrap(fromEntries(existing)));
      await tester.pump();
      expect(atBottom(tester), isTrue);
      expect(scrollOffset(tester), 0);

      await tester.pumpWidget(wrap(fromEntries([...older, ...existing])));
      await tester.pump();

      expect(
        atBottom(tester),
        isFalse,
        reason:
            'a prepend must not follow-jump a short transcript to the bottom',
      );
      expect(scrollOffset(tester), 0);
    },
  );

  testWidgets(
    'reaching the top of the window reveals older loaded blocks without moving the content',
    (tester) async {
      await tester.pumpWidget(wrap(tall(200)));
      await tester.pumpAndSettle();
      expect(find.text('message 199'), findsOneWidget);
      expect(
        find.text('message 169'),
        findsNothing,
        reason: 'the window holds the newest 30 blocks',
      );
      // Snapshot the extent: `position` is a live reference, so comparing
      // `position.maxScrollExtent` to itself can never fail (the plan's
      // original test did exactly that — see the milestone report).
      final before = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .maxScrollExtent;

      // Drive the position directly rather than by a 4000 px drag: a drag can
      // clamp or overscroll and would not deterministically exercise the armed
      // growth branch (Open Question 3 in Revision 1, now removed by construction).
      tester.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(0);
      await tester.pumpAndSettle();

      expect(
        find.text('message 170'),
        findsOneWidget,
        reason: 'the row at the top of the window is still on screen',
      );
      expect(
        tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position
            .maxScrollExtent,
        greaterThan(before),
        reason: 'the window grew, so there is more to scroll up into',
      );

      // The content did not move: the row that was pinned at the top of the
      // viewport before the growth is still at the top after it. This is the
      // witness for the anchor correction (delete it and this is ~1200 px down).
      final listTop = tester.getTopLeft(find.byType(ListView)).dy;
      final pinnedTop = tester.getTopLeft(find.text('message 170')).dy;
      expect(
        pinnedTop - listTop,
        lessThan(60),
        reason: 'the inserted chunk was compensated on the same frame',
      );

      // The plan asserted 'message 169' here, but a jump to the very top arms
      // another growth chunk (140 -> 110) and pins the row that was at the top
      // (140), so 169 sits 29 rows below the viewport. Assert the row that is
      // actually revealed and reachable: the top of the first revealed chunk,
      // which the pre-window view never rendered.
      tester.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        find.text('message 140'),
        findsOneWidget,
        reason: 'the revealed chunk is reachable by scrolling, with no round trip',
      );
    },
  );

  testWidgets(
    'a variable-height window growth pins the anchor by measured geometry',
    (tester) async {
      // mixed(200) makes the inserted chunk 140..169 contain six 30-line rows,
      // far taller than the builder's cache window, so the anchor row is
      // unmounted by the growth and the old extent-delta fallback is what places
      // the view. The extent is an estimate extrapolated from the few rows built
      // before the jump, so it mis-measures the insertion and leaves the pinned
      // row off the top (measured 214 px in this 600 px viewport; thousands on
      // device).
      await tester.pumpWidget(wrap(mixed(200)));
      await tester.pumpAndSettle();
      tester.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(0);
      await tester.pumpAndSettle();

      expect(find.text('message 170'), findsOneWidget);
      final listTop = tester.getTopLeft(find.byType(ListView)).dy;
      final pinnedTop = tester.getTopLeft(find.text('message 170')).dy;
      expect(
        pinnedTop - listTop,
        lessThan(60),
        reason: 'the growth correction must place the anchor by its measured '
            'geometry, not by the estimated extent delta',
      );
    },
  );

  testWidgets(
    'a settle that never builds its anchor gives up at the frame cap',
    (tester) async {
      await tester.pumpWidget(wrap(tallChunkAhead(100)));
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;

      // Scroll to the top of the window: this arms the growth and the next frame
      // inserts the uniformly tall chunk (blocks 40..69) above the short newest
      // window. The cache is seeded from the *minimum* built row — a short one —
      // so the additive retries never reach the anchor's true distance and the
      // settle exhausts the retry cap.
      final before = position.maxScrollExtent;
      position.jumpTo(0);
      await tester.pumpAndSettle();

      expect(
        position.maxScrollExtent,
        greaterThan(before),
        reason: 'the window really grew (the tall chunk was inserted)',
      );
      // Give-up. The correction was abandoned without chaining, so the offset is
      // exactly where the viewer left it; a landed correction would have moved
      // it by the inserted height (tens of thousands of pixels).
      //
      // The zero-seed guard (a built row of height <= 0) routes into this same
      // give-up branch, so these assertions cover it too. A real zero-height
      // block row does not exist — every block kind carries DocumentRow's 16 px
      // vertical padding — so that path is defensive, not separately reachable.
      expect(
        scrollOffset(tester),
        0,
        reason: 'a capped settle must leave the offset untouched',
      );
      // The growth-scoped cache is dropped on every settle exit.
      expect(
        tester.widget<ListView>(find.byType(ListView)).scrollCacheExtent,
        isNull,
        reason: 'a capped settle must clear the growth cache',
      );
      // The single-flight guard is released: a later upward scroll can start a
      // fresh settle, which widens the cache again. A stuck flag would swallow
      // the growth and leave the cache null here.
      position.jumpTo(position.maxScrollExtent - 1);
      position.jumpTo(0);
      await tester.pump(); // the grow check runs post-frame, then setState
      await tester.pump(); // the ListView rebuilds with the growth cache
      expect(
        tester.widget<ListView>(find.byType(ListView)).scrollCacheExtent,
        isNotNull,
        reason: 'the single-flight guard must be released after a give-up',
      );
    },
  );

  testWidgets(
    'an append during a window growth does not double-correct',
    (tester) async {
      // Control: one clean growth, one chunk's correction.
      await tester.pumpWidget(wrap(mixed(200), key: const ValueKey('control')));
      await tester.pumpAndSettle();
      tester.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(0);
      await tester.pumpAndSettle();
      final controlOffset = scrollOffset(tester);

      // Interleaved: the growth is still in flight when an append arrives. The
      // append fires didUpdateWidget -> _scheduleGrowCheck -> a second growth
      // attempt mid-settle; without a single-flight guard the second attempt
      // overwrites the cache and layers a second chunk-sized correction.
      await tester.pumpWidget(
        wrap(mixed(200), key: const ValueKey('interleaved')),
      );
      await tester.pumpAndSettle();
      tester.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(0);
      await tester.pump(); // the growth's setState has run; the settle is in flight
      await tester.pumpWidget(
        wrap(mixed(201), key: const ValueKey('interleaved')),
      );
      await tester.pump(); // a second growth attempt mid-settle
      await tester.pumpAndSettle();

      final listTop = tester.getTopLeft(find.byType(ListView)).dy;
      final pinnedTop = tester.getTopLeft(find.text('message 170')).dy;
      expect(
        pinnedTop - listTop,
        lessThan(60),
        reason: 'the one correction must pin the anchor',
      );
      expect(
        scrollOffset(tester),
        closeTo(controlOffset, 60),
        reason:
            'the interleaved append must not layer a second chunk correction',
      );
    },
  );

  testWidgets(
    'a scroll during a window growth is preserved, not discarded',
    (tester) async {
      await tester.pumpWidget(wrap(tallRows(200)));
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;

      // Arm the growth at the top of the window and let its setState run. The
      // correction callback is queued for the next frame's post-frame phase and
      // the layout is still the old one, so oldMax here is the value that
      // callback captures.
      position.jumpTo(0);
      await tester.pump();
      final oldMax = position.maxScrollExtent;

      // Scroll again in the gap before that callback runs. The inserted height
      // must be layered on the *live* offset (100 + inserted), not on the
      // offset the growth was scheduled from (0 + inserted): the latter throws
      // the new scroll away.
      position.jumpTo(100);

      await tester.pump();
      final inserted = position.maxScrollExtent - oldMax;
      expect(inserted, greaterThan(0), reason: 'the window really grew');
      expect(
        scrollOffset(tester),
        100 + inserted,
        reason:
            'the correction must compensate the insertion at the live offset',
      );
    },
  );

  testWidgets('a fetched page joins a window that is already fully open', (
    tester,
  ) async {
    // Count load requests: revealing the joined page's last row must not
    // need one.
    var loads = 0;
    Widget wrapCounted(SessionTranscript transcript) =>
        wrap(transcript, onLoadOlder: () => loads++);

    final existing = userEntries(3);
    final older = userEntries(60, prefix: 'older');
    await tester.pumpWidget(wrapCounted(fromEntries(existing)));
    await tester.pump();
    expect(find.text('older 0'), findsNothing);

    await tester.pumpWidget(wrapCounted(fromEntries([...older, ...existing])));
    await tester.pump();

    expect(
      find.text('older 0'),
      findsOneWidget,
      reason: 'a window that reaches block 0 must render the fetched page',
    );
    // The plan asserted `find.text('older 59')` right here, but a 63-block list
    // in a 600 px viewport builds only the rows near the offset: the fetched
    // page's *last* row is in the window's index space, not simultaneously laid
    // out. Assert the truthful form of "the page joined": it is reachable by
    // scrolling to the bottom, with no round trip — `loads` stays 0, so
    // revealing it never requested another page. (The same scroll-then-assert
    // shape as the M3 test above, though for a different reason — there it is
    // window growth, here it is plain viewport laziness.)
    //
    // Division of labour: only the `older 0` assertion above can redden on the
    // regression this test exists to catch (a newest-window reset). This second
    // assertion is weaker but not vacuous — it pins contiguity/reachability:
    // the joined page has no gap and scrolls into view in a single pump.
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    expect(find.text('older 59'), findsOneWidget);
    expect(loads, 0, reason: 'revealing the joined page fetched nothing');
  });

  testWidgets(
    'a search opening in the growth frame keeps the position it owns',
    (tester) async {
      await tester.pumpWidget(wrap(tall(200)));
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      final before = position.maxScrollExtent;

      // Arm the growth at the top of the window and let its setState run; its
      // correction callback is now queued for the next frame.
      position.jumpTo(0);
      await tester.pump();

      // The search opens in the very frame the grown window is laid out in. It
      // owns the scroll position now — it is about to bisect for its current
      // match — so the growth correction must bail rather than yank the offset
      // out from under the seek.
      await tester.pumpWidget(
        wrap(tall(200), search: const TranscriptSearch(open: true)),
      );
      await tester.pump();

      expect(
        position.maxScrollExtent,
        greaterThan(before),
        reason: 'the window really grew',
      );
      expect(
        scrollOffset(tester),
        0,
        reason:
            'the growth correction must not move a position the search owns',
      );
    },
  );
}
