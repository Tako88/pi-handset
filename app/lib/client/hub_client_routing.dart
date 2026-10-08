part of 'hub_client.dart';

/// Consecutive `resync-required` answers a session may provoke before the
/// client stops re-requesting and surfaces an error. A resync whose snapshot is
/// itself dropped would otherwise loop forever.
const int _maxConsecutiveResyncs = 3;

/// Consecutive `session-gone` answers a session may provoke before the client
/// stops re-subscribing and surfaces an error. Under the cap a rejection re-arms
/// the re-subscribe (which recovers the race the M10b fix targeted); past it the
/// session is genuinely gone and retrying forever only churns the registry.
const int _maxConsecutiveSessionGone = 3;

/// Inbound frame routing: decode one frame, dispatch by type, and turn each
/// into state, transcripts, streams and notices.
///
/// View it uses on [HubClient]: reads _c._store, _c._pending,
/// _c._historyPages, _settlesController, _leafEventsController,
/// _tokenStore, _credential; writes _c._store; calls
/// _markConnected, _setError, _scheduleNotify,
/// _c._connection._cancelAuthWatchdog, _c._connection._restoreSubscription,
/// _subscribe, requestHistory, _pending.*, _historyPages.*.
class _HubRouter {
  _HubRouter(this._c);

  final HubClient _c;

  /// Entry point for one inbound frame. Wrapped so a throw cannot escape into
  /// the socket's `listen` callback — an uncaught async error there is an
  /// unhandled zone error. A backstop: outbound sends have their own guard.
  void _onFrame(Object? frame) {
    try {
      _handleFrame(frame);
    } catch (error) {
      // A frame-handling fault is a protocol/logic bug, not a connection
      // failure; reconnecting will not fix it, so it must outlive one.
      _c._setError('$error', connection: false);
    }
  }

  void _handleFrame(Object? frame) {
    if (frame is! String) return;
    final result = decode(frame);
    if (!result.ok) return;
    final message = result.value!;
    switch (message['type']) {
      case 'paired':
        unawaited(_onPaired(message['token']! as String));
      case 'sessions':
        _onSessions(message);
      case 'event':
        _onEvent((message['payload']! as Map).cast<String, Object?>());
      case 'snapshot':
        _onSnapshot(message);
      case 'command-result':
        _onCommandResult(message);
      case 'dir-listing':
        _onDirListing(message);
      case 'resync-required':
        _onResyncRequired(message['sessionId']! as String);
      case 'session-gone':
        _onSessionGone(message['sessionId']! as String);
      case 'agent-settled':
        _onAgentSettled(message);
      case 'spawn-failed':
        _onSpawnFailed(message);
    }
  }

  /// A spawn the hub was tracking failed. The unknown-id guard comes first: a
  /// viewer that never received the pending push (or already saw the row go)
  /// must not be bannered for a row it never saw. Otherwise the placeholder is
  /// removed and the failure is surfaced as a session notice, never a
  /// connection error — a hub failure does not mean this connection is broken.
  void _onSpawnFailed(Map<String, Object?> message) {
    final id = message['id']! as String;
    if (!_c._store.state.pendingSessions.any((pending) => pending.id == id)) {
      return;
    }
    _c._store.update(
      (state) => state.copyWith(
        pendingSessions: state.pendingSessions
            .where((pending) => pending.id != id)
            .toList(),
      ),
    );
    _c._setError(message['error']! as String, connection: false);
  }

  /// Surfaces a settle for notification. Deliberately no state change and no
  /// `_c._scheduleNotify`: it must not rebuild the transcript, and it must reach
  /// the app even for a session it is not viewing or subscribed to.
  void _onAgentSettled(Map<String, Object?> message) {
    if (_c._settlesController.isClosed) return;
    _c._settlesController.add(
      AgentSettledEvent(
        sessionId: message['sessionId']! as String,
        label: message['label']! as String,
        text: message['text']! as String,
        truncated: message['truncated']! as bool,
      ),
    );
  }

