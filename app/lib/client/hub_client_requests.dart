part of 'hub_client.dart';

/// Bounded wait for a `command-result` before the caller's future fails.
const Duration _commandTimeout = Duration(seconds: 30);

/// Bounded wait for a `/new` or `/fork` replacement to register. pi tears the
/// old session down and registers the successor over two pushes; without this
/// a bridge that dies in between would leave the client waiting forever.
const Duration _replacementTimeout = Duration(seconds: 15);

/// One in-flight `command`, with the session it belongs to (so `session-gone`
/// can fail it) and its timeout handle.
class _PendingCommand {
  _PendingCommand(
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
class _PendingListing {
  _PendingListing(this.completer);

  final Completer<DirListingResult> completer;
  HubTimer? timer;
}

/// Requests and results: allowlisted commands, list-dirs, the shared
/// pending/result correlation, the replacement follow, and the outbound
/// plumbing (hello/send/trySend).
///
/// View it uses on [HubClient]: reads _c._state.capabilities,
/// _c._state.transcripts, _c._socket, _c._credential, _c._scheduler; writes
/// _c._state, _c._pendingCommands, _c._pendingListings, _c._commandCounter,
/// _c._listingCounter, _c._replacementTimer, _c._awaitingReplacementFrom,
/// _c._resubscribed; calls _c._setError, _c._scheduleNotify.
class _HubRequests {
  _HubRequests(this._c);

  final HubClient _c;

  Future<CommandResult> sendCommand(
    String sessionId,
    String name, {
    Map<String, Object?>? args,
    String? id,
  }) {
    return _request(sessionId, id, (commandId) {
      final message = <String, Object?>{
        'protocolVersion': protocolVersion,
        'type': 'command',
        'id': commandId,
        'sessionId': sessionId,
        'name': name,
      };
      if (args != null) message['args'] = args;
      return message;
    });
  }

  Future<CommandResult> listCommands(String sessionId, {String? id}) {
    return _request(sessionId, id, (commandId) => <String, Object?>{
      'protocolVersion': protocolVersion,
      'type': 'command',
      'id': commandId,
      'sessionId': sessionId,
      'name': 'listCommands',
    });
  }

  Future<CommandResult> listModels(String sessionId, {String? id}) {
    return _request(sessionId, id, (commandId) => <String, Object?>{
      'protocolVersion': protocolVersion,
      'type': 'command',
      'id': commandId,
      'sessionId': sessionId,
      'name': 'listModels',
    });
  }

  Future<CommandResult> listTree(String sessionId, {String? id}) {
    return _request(sessionId, id, (commandId) => <String, Object?>{
      'protocolVersion': protocolVersion,
      'type': 'command',
      'id': commandId,
      'sessionId': sessionId,
      'name': 'listTree',
    });
  }

  Future<CommandResult> sessionNew(String sessionId, {String? id}) {
    return _request(sessionId, id, (commandId) {
      return <String, Object?>{
        'protocolVersion': protocolVersion,
        'type': 'command',
        'id': commandId,
        'sessionId': sessionId,
        'name': 'sessionNew',
      };
    }, followsReplacement: true);
  }

  Future<CommandResult> sessionFork(
    String sessionId,
    String entryId, {
    String? id,
  }) {
    return _request(sessionId, id, (commandId) {
      return <String, Object?>{
        'protocolVersion': protocolVersion,
        'type': 'command',
        'id': commandId,
        'sessionId': sessionId,
        'name': 'sessionFork',
        'args': {'entryId': entryId},
      };
    }, followsReplacement: true);
  }

  Future<CommandResult> sessionTree(
    String sessionId,
    String entryId, {
    String? id,
  }) {
    return _request(sessionId, id, (commandId) {
      return <String, Object?>{
        'protocolVersion': protocolVersion,
        'type': 'command',
        'id': commandId,
        'sessionId': sessionId,
        'name': 'sessionTree',
        'args': {'entryId': entryId},
      };
    });
  }

  Future<void> loadCommands(String sessionId) async {
    final result = await listCommands(sessionId);
    if (!result.ok || result.commands == null) return;
    if (!_c._state.transcripts.containsKey(sessionId)) return;
    _c._state = _c._state.copyWith(
      commands: {..._c._state.commands, sessionId: result.commands!},
    );
    _c._scheduleNotify();
  }

  Future<CommandResult> startSession({String? id, String? cwd, bool? trust}) {
    if ((cwd != null || trust != null) &&
        !_c._state.capabilities.contains(capabilityProjectSession)) {
      return Future.value(
        const CommandResult(
          ok: false,
          error: 'this hub cannot start a session in a chosen folder',
        ),
      );
    }
    return _request('', id, (commandId) {
      final message = <String, Object?>{
        'protocolVersion': protocolVersion,
        'type': 'start-session',
        'id': commandId,
      };
      if (cwd != null) message['cwd'] = cwd;
      if (trust != null && cwd != null) message['trust'] = trust;
      return message;
    });
  }

  Future<DirListingResult> listDirs({String? path, String? id}) {
    if (!_c._state.capabilities.contains(capabilityListDirs)) {
      return Future.value(
        const DirListingResult(ok: false, error: 'this hub cannot browse folders'),
      );
    }
    if (_c._socket == null) {
      return Future.value(
        const DirListingResult(ok: false, error: 'not connected'),
      );
    }
    final listingId = id ?? 'dirs-${++_c._listingCounter}';
    final completer = Completer<DirListingResult>();
    final pending = _PendingListing(completer);
    _c._pendingListings[listingId] = pending;
    pending.timer = _c._scheduler.schedule(_commandTimeout, () {
      final removed = _c._pendingListings.remove(listingId);
      if (removed == null || removed.completer.isCompleted) return;
      removed.completer.complete(
        const DirListingResult(ok: false, error: 'timed out'),
      );
    }, kind: HubTimerKind.command);
    final message = <String, Object?>{
      'protocolVersion': protocolVersion,
      'type': 'list-dirs',
      'id': listingId,
    };
    if (path != null && path.isNotEmpty) message['path'] = path;
    final error = _trySend(message);
    if (error != null) {
      _c._pendingListings.remove(listingId);
      pending.timer?.cancel();
      completer.complete(DirListingResult(ok: false, error: '$error'));
    }
    return completer.future;
  }

  Future<CommandResult> killSession(String sessionId, {String? id}) {
    return _request('', id, (commandId) => <String, Object?>{
      'protocolVersion': protocolVersion,
      'type': 'kill-session',
      'id': commandId,
      'sessionId': sessionId,
    });
  }

  /// The shared body of every request/result command: registers a pending
  /// entry under a generated id, schedules the bounded wait, sends [build]'s
  /// frame, and completes when the matching `command-result` arrives.
  Future<CommandResult> _request(
    String pendingSessionId,
    String? id,
    Map<String, Object?> Function(String commandId) build, {
    bool followsReplacement = false,
  }) {
    if (_c._socket == null) {
      // Dropping the request silently would leave the UI spinning forever.
      return Future.value(
        const CommandResult(ok: false, error: 'not connected'),
      );
    }
    final commandId = id ?? 'cmd-${++_c._commandCounter}';
    final completer = Completer<CommandResult>();
    final pending = _PendingCommand(
      pendingSessionId,
      completer,
      followsReplacement: followsReplacement,
    );
    _c._pendingCommands[commandId] = pending;
    pending.timer = _c._scheduler.schedule(_commandTimeout, () {
      final removed = _c._pendingCommands.remove(commandId);
      if (removed == null || removed.completer.isCompleted) return;
      removed.completer.complete(
        const CommandResult(ok: false, error: 'timed out'),
      );
    }, kind: HubTimerKind.command);
    // Arm the follow immediately before the frame goes out, so the successor's
    // `sessions` push can never race ahead of a set flag. `_onSessions` keys
    // off the old id, not `activeSessionId`, so a `session-gone` arriving first
    // does not lose it.
    if (followsReplacement) _beginReplacementFollow(pendingSessionId);
    final error = _trySend(build(commandId));
    if (error != null) {
      // A closing socket must not leave the caller with a thrown exception and
      // an entry that only the 30s timeout would clear.
      _c._pendingCommands.remove(commandId);
      pending.timer?.cancel();
      if (followsReplacement) _clearReplacementFollow();
      completer.complete(CommandResult(ok: false, error: '$error'));
    }
    return completer.future;
  }

  /// Starts waiting for [oldId] to be replaced. Cancels any prior follow timer:
  /// only one replacement can be in flight at a time.
  void _beginReplacementFollow(String oldId) {
    // A second replacement targeting a different session supersedes the first:
    // its pending can never match the new witness, so fail it now rather than
    // letting its 30 s command timeout be the only settle path. A same-id retry
    // shares the witness, so it is left alone.
    _abandonReplacementPendings(
      (pending) => pending.sessionId != oldId,
      'superseded',
    );
    _c._replacementTimer?.cancel();
    _c._awaitingReplacementFrom = oldId;
    _c._replacementTimer = _c._scheduler.schedule(_replacementTimeout, () {
      final old = _c._awaitingReplacementFrom;
      if (old == null) return;
      _clearReplacementFollow();
      // Re-enable the normal restore path *without* moving `_desiredSessionId`:
      // the next `sessions` push re-subscribes the old id, the hub answers
      // `session-gone`, and the existing cap machinery takes it from there.
      _c._resubscribed = false;
      _failPending('the session did not come back', sessionId: old);
    }, kind: HubTimerKind.replacement);
  }

  /// Clears the replacement follow: no successor was adopted (or none is still
  /// awaited), so a later restore must not depend on it.
  void _clearReplacementFollow() {
    _c._replacementTimer?.cancel();
    _c._replacementTimer = null;
    _c._awaitingReplacementFrom = null;
  }

  /// Completes every still-outstanding `followsReplacement` pending for
  /// [oldId] as `ok`. Called at both replacement witnesses — adoption in
  /// `_onSessions` and `_onSessionGone` while the follow is armed — so the two
  /// arrival orders converge on the same outcome.
  void _settleReplacementPendings(String oldId) {
    for (final entry in [..._c._pendingCommands.entries]) {
      final pending = entry.value;
      if (!pending.followsReplacement || pending.sessionId != oldId) continue;
      _c._pendingCommands.remove(entry.key);
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
  void _abandonReplacementPendings(
    bool Function(_PendingCommand pending) matches,
    String error,
  ) {
    for (final entry in [..._c._pendingCommands.entries]) {
      final pending = entry.value;
      if (!pending.followsReplacement || !matches(pending)) continue;
      _c._pendingCommands.remove(entry.key);
      pending.timer?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.complete(CommandResult(ok: false, error: error));
      }
    }
  }

  Map<String, Object?> _hello() => <String, Object?>{
    'protocolVersion': protocolVersion,
    'type': 'hello',
    ...?_c._credential,
  };

  void _send(Map<String, Object?> message) {
    final socket = _c._socket;
    if (socket == null) return;
    socket.send(encode(message));
  }

  /// Sends [message], converting the synchronous throw of a closing socket into
  /// a recorded error rather than letting it escape into the UI. Returns the
  /// thrown error, or null when the frame went out.
  Object? _trySend(Map<String, Object?> message) {
    try {
      _send(message);
      return null;
    } catch (error) {
      _c._setError('$error', connection: true);
      return error;
    }
  }

  void _failPending(
    String error, {
    String? sessionId,
    bool skipReplacement = false,
  }) {
    // Listings are session-less, so only a whole-connection failure
    // (`sessionId == null`) reaches them.
    if (sessionId == null) {
      for (final entry in [..._c._pendingListings.entries]) {
        final pending = entry.value;
        _c._pendingListings.remove(entry.key);
        pending.timer?.cancel();
        if (!pending.completer.isCompleted) {
          pending.completer.complete(
            DirListingResult(ok: false, error: error),
          );
        }
      }
    }
    for (final entry in [..._c._pendingCommands.entries]) {
      final pending = entry.value;
      if (sessionId != null && pending.sessionId != sessionId) continue;
      if (skipReplacement && pending.followsReplacement) continue;
      _c._pendingCommands.remove(entry.key);
      pending.timer?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.complete(CommandResult(ok: false, error: error));
      }
    }
  }
}
