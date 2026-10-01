/// The session list, driven by the hub's `sessions` push.
///
/// Presentational: it renders a snapshot of [sessions] and reports taps. The
/// list is a hint list, not a live feed — the client owns the state.
///
/// App-started sessions are grouped above PC-started ones, each under a
/// header that appears only when its group is non-empty. An app row carries a
/// kill affordance when [onKill] is supplied; a PC row never does.
library;

import 'package:flutter/material.dart';

import '../client/hub_client.dart';

class SessionList extends StatelessWidget {
  const SessionList({
    super.key,
    required this.sessions,
    required this.onOpen,
    this.onKill,
  });

  final List<SessionSummary> sessions;
  final void Function(SessionSummary session) onOpen;

  /// Kill an app-started session. Optional: when null, no kill affordance is
  /// shown even for app sessions.
  final void Function(SessionSummary session)? onKill;

  static const String emptyMessage =
      'No sessions yet. Start pi on your PC and open a session.';

  static const String appSectionHeader = 'Started from the app';
  static const String pcSectionHeader = 'Started on the PC';

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
    final appSessions = sessions.where((s) => s.origin == 'app').toList();
    final pcSessions = sessions.where((s) => s.origin != 'app').toList();
    final children = <Widget>[];
    if (appSessions.isNotEmpty) {
      children.add(_header(context, appSectionHeader));
      children.addAll(appSessions.map(_row));
    }
    if (pcSessions.isNotEmpty) {
      children.add(_header(context, pcSectionHeader));
      children.addAll(pcSessions.map(_row));
    }
    return ListView(children: children);
  }

  Widget _header(BuildContext context, String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(label, style: Theme.of(context).textTheme.titleSmall),
  );

  Widget _row(SessionSummary session) => ListTile(
    title: Text(session.label, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(session.agentState),
    onTap: () => onOpen(session),
    trailing: session.origin == 'app' && onKill != null
        ? IconButton(
            key: Key('kill-${session.sessionId}'),
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Kill session',
            onPressed: () => onKill!(session),
          )
        : null,
  );
}