  Future<void> _onPaired(String token) async {
    _c._connection._cancelAuthWatchdog();
    // Later reconnects authenticate with the token, not the spent ticket.
    _c._credential = {'token': token};
    try {
      // Report connected only once the token is durable: a kill in the
      // unawaited-write window would silently lose it and re-pair.
      await _c._tokenStore.write(token);
    } catch (error) {
      _c._setError('could not persist token: $error', connection: false);
      return;
    }
    _c._markConnected();
    _c._connection._restoreSubscription();
  }

  void _onSessions(Map<String, Object?> message) {
    _c._connection._cancelAuthWatchdog();
    final raw = message['sessions']! as List;
    final summaries = raw
        .map(
          (entry) =>
              SessionSummary.fromJson((entry as Map).cast<String, Object?>()),
        )
        .toList();
    // Absent means a hub with no pending spawns (or one that predates the
    // field): the empty list, so the placeholder section never renders.
    final rawPending = message['pending'];
    final pendingSessions = rawPending is List
        ? rawPending
              .map(
                (entry) => PendingSessionSummary.fromJson(
                  (entry as Map).cast<String, Object?>(),
                ),
              )
              .toList()
        : const <PendingSessionSummary>[];
    // Absent means a hub that predates the field: an empty set, so the folder
    // feature is hidden rather than probed with a frame that would disconnect.
    final rawCapabilities = message['capabilities'];
    final capabilities = rawCapabilities is List
        ? rawCapabilities.whereType<String>().toSet()
        : <String>{};
    _c._store.update(
      (state) => state.copyWith(
        sessions: summaries,
        capabilities: capabilities,
        pendingSessions: pendingSessions,
      ),
    );
    // The hub pushes `sessions` on authentication; its arrival is how a
    // token-authenticated connection is confirmed (there is no `paired`).
    _c._markConnected();
    final awaited = _c._pending.awaitingReplacementFrom;
    if (awaited != null) {
      // A replacement is in flight: adopt its successor and *never* fall back
      // to `_c._connection._restoreSubscription`, which would re-subscribe the
      // dead id and walk the give-up counter against a session that is
      // deliberately gone.
      SessionSummary? successor;
      for (final summary in summaries) {
        if (summary.replacesSessionId == awaited) {
          successor = summary;
          break;
        }
      }
      if (successor != null) {
        _c._pending.settleReplacement(awaited);
        _c._pending.clearReplacementFollow();
        _c._store.resubscribed = true;
        // Adoption puts/removes no predecessor transcript, so it must not touch
        // the predecessor derivation: the predecessor's own `session-gone`
        // classifies it (drop or keep) and the derivation follows its
        // transcript there.
        _c._subscribe(successor.sessionId, restoring: true);
      }
    } else {
      _c._connection._restoreSubscription();
    }
    // Explicitly, and not left to `_c._markConnected`: `_setStatus` early-returns
    // when the status is unchanged, so it notifies only on the first push of a
    // connection. Without this line every later registry change (a session
    // registering, dying, or changing agent state) updates the list in memory
    // and never reaches the UI.
    _c._scheduleNotify();
  }

