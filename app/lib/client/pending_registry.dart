// ignore_for_file: prefer_initializing_formals
// The scheduler/store/isConnected/trySend fields are private, and a private
// *named* parameter is illegal in Dart, so the initializer list is the only way
// to bind them (the lint's suggested fix does not compile).

/// In-flight request bookkeeping: the pending-command and pending-listing maps
/// and their bounded waits, the replacement follow, and the shared
/// pending/result correlation.
///
/// Extracted from the hub client so the maps, the counters and the follow have
/// a single owner. The clock is the injected scheduler; the outbound path and
/// the connection check are the client's, handed in as callbacks so this file
/// never holds a [HubClient].
library;

import 'dart:async';

import 'hub_models.dart';
import 'scheduler.dart';
import 'session_state.dart';

/// Bounded wait for a `command-result` before the caller's future fails.
const Duration _commandTimeout = Duration(seconds: 30);

/// Bounded wait for a `/new` or `/fork` replacement to register. pi tears the
/// old session down and registers the successor over two pushes; without this
/// a bridge that dies in between would leave the client waiting forever.
const Duration _replacementTimeout = Duration(seconds: 15);

/// One in-flight `command`, with the session it belongs to (so `session-gone`
/// can fail it) and its timeout handle.
class PendingCommand {
  PendingCommand(
    this.sessionId,
    this.completer, {
    this.followsReplacement = false,
  });

  final String sessionId;
  final Completer<CommandResult> completer;

  /// Set by `sessionNew`/`sessionFork` only: this command's success witness is
  /// the session being replaced, so it is settled by that replacement rather
  /// than by a `command-result`.
  final bool followsReplacement;
  HubTimer? timer;
}

/// One in-flight `list-dirs` and its timeout handle. Session-less, so only a
/// disconnect or the timeout can fail it.
class PendingListing {
  PendingListing(this.completer);

  final Completer<DirListingResult> completer;
  HubTimer? timer;
}

/// The pending requests and results: allowlisted commands, list-dirs, the
/// shared pending/result correlation, and the replacement follow.
///
/// The client hands in its scheduler, its store (for the one resubscribe flag
/// the follow timeout writes), its connection check and its outbound send, so
/// this collaborator owns the maps and timers without a back-reference.
class PendingRegistry {
  PendingRegistry({
    required HubScheduler scheduler,
    required SessionStateStore store,
    required bool Function() isConnected,
    required Object? Function(Map<String, Object?>) trySend,
  }) : _scheduler = scheduler,
       _store = store,
       _isConnected = isConnected,
       _trySend = trySend;

  final HubScheduler _scheduler;
  final SessionStateStore _store;
  final bool Function() _isConnected;
  final Object? Function(Map<String, Object?>) _trySend;

  final Map<String, PendingCommand> _pendingCommands = {};

  /// In-flight `list-dirs`, keyed by their `dirs-N` id. Kept separate from
  /// [_pendingCommands] because the two share the wire `id` field: a
  /// `command-result` for a listing id must not complete a command.
  final Map<String, PendingListing> _pendingListings = {};

  int _commandCounter = 0;
  int _listingCounter = 0;

  /// The old session id a `/new` or `/fork` is waiting to be replaced, or null
  /// when no replacement is in flight. While set, `_onSessions` adopts a
  /// summary whose `replacesSessionId` matches it and never re-subscribes the
  /// dead id.
  String? _awaitingReplacementFrom;
  HubTimer? _replacementTimer;

  /// Registers a pending command under a generated id, schedules the bounded
  /// wait, sends [build]'s frame, and completes when the matching
  /// `command-result` arrives.
  Future<CommandResult> command({
    required String sessionId,
    String? id,
    required Map<String, Object?> Function(String commandId) build,
    bool followsReplacement = false,
  }) {
    if (!_isConnected()) {
      // Dropping the request silently would leave the UI spinning forever.
      return Future.value(
        const CommandResult(ok: false, error: 'not connected'),
      );
    }
    final commandId = id ?? 'cmd-${++_commandCounter}';
    final completer = Completer<CommandResult>();
    final pending = PendingCommand(
      sessionId,
      completer,
      followsReplacement: followsReplacement,
    );
    _pendingCommands[commandId] = pending;
    pending.timer = _scheduler.schedule(_commandTimeout, () {
      final removed = _pendingCommands.remove(commandId);
      if (removed == null || removed.completer.isCompleted) return;
      removed.completer.complete(
        const CommandResult(ok: false, error: 'timed out'),
      );
    }, kind: HubTimerKind.command);
    // Arm the follow immediately before the frame goes out, so the successor's
    // `sessions` push can never race ahead of a set flag. `_onSessions` keys
    // off the old id, not `activeSessionId`, so a `session-gone` arriving first
    // does not lose it.
    if (followsReplacement) beginReplacementFollow(sessionId);
    final error = _trySend(build(commandId));
    if (error != null) {
      // A closing socket must not leave the caller with a thrown exception and
      // an entry that only the 30s timeout would clear.
      _pendingCommands.remove(commandId);
      pending.timer?.cancel();
      if (followsReplacement) clearReplacementFollow();
      completer.complete(CommandResult(ok: false, error: '$error'));
    }
    return completer.future;
  }

