// Session list: driven by the hub's `sessions` push. Each row shows the label
// and the agent state; the empty case is explicit.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/hub_client.dart';
import 'package:pi_handset/ui/session_list.dart';
import 'package:pi_handset/ui/theme.dart';

/// The app's own theme, not Material's default: `SessionList` reads `PiRoles`,
/// and a test that renders it outside the app's theme is not rendering what the
/// app renders.
Widget host(Widget child) =>
    MaterialApp(theme: piTheme(Brightness.dark), home: Scaffold(body: child));

const sessions = [
  SessionSummary(sessionId: 's1', label: 'api refactor', agentState: 'idle'),
  SessionSummary(sessionId: 's2', label: 'docs pass', agentState: 'running'),
];

void main() {
  testWidgets('an empty session list says so', (tester) async {
    await tester.pumpWidget(host(SessionList(sessions: const [], onOpen: (_) {})));

    expect(find.text(SessionList.emptyMessage), findsOneWidget);
  });

  testWidgets('a session list renders each label and agent state', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(SessionList(sessions: sessions, onOpen: (_) {})),
    );

    expect(find.text('api refactor'), findsOneWidget);
    expect(find.text('docs pass'), findsOneWidget);
    expect(find.text('idle'), findsOneWidget);
    expect(find.text('running'), findsOneWidget);
    expect(find.text(SessionList.emptyMessage), findsNothing);
  });

  testWidgets('a running session is ruled apart from an idle one', (
    tester,
  ) async {
    // The rule is the only thing on a row you cannot read off the label, so it
    // has to mean something. Violet = running, the same violet the transcript
    // gives the user's own row.
    await tester.pumpWidget(
      host(SessionList(sessions: sessions, onOpen: (_) {})),
    );

    final roles = piTheme(Brightness.dark).extension<PiRoles>()!;
    DocumentRow rowOf(String label) => tester.widget<DocumentRow>(
      find.ancestor(of: find.text(label), matching: find.byType(DocumentRow)).first,
    );
    expect(rowOf('docs pass').rule, roles.accent);
    expect(rowOf('api refactor').rule, roles.dim);
  });

  testWidgets('a long session label is ellipsized to a single line', (
    tester,
  ) async {
    final longLabel = 'x' * 200;
    final longSessions = [
      SessionSummary(sessionId: 's1', label: longLabel, agentState: 'idle'),
      SessionSummary(sessionId: 's2', label: 'short', agentState: 'idle'),
    ];
    await tester.pumpWidget(
      host(SessionList(sessions: longSessions, onOpen: (_) {})),
    );

    expect(tester.widget<Text>(find.text(longLabel)).maxLines, 1);
    expect(
      tester.widget<Text>(find.text(longLabel)).overflow,
      TextOverflow.ellipsis,
    );
    // `didExceedMaxLines` is true precisely when the label was constrained to
    // `maxLines` and ellipsized; it would also be false for an unconstrained
    // multi-line label, so it witnesses the ellipsis rather than proving nothing.
    expect(
      tester.renderObject<RenderParagraph>(find.text(longLabel)).didExceedMaxLines,
      isTrue,
    );
    // Rendered geometry, not internal state: one line either way.
    expect(
      tester.getSize(find.text(longLabel)).height,
      tester.getSize(find.text('short')).height,
    );
  });

  testWidgets('tapping a session opens it', (tester) async {
    SessionSummary? opened;
    await tester.pumpWidget(
      host(
        SessionList(sessions: sessions, onOpen: (session) => opened = session),
      ),
    );

    await tester.tap(find.text('docs pass'));
    await tester.pump();

    expect(opened?.sessionId, 's2');
  });

  testWidgets('app and pc sessions render under their own headers', (tester) async {
    final mixed = [
      const SessionSummary(
        sessionId: 's1',
        label: 'from phone',
        agentState: 'idle',
        origin: 'app',
      ),
      const SessionSummary(
        sessionId: 's2',
        label: 'from pc',
        agentState: 'idle',
        origin: 'pc',
      ),
    ];
    await tester.pumpWidget(host(SessionList(sessions: mixed, onOpen: (_) {})));

    expect(find.text(SessionList.appSectionHeader), findsOneWidget);
    expect(find.text(SessionList.pcSectionHeader), findsOneWidget);
    expect(find.text('from phone'), findsOneWidget);
    expect(find.text('from pc'), findsOneWidget);
  });

  testWidgets('the app header is absent when there are no app sessions', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(SessionList(sessions: sessions, onOpen: (_) {})),
    );

    expect(find.text(SessionList.appSectionHeader), findsNothing);
    expect(find.text(SessionList.pcSectionHeader), findsOneWidget);
  });

  testWidgets('an app row shows a kill button whose tap calls onKill', (
    tester,
  ) async {
    SessionSummary? killed;
    final mixed = [
      const SessionSummary(
        sessionId: 's1',
        label: 'from phone',
        agentState: 'idle',
        origin: 'app',
      ),
    ];
    await tester.pumpWidget(
      host(
        SessionList(
          sessions: mixed,
          onOpen: (_) {},
          onKill: (session) => killed = session,
        ),
      ),
    );

    expect(find.byKey(const Key('kill-s1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('kill-s1')));
    await tester.pump();
    expect(killed?.sessionId, 's1');
  });

  testWidgets('a pc row shows no kill button', (tester) async {
    final mixed = [
      const SessionSummary(
        sessionId: 's2',
        label: 'from pc',
        agentState: 'idle',
        origin: 'pc',
      ),
    ];
    await tester.pumpWidget(
      host(SessionList(sessions: mixed, onOpen: (_) {}, onKill: (_) {})),
    );

    expect(find.byKey(const Key('kill-s2')), findsNothing);
  });

  testWidgets('a pending row renders under the app header with a cancel button', (
    tester,
  ) async {
    PendingSessionSummary? cancelled;
    await tester.pumpWidget(
      host(
        SessionList(
          sessions: const [],
          pendingSessions: const [
            PendingSessionSummary(id: 'p1', label: 'New session'),
          ],
          onOpen: (_) {},
          onCancel: (pending) => cancelled = pending,
        ),
      ),
    );

    expect(find.text(SessionList.appSectionHeader), findsOneWidget);
    expect(find.text(SessionList.emptyMessage), findsNothing);
    expect(find.text('starting…'), findsOneWidget);
    expect(find.byKey(const Key('cancel-p1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('cancel-p1')));
    await tester.pump();
    expect(cancelled?.id, 'p1');
  });

  testWidgets('a pending row is not openable', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      host(
        SessionList(
          sessions: const [],
          pendingSessions: const [
            PendingSessionSummary(id: 'p1', label: 'New session'),
          ],
          onOpen: (_) => opened = true,
        ),
      ),
    );

    await tester.tap(find.text('New session'));
    await tester.pump();
    expect(opened, isFalse);
  });
}