  void _onEvent(Map<String, Object?> payload) {
    final sessionId = _c._store.state.activeSessionId;
    if (sessionId == null) return;
    final transcript =
        _c._store.transcript(sessionId) ?? const SessionTranscript();
    switch (payload['kind']) {
      case 'stream':
        final seq = (payload['seq']! as num).toInt();
        final lastSeq = seq > transcript.lastSeq ? seq : transcript.lastSeq;
        final text = payload['text'];
        final isThinking = payload['phase'] == 'thinking';
        if (text is String && isThinking) {
          // Reasoning streams like the reply but into its own buffer, so the
          // two can never be confused on the wire or on screen.
          _c._store.putTranscript(
            sessionId,
            transcript.copyWith(
              streamingThinking: transcript.streamingThinking + text,
              thinking: true,
              lastSeq: lastSeq,
            ),
          );
        } else if (text is String) {
          _c._store.putTranscript(
            sessionId,
            transcript.copyWith(
              streamingText: transcript.streamingText + text,
              streaming: true,
              // The first byte of text proves thinking is over. The reasoning
              // buffer survives: only the commit retires it.
              thinking: false,
              lastSeq: lastSeq,
            ),
          );
        } else {
          // A content-free phase frame (no `text`): a liveness signal, not a
          // delta. It must not reset the in-flight buffer or crash on the
          // missing text.
          _c._store.putTranscript(
            sessionId,
            transcript.copyWith(
              thinking: payload['phase'] == 'thinking'
                  ? true
                  : transcript.thinking,
              lastSeq: lastSeq,
            ),
          );
        }
      case 'usage':
        // State, not a row: an explicit case keeps it out of `entries`, where an
        // unknown payload would otherwise be appended and then ignored by the
        // renderer.
        final window = payload['contextWindow'];
        final tokens = payload['tokens'];
        final rawModel = payload['model'];
        final usableWindow = window is num && window > 0;
        _c._store.putTranscript(
          sessionId,
          transcript.copyWith(
            contextUsage: usableWindow
                ? ContextUsage(
                    tokens: tokens is num ? tokens.toInt() : null,
                    contextWindow: window.toInt(),
                  )
                : transcript.contextUsage,
            thinkingLevel: usableWindow
                ? payload['thinkingLevel'] as String?
                : transcript.thinkingLevel,
            // Read OUTSIDE the window guard: the menu label must not depend on
            // the token estimate, and a usage frame can carry the model while
            // the window is absent or zero.
            currentModel: rawModel is Map
                ? ModelSummary.fromJson(rawModel.cast<String, Object?>())
                : transcript.currentModel,
          ),
        );
      case 'agent':
        final agentState = payload['state']! as String;
        // Terminal state is `settled`, never a message-level end. Clearing the
        // buffer too keeps a settle-without-message from hiding the text and
        // leaving the next stream appending to a stale buffer.
        final running = agentState == 'running';
        _c._store.putTranscript(
          sessionId,
          transcript.copyWith(
            agentState: agentState,
            streaming: running ? transcript.streaming : false,
            streamingText: running ? transcript.streamingText : '',
            streamingThinking: running ? transcript.streamingThinking : '',
            thinking: running ? transcript.thinking : false,
          ),
        );
      case 'message':
        // Only an assistant message commits the reply: a relayed user message
        // (a mid-stream steer) or a tool result appends without wiping the
        // text still in flight.
        final message = payload['message'];
        // A truncated marker (`{truncated:true, bytes}`) replaces an oversized
        // assistant message, so it carries no `role`; it still stands in for
        // the reply and must clear the in-flight phase and buffer.
        final isTruncated = message is Map && message['truncated'] == true;
        final fromAssistant =
            message is Map && (message['role'] == 'assistant' || isTruncated);
        _c._store.putTranscript(
          sessionId,
          _c._store.withEntries(sessionId, transcript, message).copyWith(
            streamingText: fromAssistant ? '' : transcript.streamingText,
            // Cleared in the SAME update that commits the message: the commit
            // carries the reasoning block itself, so a later clear would render
            // the same reasoning twice.
            streamingThinking: fromAssistant ? '' : transcript.streamingThinking,
            streaming: fromAssistant ? false : transcript.streaming,
            thinking: fromAssistant ? false : transcript.thinking,
          ),
        );
      case 'status':
        // A compaction announcement is transient state, not transcript content:
        // it carries no message, and appending it would leave a row that renders
        // nothing and then outlives the compaction it describes.
        if (payload['event'] == 'compacting') {
          _c._store.putTranscript(
            sessionId,
            transcript.copyWith(compacting: payload['active'] == true),
          );
          break;
        }
        // Any other `status` is relayed raw so the renderer can decide. An error
        // status ends the turn without a settle, so clear the thinking phase
        // here or `Thinking…` would stick forever.
        final isErrorStatus = payload['event'] == 'error';
        _c._store.putTranscript(
          sessionId,
          _c._store.withEntries(sessionId, transcript, payload).copyWith(
            thinking: isErrorStatus ? false : transcript.thinking,
            streamingThinking: isErrorStatus ? '' : transcript.streamingThinking,
          ),
        );
      case 'tool':
        // A bridge-normalized tool annotation: retained raw in `entries`, where
        // the transcript model pairs its view to the call/result row. Appended
        // in arrival order, like any other entry.
        _c._store.putTranscript(
          sessionId,
          _c._store.withEntries(sessionId, transcript, payload),
        );
      case 'leaf':
        // The bridge moved the leaf (or pi did, on the PC). A signal, not a row:
        // re-request history so the transcript re-baselines to the new branch,
        // and announce the move so the shell can settle a pending tree tap.
        if (!_c._leafEventsController.isClosed) {
          _c._leafEventsController.add(
            LeafEvent(
              sessionId: sessionId,
              leafId: payload['leafId'] as String?,
            ),
          );
        }
        _c.requestHistory(sessionId);
      default:
        // An unknown payload is retained rather than dropped, so a future
        // renderer can consume it; nothing in this build does.
        _c._store.putTranscript(
          sessionId,
          _c._store.withEntries(sessionId, transcript, payload),
        );
    }
    _c._scheduleNotify();
  }

