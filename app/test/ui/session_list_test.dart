// Session list: driven by the hub's `sessions` push. Each row shows the label
// and the agent state; the empty case is explicit.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/ui/session_list.dart';

const sessions = [
  SessionSummary(sessionId: 's1', label: 'api refactor', agentState: 'idle'),
  SessionSummary(sessionId: 's2', label: 'docs pass', agentState: 'running'),
];

void main() {
  testWidgets('an empty session list says so', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SessionList(sessions: const [], onOpen: (_) {}))),
    );

    expect(find.text(SessionList.emptyMessage), findsOneWidget);
  });

  testWidgets('a session list renders each label and agent state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SessionList(sessions: sessions, onOpen: (_) {}))),
    );

    expect(find.text('api refactor'), findsOneWidget);
    expect(find.text('docs pass'), findsOneWidget);
    expect(find.text('idle'), findsOneWidget);
    expect(find.text('running'), findsOneWidget);
    expect(find.text(SessionList.emptyMessage), findsNothing);
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
      MaterialApp(
        home: Scaffold(
          body: SessionList(sessions: longSessions, onOpen: (_) {}),
        ),
      ),
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
      MaterialApp(
        home: Scaffold(
          body: SessionList(sessions: sessions, onOpen: (session) => opened = session),
        ),
      ),
    );

    await tester.tap(find.text('docs pass'));
    await tester.pump();

    expect(opened?.sessionId, 's2');
  });
}
