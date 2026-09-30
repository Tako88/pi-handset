// Session list: driven by the hub's `sessions` push. Each row shows the label
// and the agent state; the empty case is explicit.

import 'package:flutter/material.dart';
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
