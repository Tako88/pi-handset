// Find in the transcript. The group is kept verbatim so the emitted test names
// match the baseline.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/endpoint_store.dart';
import 'package:pi_droid/ui/session_menu.dart';
import 'package:pi_droid/ui/transcript_view.dart';

import 'support/app_shell_harness.dart';

void main() {
  group('transcript search', () {
    testWidgets('the bar offers search immediately before the session menu', (
      tester,
    ) async {
      await openSearchableSession(tester);

      final actions = tester.widget<AppBar>(find.byType(AppBar)).actions!;
      expect(actions, hasLength(2));
      expect((actions.first as IconButton).key, const Key('transcript-search'));
      expect(actions.last, isA<SessionMenuButton>());
    });

    testWidgets('the search button opens a field showing 0/0', (tester) async {
      await openSearchableSession(tester);

      expect(find.byKey(const Key('transcript-search-field')), findsNothing);
      await tester.tap(find.byKey(const Key('transcript-search')));
      await tester.pump();

      expect(find.byKey(const Key('transcript-search-field')), findsOneWidget);
      expect(searchCount(tester), '0/0');
      // The session menu is hidden until the search closes.
      expect(find.byKey(const Key('session-menu')), findsNothing);
    });

    testWidgets(
      'typing sets the count and tints the matching row in the same frame',
      (tester) async {
        await openSearchableSession(tester);
        await tester.tap(find.byKey(const Key('transcript-search')));
        await tester.pump();

        // One frame after the keystroke: the count AND the highlight must both
        // be updated, which proves the shell setState reaches the pushed
        // transcript route's TranscriptView.didUpdateWidget (OQ1).
        await tester.enterText(
          find.byKey(const Key('transcript-search-field')),
          'message 1',
        );
        await tester.pump();

        expect(searchCount(tester), '1/1');
        expect(searchHighlightedRows(tester), hasLength(1));
        await tester.pumpAndSettle();
      },
    );

    testWidgets('next and prev step through the matches and wrap', (
      tester,
    ) async {
      await openSearchableSession(tester, count: 3);
      await tester.tap(find.byKey(const Key('transcript-search')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('transcript-search-field')),
        'message',
      );
      await tester.pump();
      expect(searchCount(tester), '1/3');

      await tester.tap(find.byKey(const Key('transcript-search-next')));
      await tester.pump();
      expect(searchCount(tester), '2/3');
      await tester.tap(find.byKey(const Key('transcript-search-next')));
      await tester.pump();
      expect(searchCount(tester), '3/3');
      await tester.tap(find.byKey(const Key('transcript-search-next')));
      await tester.pump();
      expect(searchCount(tester), '1/3');

      await tester.tap(find.byKey(const Key('transcript-search-prev')));
      await tester.pump();
      expect(searchCount(tester), '3/3');
      await tester.pumpAndSettle();
    });

    testWidgets('a query with no match shows 0/0 and disables both steppers', (
      tester,
    ) async {
      await openSearchableSession(tester);
      await tester.tap(find.byKey(const Key('transcript-search')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('transcript-search-field')),
        'nothing here',
      );
      await tester.pump();

      expect(searchCount(tester), '0/0');
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('transcript-search-next')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('transcript-search-prev')))
            .onPressed,
        isNull,
      );
      await tester.pumpAndSettle();
    });

    testWidgets('closing the search restores the session menu', (tester) async {
      await openSearchableSession(tester);
      await tester.tap(find.byKey(const Key('transcript-search')));
      await tester.pump();
      expect(find.byKey(const Key('transcript-search-field')), findsOneWidget);
      expect(find.byKey(const Key('session-menu')), findsNothing);

      await tester.tap(find.byKey(const Key('transcript-search-close')));
      await tester.pump();

      expect(find.byKey(const Key('transcript-search-field')), findsNothing);
      expect(find.byKey(const Key('session-menu')), findsOneWidget);
    });

    testWidgets('a query matching only the truncated notice yields 0/0', (
      tester,
    ) async {
      final h = Harness(
        endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787),
      );
      await tester.pumpWidget(h.app());
      await pumpBootstrap(tester);
      h.factory.last.receive(sessionsFrame([sessionS1]));
      await settle(tester, h.scheduler);
      await openSession(tester, h, 'api refactor');
      h.factory.last.receive(truncatedSnapshotFrame('s1'));
      await settle(tester, h.scheduler);
      await tester.pumpAndSettle();

      // The notice row renders, but it is a synthetic block that is never in
      // the search corpus, so matching its text finds nothing.
      expect(find.byKey(const ValueKey('history-truncated')), findsOneWidget);

      await tester.tap(find.byKey(const Key('transcript-search')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('transcript-search-field')),
        'Older messages',
      );
      await tester.pump();

      expect(searchCount(tester), '0/0');
    });

    testWidgets(
      'an empty transcript opens a search that finds nothing and does not throw',
      (tester) async {
        // No snapshot: the session has no blocks at all, so the view shows the
        // empty message and there is no list for the reveal to scroll.
        await openFirstSession(tester);
        await tester.tap(find.byKey(const Key('transcript-search')));
        await tester.pump();

        expect(find.byKey(const Key('transcript-search-field')), findsOneWidget);
        expect(find.text(TranscriptView.emptyMessage), findsOneWidget);
        expect(searchCount(tester), '0/0');
        expect(
          tester
              .widget<IconButton>(find.byKey(const Key('transcript-search-next')))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<IconButton>(find.byKey(const Key('transcript-search-prev')))
              .onPressed,
          isNull,
        );
      },
    );

    testWidgets('switching sessions clears the search', (tester) async {
      final h = await openSearchableSession(tester, includeSecond: true);
      await tester.tap(find.byKey(const Key('transcript-search')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('transcript-search-field')),
        'message',
      );
      await tester.pump();
      expect(find.byKey(const Key('transcript-search-field')), findsOneWidget);
      expect(searchHighlightedRows(tester), isNotEmpty);

      // The first back closes the search (canPop:false while searching); the
      // second pops the transcript, then the other session is opened.
      await pressSystemBack(tester, h.scheduler);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('transcript-search-field')), findsNothing);

      await pressSystemBack(tester, h.scheduler);
      await tester.pumpAndSettle();
      await openSession(tester, h, 'second session');

      expect(find.byKey(const Key('transcript-search-field')), findsNothing);
      expect(searchHighlightedRows(tester), isEmpty);
    });

    testWidgets(
      'predictive back while searching closes the search without leaving the session',
      (tester) async {
        final h = await openSearchableSession(tester);
        await tester.tap(find.byKey(const Key('transcript-search')));
        await tester.pump();
        expect(
          find.byKey(const Key('transcript-search-field')),
          findsOneWidget,
        );

        // canPop:false suppresses the predictive preview, so the start's
        // return value is not asserted; the end state is the contract.
        await startBackGesture(tester);
        await commitBackGesture(tester);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('transcript-search-field')), findsNothing);
        expect(find.byKey(const Key('compose-field')), findsOneWidget);
        expect(sentUnsubscribe(h, 's1'), isFalse);

        // A second back now pops the route and unsubscribes as before.
        await startBackGesture(tester);
        await commitBackGesture(tester);
        await tester.pumpAndSettle();
        h.scheduler.flushNotifications();
        await tester.pump();

        expect(find.byKey(const Key('compose-field')), findsNothing);
        expect(sentUnsubscribe(h, 's1'), isTrue);
      },
    );
  });
}
