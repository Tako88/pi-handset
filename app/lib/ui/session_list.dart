/// The session list, driven by the hub's `sessions` push.
///
/// Presentational: it renders a snapshot of [sessions] and reports taps. The
/// list is a hint list, not a live feed — the client owns the state.
///
/// Rows use the same [DocumentRow] shape as the transcript, so the two screens
/// share one left text edge and the list already looks like the thing it opens.
/// A row's rule carries the *only* thing about a session you cannot read off the
/// label: whether it is running (violet, the same violet as the user's own row)
/// or idle (neutral). The group headers are a machine label, not a headline, so
/// they are set in the mono face and aligned to the row text.
///
/// App-started sessions are grouped above PC-started ones, each under a
/// header that appears only when its group is non-empty. An app row carries a
/// kill affordance when [onKill] is supplied; a PC row never does.
library;

import 'package:flutter/material.dart';

import '../client/hub_models.dart';
import 'theme.dart';

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

  /// The x every row's text starts at — page padding + rule + gap. The eyebrow
  /// shares it, so the header sits over the words rather than over the rule.
  static const double _textInset = 25;

  @override
  Widget build(BuildContext context) {
    final roles = Theme.of(context).extension<PiRoles>()!;
    if (sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            emptyMessage,
            textAlign: TextAlign.center,
            style: TextStyle(color: roles.muted),
          ),
        ),
      );
    }
    final appSessions = sessions.where((s) => s.origin == 'app').toList();
    final pcSessions = sessions.where((s) => s.origin != 'app').toList();
    final children = <Widget>[];
    if (appSessions.isNotEmpty) {
      children.add(_header(context, appSectionHeader));
      children.addAll(appSessions.map((s) => _row(context, s)));
    }
    if (pcSessions.isNotEmpty) {
      children.add(_header(context, pcSectionHeader));
      children.addAll(pcSessions.map((s) => _row(context, s)));
    }
    return ListView(children: children);
  }

  /// The group label: mono, letterspaced, `muted`. It encodes a real grouping,
  /// so it is structure — but it is still the machine's voice, not a headline.
  Widget _header(BuildContext context, String label) {
    final roles = Theme.of(context).extension<PiRoles>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(_textInset, 16, 16, 4),
      child: Text(
        label,
        style: piMono(fontSize: 11, color: roles.muted, letterSpacing: 1.2),
      ),
    );
  }

  Widget _row(BuildContext context, SessionSummary session) {
    final roles = Theme.of(context).extension<PiRoles>()!;
    final running = session.agentState == 'running';
    return DocumentRow(
      rule: running ? roles.accent : roles.dim,
      onTap: () => onOpen(session),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: roles.text, fontSize: 15),
                ),
                const SizedBox(height: 2),
                // Just the state: which group a row is under already says where
                // it was started, so repeating the origin would be noise.
                Text(
                  session.agentState,
                  style: piMono(fontSize: 11, color: roles.muted),
                ),
              ],
            ),
          ),
          if (session.origin == 'app' && onKill != null)
            IconButton(
              key: Key('kill-${session.sessionId}'),
              icon: Icon(Icons.delete_outline, size: 18, color: roles.dim),
              tooltip: 'Kill session',
              onPressed: () => onKill!(session),
            ),
        ],
      ),
    );
  }
}