  void _onSnapshot(Map<String, Object?> message) {
    final sessionId = message['sessionId']! as String;
    // Routing fields first: a discarded frame must not be decoded (round 2's
    // missed edge), so `entries` is only touched on an apply path.
    final token = message['cursor'] as String?;
    final older = message['older'] == true;
    final olderCursor = message['olderCursor'] as String?;

    if (older) {
      final existing = _c._store.transcript(sessionId);
      // Apply only the page this session actually asked for. Anything else — an
      // absent token, a stale one, or no transcript — is discarded touching
      // nothing, so a stale page cannot reset the resync livelock streak (R5)
      // nor fabricate a baseline.
      if (!_c._historyPages.matchesPending(sessionId, token) ||
          existing == null) {
        return;
      }
      _c._historyPages.dropPending(sessionId);
      _c._store.removeResyncCount(sessionId);
      _c._store.removeGoneCount(sessionId);
      final entries = (message['entries']! as List).cast<Object?>();
      // Prepend through the session's own derivation. `copyWith` carries the
      // in-flight stream and every ambient field across (design D + fact 13);
      // the lists are copied so a retained snapshot is a true value.
      final derivation = _c._store.derivation(sessionId)!;
      derivation.rebuild([...entries, ...existing.entries]);
      _c._store.putTranscript(
        sessionId,
        existing.copyWith(
          entries: List<Object?>.of(derivation.entries),
          blocks: List<TranscriptBlock>.of(derivation.blocks),
          lastSeq: (message['lastSeq']! as num).toInt(),
          agentState: message['agentState']! as String,
          truncated: message['truncated']! as bool,
          olderCursor: olderCursor,
          historyLoading: false,
        ),
      );
      _c._scheduleNotify();
      return;
    }

    // No `older` flag is the newest-page baseline: a REPLACE that also
    // invalidates any page in flight for this session.
    _c._historyPages.dropPending(sessionId);
    // A delivered baseline breaks any resync or gone streak.
    _c._store.removeResyncCount(sessionId);
    _c._store.removeGoneCount(sessionId);
    final entries = (message['entries']! as List).cast<Object?>();
    final derivation = TranscriptDerivation()..rebuild(entries);
    _c._store.setDerivation(sessionId, derivation);
    _c._store.putTranscript(
      sessionId,
      SessionTranscript(
        entries: List<Object?>.of(derivation.entries),
        blocks: List<TranscriptBlock>.of(derivation.blocks),
        lastSeq: (message['lastSeq']! as num).toInt(),
        agentState: message['agentState']! as String,
        truncated: message['truncated']! as bool,
        historyLoaded: true,
        olderCursor: olderCursor,
        // A snapshot re-baselines the transcript, so the usage reading has to be
        // carried across explicitly — and from THIS session's transcript, never
        // from whatever is currently active. The thinking level is the same. So
        // are the current model and the compaction indicator, which the snapshot
        // says nothing about.
        contextUsage: _c._store.transcript(sessionId)?.contextUsage,
        thinkingLevel: _c._store.transcript(sessionId)?.thinkingLevel,
        currentModel: _c._store.transcript(sessionId)?.currentModel,
        compacting: _c._store.transcript(sessionId)?.compacting ?? false,
      ),
    );
    _c._scheduleNotify();
  }

