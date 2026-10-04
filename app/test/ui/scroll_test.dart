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
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/client/transcript.dart';
import 'package:pi_droid/ui/theme.dart';
import 'package:pi_droid/ui/transcript_view.dart';

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

Widget wrap(SessionTranscript transcript, {Key? key}) =>
    MaterialApp(
      theme: piTheme(Brightness.dark),
      home: TranscriptView(
        key: key,
        transcript: transcript,
        onLoadOlder: () {},
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
}
