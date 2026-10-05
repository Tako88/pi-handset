/// The app shell's session actions, lifted out of the app shell.
///
/// Owns the seven session-lifecycle actions driven from the session list, the
/// start FAB, and the transcript's ⋮ menu: starting (via a chooser or directly),
/// killing, compacting, replacing, and renaming. Each captures its messenger
/// before the first await and reads current shell state through the probes it
/// was handed, so it sees what the shell saw at the same point. A pure action
/// layer: all it needs from the shell is the client and three live probes.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../client/hub_client_view.dart';
import 'folder_browser.dart';
import 'session_menu.dart';

/// The app shell's session-lifecycle actions.
class SessionActions {
  SessionActions({
    required this.client,
    required this.isMounted,
    required this.activeSessionId,
    required this.labelOf,
  });

  final HubClientView client;

  /// Whether the owning State is still mounted. Read at each guard point, at
  /// the position the shell's own `mounted` checks held.
  final bool Function() isMounted;

  /// The active session id, or null. Read at each use, at the position the
  /// shell read `_state.activeSessionId`.
  final String? Function() activeSessionId;

  /// The display label for a session id. Read at each use, at the position the
  /// shell called `_sessionLabel`.
  final String Function(String) labelOf;

  /// Starts an app-started session. With the folder capabilities the FAB first
  /// offers a choice between a quick temp-dir session and browsing to a project;
  /// otherwise it starts directly, exactly as it always has. [context] is the
  /// sessions-view context, below `MaterialApp`, so its `ScaffoldMessenger` and
  /// `Navigator` are ancestors.
  void start(BuildContext context, {required bool canBrowse}) {
    if (canBrowse) {
      unawaited(chooseStart(context));
      return;
    }
    quickStart(context);
  }

  /// The old-hub path: start immediately, no chooser.
  void quickStart(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    unawaited(
      client.startSession().then((result) {
        if (!result.ok) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(result.error ?? 'could not start a session'),
            ),
          );
        }
      }),
    );
  }

  /// The capability path: a bottom-sheet chooser. The messenger and navigator
  /// are captured before the sheet's async gap, because the sheet's own context
  /// is gone once it closes; the sheet is popped and only then is the browser
  /// route pushed.
  Future<void> chooseStart(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('quick-session'),
              leading: const Icon(Icons.add),
              title: const Text('Quick session'),
              onTap: () => Navigator.pop(sheetContext, 'quick'),
            ),
            ListTile(
              key: const Key('open-project'),
              leading: const Icon(Icons.folder_open),
              title: const Text('Open a project'),
              onTap: () => Navigator.pop(sheetContext, 'project'),
            ),
          ],
        ),
      ),
    );
    if (!isMounted()) return;
    if (choice == 'quick') {
      final result = await client.startSession();
      if (!isMounted()) return;
      if (!result.ok) {
        messenger.showSnackBar(
          SnackBar(content: Text(result.error ?? 'could not start a session')),
        );
      }
    } else if (choice == 'project') {
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => FolderBrowserScreen(client: client),
        ),
      );
    }
  }

  /// Kills an app-started session. A refusal is shown in a SnackBar.
  void kill(SessionSummary session, BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    unawaited(
      client.killSession(session.sessionId).then((result) {
        if (!result.ok) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(result.error ?? 'could not kill the session'),
            ),
          );
        }
      }),
    );
  }

  /// Cancels a pending spawn by its placeholder id. A success is silent — the
  /// row disappears on the next push; a refusal is shown in a SnackBar.
  void cancelPending(PendingSessionSummary pending, BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    unawaited(
      client.killSession(pending.id).then((result) {
        if (!result.ok) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(result.error ?? 'could not cancel the session'),
            ),
          );
        }
      }),
    );
  }

  /// Compacts the session after a confirmation. The messenger and session id
  /// are captured before the dialog's await, because the dialog's own context
  /// is gone once it closes.
  Future<void> compact(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final activeId = activeSessionId();
    if (activeId == null) return;
    final confirmed = await confirmCompact(context);
    if (!isMounted() || !confirmed) return;
    final result = await client.sendCommand(activeId, 'compact');
    if (!isMounted() || result.ok) return;
    messenger.showSnackBar(
      SnackBar(content: Text(result.error ?? 'could not compact')),
    );
  }

  /// Replaces the session with a fresh one after a confirmation. The messenger
  /// and session id are captured before the dialog's await, because the dialog's
  /// own context is gone once it closes.
  ///
  /// The returned future settles on the replacement, not the ack, so a refusal
  /// is the only failure that reaches the SnackBar here.
  Future<void> newSession(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final activeId = activeSessionId();
    if (activeId == null) return;
    final confirmed = await confirmNewSession(context);
    if (!isMounted() || !confirmed) return;
    final result = await client.sessionNew(activeId);
    if (!isMounted() || result.ok) return;
    messenger.showSnackBar(
      SnackBar(content: Text(result.error ?? 'could not start a new session')),
    );
  }

  /// Renames the session. The display updates when pi reports the new label.
  Future<void> rename(String activeId, BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final name = await promptRename(context, labelOf(activeId));
    if (!isMounted() || name == null) return;
    final result = await client.sendCommand(
      activeId,
      'setSessionName',
      args: {'name': name.trim()},
    );
    if (!isMounted() || result.ok) return;
    messenger.showSnackBar(
      SnackBar(content: Text(result.error ?? 'could not rename the session')),
    );
  }
}