  /// A listing's rejection (an invalid path, a trust-store fault) arrives as a
  /// `command-result` carrying the listing's id, so listings are consulted
  /// first: the id spaces are disjoint by construction, but the routing order
  /// is the guarantee. A listing failure never carries `ok:true`.
  void _onCommandResult(Map<String, Object?> message) {
    final id = message['id']! as String;
    final listing = _c._pending.takeListing(id);
    if (listing != null) {
      if (listing.completer.isCompleted) return;
      listing.timer?.cancel();
      listing.completer.complete(
        DirListingResult(ok: false, error: message['error'] as String?),
      );
      return;
    }
    final pending = _c._pending.peekCommand(id);
    if (pending == null || pending.completer.isCompleted) return;
    if (pending.followsReplacement) {
      // A successful ack is not the witness — the successor's registration is.
      // Leave the pending and the follow armed so adoption settles it.
      if (message['ok']! as bool) return;
      // A refused replacement will never produce a successor: fail the caller
      // and disarm the follow. Left armed with no pending to settle, it would
      // suppress every legitimate restore for 15 s, and a `session-gone` for
      // the id would skip the re-arm.
      _c._pending.takeCommand(id);
      pending.timer?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.complete(
          CommandResult(ok: false, error: message['error'] as String?),
        );
      }
      if (_c._pending.awaitingReplacementFrom == pending.sessionId &&
          !_c._pending.hasFollowForSession(pending.sessionId)) {
        _c._pending.clearReplacementFollow();
      }
      return;
    }
    _c._pending.takeCommand(id);
    pending.timer?.cancel();
    final rawCommands = message['commands'];
    final rawModels = message['models'];
    final rawTree = message['tree'];
    pending.completer.complete(
      CommandResult(
        ok: message['ok']! as bool,
        error: message['error'] as String?,
        commands: rawCommands is List
            ? rawCommands
                  .map(
                    (entry) => SlashCommand.fromJson(
                      (entry as Map).cast<String, Object?>(),
                    ),
                  )
                  .toList()
            : null,
        models: rawModels is List
            ? rawModels
                  .map(
                    (entry) => ModelSummary.fromJson(
                      (entry as Map).cast<String, Object?>(),
                    ),
                  )
                  .toList()
            : null,
        // Absent maps to null ("unknown"), never false.
        queued: message['queued'] as bool?,
        tree: rawTree is List
            ? rawTree
                  .map(
                    (entry) => TreeNodeSummary.fromJson(
                      (entry as Map).cast<String, Object?>(),
                    ),
                  )
                  .toList()
            : null,
        treeTruncated: message['treeTruncated'] as bool?,
        // Absent (an older bridge) and null both mean "unknown position".
        leafId: message['leafId'] as String?,
      ),
    );
  }

  void _onDirListing(Map<String, Object?> message) {
    final id = message['id']! as String;
    final pending = _c._pending.takeListing(id);
    if (pending == null || pending.completer.isCompleted) return;
    pending.timer?.cancel();
    pending.completer.complete(
      DirListingResult(
        ok: true,
        listing: DirListing(
          path: message['path']! as String,
          root: message['root']! as String,
          trust: message['trust'] as bool?,
          trustRequired: message['trustRequired']! as bool,
          entries: (message['entries']! as List).cast<String>(),
          truncated: message['truncated']! as bool,
        ),
      ),
    );
  }

  void _onResyncRequired(String sessionId) {
    final count = _c._store.resyncCount(sessionId) + 1;
    _c._store.setResyncCount(sessionId, count);
    if (count > _maxConsecutiveResyncs) {
      // Re-requesting forever is the livelock; stop and surface it instead.
      _c._setError(
        'gave up resyncing $sessionId after $_maxConsecutiveResyncs attempts',
        connection: false,
      );
      return;
    }
    _c.requestHistory(sessionId);
  }

  void _onSessionGone(String sessionId) {
    _c._store.removeResyncCount(sessionId);
    final count = _c._store.goneCount(sessionId) + 1;
    _c._store.setGoneCount(sessionId, count);
    final gaveUp = count > _maxConsecutiveSessionGone;
    // The awaited session vanishing is the replacement's first witness: the
    // session is meant to be gone, so its pending is settled rather than
    // failed, and the follow stays armed until the successor names it (or the
    // follow times out). `_c._store.resubscribed` is deliberately left alone — the
    // successor's push must not lose to a restore of the dead id.
    final awaiting = _c._pending.awaitingReplacementFrom == sessionId;
    if (awaiting) _c._pending.settleReplacement(sessionId);
    // A `session-gone` answering an automatic restore is the re-subscribe
    // racing the agent's re-registration; only once the cap is past — or when
    // the user subscribed directly and the session is simply gone — is the
    // transcript genuinely obsolete.
    final keepTranscript = !gaveUp && _c._store.isRestored(sessionId);
    if (gaveUp) {
      // The session is genuinely gone. Re-arming again would resend
      // subscribe+history on every registry push forever, so clear the desired
      // session and say so rather than looping silently.
      _c._store.removeRestored(sessionId);
      if (_c._store.desiredSessionId == sessionId) _c._store.desiredSessionId = null;
    } else if (!awaiting && _c._store.desiredSessionId == sessionId) {
      // A gone session may come back (an agent restart, or a re-subscribe that
      // raced the agent's re-registration): drop the one-shot guard so the next
      // `sessions` push re-attaches to the session the user was viewing.
      _c._store.resubscribed = false;
    }
    _c._pending.failPending('session gone', sessionId: sessionId);
    final sessions = _c._store.state.sessions
        .where((summary) => summary.sessionId != sessionId)
        .toList();
    final transcripts = {..._c._store.state.transcripts};
    if (!keepTranscript) {
      transcripts.remove(sessionId);
      _c._store.removeDerivation(sessionId);
      _c._historyPages.dropPending(sessionId);
    }
    // Only the genuinely-gone branch drops the cache: under the cap the session
    // may come back (the re-subscribe race), and a kept key avoids a flicker.
    final commands = gaveUp
        ? ({..._c._store.state.commands}..remove(sessionId))
        : _c._store.state.commands;
    _c._store.update(
      (state) => state.copyWith(
        sessions: sessions,
        transcripts: transcripts,
        commands: commands,
        activeSessionId: state.activeSessionId == sessionId
            ? null
            : state.activeSessionId,
      ),
    );
    if (gaveUp) {
      _c._setError(
        'the session $sessionId is gone; pick another session to view',
        connection: false,
      );
    } else {
      _c._scheduleNotify();
    }
  }

}