  /// Registers a pending `list-dirs` under a generated `dirs-N` id, schedules
  /// its bounded wait, sends [build]'s frame, and completes when the matching
  /// `dir-listing` (or `command-result`) arrives.
  Future<DirListingResult> listing({
    String? id,
    required Map<String, Object?> Function(String listingId) build,
  }) {
    if (!_isConnected()) {
      return Future.value(
        const DirListingResult(ok: false, error: 'not connected'),
      );
    }
    final listingId = id ?? 'dirs-${++_listingCounter}';
    final completer = Completer<DirListingResult>();
    final pending = PendingListing(completer);
    _pendingListings[listingId] = pending;
    pending.timer = _scheduler.schedule(_commandTimeout, () {
      final removed = _pendingListings.remove(listingId);
      if (removed == null || removed.completer.isCompleted) return;
      removed.completer.complete(
        const DirListingResult(ok: false, error: 'timed out'),
      );
    }, kind: HubTimerKind.command);
    final error = _trySend(build(listingId));
    if (error != null) {
      _pendingListings.remove(listingId);
      pending.timer?.cancel();
      completer.complete(DirListingResult(ok: false, error: '$error'));
    }
    return completer.future;
  }

  /// The pending command under [id], without removing it. Used where the
  /// decision has to be made before the entry is taken (a permitted
  /// replacement ack must leave it in place).
  PendingCommand? peekCommand(String id) => _pendingCommands[id];

  /// Removes and returns the pending command under [id], or null.
  PendingCommand? takeCommand(String id) => _pendingCommands.remove(id);

  /// Removes and returns the pending listing under [id], or null.
  PendingListing? takeListing(String id) => _pendingListings.remove(id);

  /// The old session id a replacement is waiting on, or null when none is.
  String? get awaitingReplacementFrom => _awaitingReplacementFrom;

  /// Whether any still-outstanding `followsReplacement` pending belongs to
  /// [sessionId]. Used to decide whether a refused replacement may clear the
  /// follow.
  bool hasFollowForSession(String sessionId) => _pendingCommands.values.any(
    (pending) =>
        pending.followsReplacement && pending.sessionId == sessionId,
  );

  /// Starts waiting for [oldId] to be replaced. Cancels any prior follow timer:
  /// only one replacement can be in flight at a time.
  void beginReplacementFollow(String oldId) {
    // A second replacement targeting a different session supersedes the first:
    // its pending can never match the new witness, so fail it now rather than
    // letting its 30 s command timeout be the only settle path. A same-id retry
    // shares the witness, so it is left alone.
    abandonReplacement(
      (pending) => pending.sessionId != oldId,
      'superseded',
    );
    _replacementTimer?.cancel();
    _awaitingReplacementFrom = oldId;
    _replacementTimer = _scheduler.schedule(_replacementTimeout, () {
      final old = _awaitingReplacementFrom;
      if (old == null) return;
      clearReplacementFollow();
      // Re-enable the normal restore path *without* moving the desired
      // session: the next `sessions` push re-subscribes the old id, the hub
      // answers `session-gone`, and the existing cap machinery takes it from
      // there.
      _store.resubscribed = false;
      failPending('the session did not come back', sessionId: old);
    }, kind: HubTimerKind.replacement);
  }

  /// Clears the replacement follow: no successor was adopted (or none is still
  /// awaited), so a later restore must not depend on it.
  void clearReplacementFollow() {
    _replacementTimer?.cancel();
    _replacementTimer = null;
    _awaitingReplacementFrom = null;
  }

  /// Completes every still-outstanding `followsReplacement` pending for
  /// [oldId] as `ok`. Called at both replacement witnesses — adoption in
  /// `_onSessions` and `_onSessionGone` while the follow is armed — so the two
  /// arrival orders converge on the same outcome.
  void settleReplacement(String oldId) {
    for (final entry in [..._pendingCommands.entries]) {
      final pending = entry.value;
      if (!pending.followsReplacement || pending.sessionId != oldId) continue;
      _pendingCommands.remove(entry.key);
      pending.timer?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.complete(const CommandResult(ok: true));
      }
    }
  }

  /// Fails and removes every outstanding `followsReplacement` pending matching
  /// [matches], cancelling its command timer and completing it `ok:false` with
  /// [error]. Used when a replacement is abandoned before its witness can
  /// arrive: a second replacement supersedes it, or the user navigates away.
  void abandonReplacement(
    bool Function(PendingCommand pending) matches,
    String error,
  ) {
    for (final entry in [..._pendingCommands.entries]) {
      final pending = entry.value;
      if (!pending.followsReplacement || !matches(pending)) continue;
      _pendingCommands.remove(entry.key);
      pending.timer?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.complete(CommandResult(ok: false, error: error));
      }
    }
  }

  /// Fails and removes every pending request matching [error]: all of them on a
  /// whole-connection failure (`sessionId == null`), otherwise only those
  /// belonging to [sessionId]. Listings are session-less, so only a
  /// whole-connection failure reaches them. A `followsReplacement` command is
  /// skipped when [skipReplacement] is set: the replacement proceeds on the
  /// server regardless of this viewer's reconnect.
  void failPending(
    String error, {
    String? sessionId,
    bool skipReplacement = false,
  }) {
    // Listings are session-less, so only a whole-connection failure
    // (`sessionId == null`) reaches them.
    if (sessionId == null) {
      for (final entry in [..._pendingListings.entries]) {
        final pending = entry.value;
        _pendingListings.remove(entry.key);
        pending.timer?.cancel();
        if (!pending.completer.isCompleted) {
          pending.completer.complete(
            DirListingResult(ok: false, error: error),
          );
        }
      }
    }
    for (final entry in [..._pendingCommands.entries]) {
      final pending = entry.value;
      if (sessionId != null && pending.sessionId != sessionId) continue;
      if (skipReplacement && pending.followsReplacement) continue;
      _pendingCommands.remove(entry.key);
      pending.timer?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.complete(CommandResult(ok: false, error: error));
      }
    }
  }
}
