/// The session list, driven by the hub's `sessions` push.
///
/// Presentational: it renders a snapshot of [sessions] and reports taps. The
/// list is a hint list, not a live feed — the client owns the state.
library;

import 'package:flutter/material.dart';

import '../client/hub_client.dart';

class SessionList extends StatelessWidget {
  const SessionList({super.key, required this.sessions, required this.onOpen});

  final List<SessionSummary> sessions;
  final void Function(SessionSummary session) onOpen;

  static const String emptyMessage =
      'No sessions yet. Start pi on your PC and open a session.';

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(emptyMessage, textAlign: TextAlign.center),
        ),
      );
    }
    return ListView.separated(
      itemCount: sessions.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final session = sessions[index];
        return ListTile(
          title: Text(session.label),
          subtitle: Text(session.agentState),
          onTap: () => onOpen(session),
        );
      },
    );
  }
}
