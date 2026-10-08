/// Inbound frame routing: decode one frame, dispatch by type, and turn each
/// into state, transcripts, streams and notices.
///
/// Extracted from the hub client into free functions taking a [RouterContext].
/// The context carries the collaborators the router writes through — the state
/// store, the pending registry, the paging bookkeeper and the notification
/// coalescer — plus the client's outbound seams. The router owns no state of
/// its own and never holds a hub client.
library;

import 'dart:async';

import '../protocol/protocol.dart';
import 'context_usage.dart';
import 'history_pages.dart';
import 'hub_models.dart';
import 'notify_coalescer.dart';
import 'pending_registry.dart';
import 'session_state.dart';
import 'transcript.dart';

/// The collaborators and client seams one inbound frame is routed through.
///
/// Fourteen fields is the intrinsic width of routing: it spans state, pending
/// requests, paging, notification, subscription and connection control. The
/// client hands in tear-offs of its stable seam methods, so their bodies can
/// move without a re-pointing.
class RouterContext {
  RouterContext({
    required this.store,
    required this.pending,
    required this.historyPages,
    required this.notify,
    required this.subscribe,
    required this.markConnected,
    required this.setError,
    required this.cancelAuthWatchdog,
    required this.restoreSubscription,
    required this.persistToken,
    required this.emitSettled,
    required this.emitLeaf,
    required this.resyncCap,
    required this.goneCap,
  });

  /// The single writer of the state the router reads and writes.
  final SessionStateStore store;

  /// In-flight request bookkeeping: the pending maps and the replacement
  /// follow.
  final PendingRegistry pending;

  /// History paging: the single-flight cursor and its bounded wait.
  final HistoryPages historyPages;

  /// Coalesces the state notifications the router raises.
  final NotifyCoalescer notify;

  /// Subscribe to a session (the client's shared subscribe body).
  final void Function(String sessionId, {bool restoring}) subscribe;

  /// Mark the connection authenticated.
  final void Function() markConnected;

  /// Record a user-visible error and whether a later connection supersedes it.
  final void Function(String message, {required bool connection}) setError;

  /// Cancel the authentication watchdog of the current attempt.
  final void Function() cancelAuthWatchdog;

  /// Restore the previous connection's subscription once authenticated.
  final void Function() restoreSubscription;

  /// Persist a `paired` token: set the credential, then await the write.
  final Future<void> Function(String token) persistToken;

  /// Emit a settle notification.
  final void Function(AgentSettledEvent event) emitSettled;

  /// Emit a leaf move.
  final void Function(LeafEvent event) emitLeaf;

  /// The consecutive `resync-required` cap the client exposes to the tests.
  final int resyncCap;

  /// The consecutive `session-gone` cap the client exposes to the tests.
  final int goneCap;
}

/// Entry point for one inbound frame. Wrapped so a throw cannot escape into
/// the socket's `listen` callback — an uncaught async error there is an
/// unhandled zone error. A backstop: outbound sends have their own guard.
void handleInboundFrame(Object? frame, RouterContext ctx) {
  try {
    _handleFrame(frame, ctx);
  } catch (error) {
    // A frame-handling fault is a protocol/logic bug, not a connection
    // failure; reconnecting will not fix it, so it must outlive one.
    ctx.setError('$error', connection: false);
  }
}

void _handleFrame(Object? frame, RouterContext ctx) {
  if (frame is! String) return;
  final result = decode(frame);
  if (!result.ok) return;
  final message = result.value!;
  switch (message['type']) {
    case 'paired':
      unawaited(_onPaired(ctx, message['token']! as String));
    case 'sessions':
      _onSessions(ctx, message);
    case 'event':
      _onEvent(ctx, (message['payload']! as Map).cast<String, Object?>());
    case 'snapshot':
      _onSnapshot(ctx, message);
    case 'command-result':
      _onCommandResult(ctx, message);
    case 'dir-listing':
      _onDirListing(ctx, message);
    case 'resync-required':
      _onResyncRequired(ctx, message['sessionId']! as String);
    case 'session-gone':
      _onSessionGone(ctx, message['sessionId']! as String);
    case 'agent-settled':
      _onAgentSettled(ctx, message);
    case 'spawn-failed':
      _onSpawnFailed(ctx, message);
  }
}

/// A spawn the hub was tracking failed. The unknown-id guard comes first: a
/// viewer that never received the pending push (or already saw the row go)
/// must not be bannered for a row it never saw. Otherwise the placeholder is
/// removed and the failure is surfaced as a session notice, never a
/// connection error — a hub failure does not mean this connection is broken.
void _onSpawnFailed(RouterContext ctx, Map<String, Object?> message) {
  final id = message['id']! as String;
  if (!ctx.store.state.pendingSessions.any((pending) => pending.id == id)) {
    return;
  }
  ctx.store.update(
    (state) => state.copyWith(
      pendingSessions: state.pendingSessions
          .where((pending) => pending.id != id)
          .toList(),
    ),
  );
  ctx.setError(message['error']! as String, connection: false);
}

/// Surfaces a settle for notification. Deliberately no state change and no
/// `ctx.notify.schedule`: it must not rebuild the transcript, and it must
/// reach the app even for a session it is not viewing or subscribed to.
void _onAgentSettled(RouterContext ctx, Map<String, Object?> message) {
  ctx.emitSettled(
    AgentSettledEvent(
      sessionId: message['sessionId']! as String,
      label: message['label']! as String,
      text: message['text']! as String,
      truncated: message['truncated']! as bool,
    ),
  );
}

Future<void> _onPaired(RouterContext ctx, String token) async {
  ctx.cancelAuthWatchdog();
  try {
    // Report connected only once the token is durable: a kill in the
    // unawaited-write window would silently lose it and re-pair.
    await ctx.persistToken(token);
  } catch (error) {
    ctx.setError('could not persist token: $error', connection: false);
    return;
  }
  ctx.markConnected();
  ctx.restoreSubscription();
}

void _onSessions(RouterContext ctx, Map<String, Object?> message) {
  ctx.cancelAuthWatchdog();
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
  ctx.store.update(
    (state) => state.copyWith(
      sessions: summaries,
      capabilities: capabilities,
      pendingSessions: pendingSessions,
    ),
  );
  // The hub pushes `sessions` on authentication; its arrival is how a
  // token-authenticated connection is confirmed (there is no `paired`).
  ctx.markConnected();
  final awaited = ctx.pending.awaitingReplacementFrom;
  if (awaited != null) {
    // A replacement is in flight: adopt its successor and *never* fall back
    // to `ctx.restoreSubscription`, which would re-subscribe the dead id and
    // walk the give-up counter against a session that is deliberately gone.
    SessionSummary? successor;
    for (final summary in summaries) {
      if (summary.replacesSessionId == awaited) {
        successor = summary;
        break;
      }
    }
    if (successor != null) {
      ctx.pending.settleReplacement(awaited);
      ctx.pending.clearReplacementFollow();
      ctx.store.resubscribed = true;
      // Adoption puts/removes no predecessor transcript, so it must not touch
      // the predecessor derivation: the predecessor's own `session-gone`
      // classifies it (drop or keep) and the derivation follows its
      // transcript there.
      ctx.subscribe(successor.sessionId, restoring: true);
    }
  } else {
    ctx.restoreSubscription();
  }
  // Explicitly, and not left to `ctx.markConnected`: `_setStatus` early-returns
  // when the status is unchanged, so it notifies only on the first push of a
  // connection. Without this line every later registry change (a session
  // registering, dying, or changing agent state) updates the list in memory
  // and never reaches the UI.
  ctx.notify.schedule();
}

void _onEvent(RouterContext ctx, Map<String, Object?> payload) {
  final sessionId = ctx.store.state.activeSessionId;
  if (sessionId == null) return;
  final transcript = ctx.store.transcript(sessionId) ?? const SessionTranscript();
  switch (payload['kind']) {
    case 'stream':
      final seq = (payload['seq']! as num).toInt();
      final lastSeq = seq > transcript.lastSeq ? seq : transcript.lastSeq;
      final text = payload['text'];
      final isThinking = payload['phase'] == 'thinking';
      if (text is String && isThinking) {
        // Reasoning streams like the reply but into its own buffer, so the
        // two can never be confused on the wire or on screen.
        ctx.store.putTranscript(
          sessionId,
          transcript.copyWith(
            streamingThinking: transcript.streamingThinking + text,
            thinking: true,
            lastSeq: lastSeq,
          ),
        );
      } else if (text is String) {
        ctx.store.putTranscript(
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
        ctx.store.putTranscript(
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
      ctx.store.putTranscript(
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
      ctx.store.putTranscript(
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
      ctx.store.putTranscript(
        sessionId,
        ctx.store.withEntries(sessionId, transcript, message).copyWith(
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
        ctx.store.putTranscript(
          sessionId,
          transcript.copyWith(compacting: payload['active'] == true),
        );
        break;
      }
      // Any other `status` is relayed raw so the renderer can decide. An error
      // status ends the turn without a settle, so clear the thinking phase
      // here or `Thinking…` would stick forever.
      final isErrorStatus = payload['event'] == 'error';
      ctx.store.putTranscript(
        sessionId,
        ctx.store.withEntries(sessionId, transcript, payload).copyWith(
          thinking: isErrorStatus ? false : transcript.thinking,
          streamingThinking: isErrorStatus ? '' : transcript.streamingThinking,
        ),
      );
    case 'tool':
      // A bridge-normalized tool annotation: retained raw in `entries`, where
      // the transcript model pairs its view to the call/result row. Appended
      // in arrival order, like any other entry.
      ctx.store.putTranscript(
        sessionId,
        ctx.store.withEntries(sessionId, transcript, payload),
      );
    case 'leaf':
      // The bridge moved the leaf (or pi did, on the PC). A signal, not a row:
      // re-request history so the transcript re-baselines to the new branch,
      // and announce the move so the shell can settle a pending tree tap.
      ctx.emitLeaf(
        LeafEvent(
          sessionId: sessionId,
          leafId: payload['leafId'] as String?,
        ),
      );
      ctx.historyPages.requestHistory(sessionId);
    default:
      // An unknown payload is retained rather than dropped, so a future
      // renderer can consume it; nothing in this build does.
      ctx.store.putTranscript(
        sessionId,
        ctx.store.withEntries(sessionId, transcript, payload),
      );
  }
  ctx.notify.schedule();
}

void _onSnapshot(RouterContext ctx, Map<String, Object?> message) {
  final sessionId = message['sessionId']! as String;
  // Routing fields first: a discarded frame must not be decoded (round 2's
  // missed edge), so `entries` is only touched on an apply path.
  final token = message['cursor'] as String?;
  final older = message['older'] == true;
  final olderCursor = message['olderCursor'] as String?;

  if (older) {
    final existing = ctx.store.transcript(sessionId);
    // Apply only the page this session actually asked for. Anything else — an
    // absent token, a stale one, or no transcript — is discarded touching
    // nothing, so a stale page cannot reset the resync livelock streak (R5)
    // nor fabricate a baseline.
    if (!ctx.historyPages.matchesPending(sessionId, token) || existing == null) {
      return;
    }
    ctx.historyPages.dropPending(sessionId);
    ctx.store.removeResyncCount(sessionId);
    ctx.store.removeGoneCount(sessionId);
    final entries = (message['entries']! as List).cast<Object?>();
    // Prepend through the session's own derivation. `copyWith` carries the
    // in-flight stream and every ambient field across (design D + fact 13);
    // the lists are copied so a retained snapshot is a true value.
    final derivation = ctx.store.derivation(sessionId)!;
    derivation.rebuild([...entries, ...existing.entries]);
    ctx.store.putTranscript(
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
    ctx.notify.schedule();
    return;
  }

  // No `older` flag is the newest-page baseline: a REPLACE that also
  // invalidates any page in flight for this session.
  ctx.historyPages.dropPending(sessionId);
  // A delivered baseline breaks any resync or gone streak.
  ctx.store.removeResyncCount(sessionId);
  ctx.store.removeGoneCount(sessionId);
  final entries = (message['entries']! as List).cast<Object?>();
  final derivation = TranscriptDerivation()..rebuild(entries);
  ctx.store.setDerivation(sessionId, derivation);
  ctx.store.putTranscript(
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
      contextUsage: ctx.store.transcript(sessionId)?.contextUsage,
      thinkingLevel: ctx.store.transcript(sessionId)?.thinkingLevel,
      currentModel: ctx.store.transcript(sessionId)?.currentModel,
      compacting: ctx.store.transcript(sessionId)?.compacting ?? false,
    ),
  );
  ctx.notify.schedule();
}

/// A listing's rejection (an invalid path, a trust-store fault) arrives as a
/// `command-result` carrying the listing's id, so listings are consulted
/// first: the id spaces are disjoint by construction, but the routing order
/// is the guarantee. A listing failure never carries `ok:true`.
void _onCommandResult(RouterContext ctx, Map<String, Object?> message) {
  final id = message['id']! as String;
  final listing = ctx.pending.takeListing(id);
  if (listing != null) {
    if (listing.completer.isCompleted) return;
    listing.timer?.cancel();
    listing.completer.complete(
      DirListingResult(ok: false, error: message['error'] as String?),
    );
    return;
  }
  final pending = ctx.pending.peekCommand(id);
  if (pending == null || pending.completer.isCompleted) return;
  if (pending.followsReplacement) {
    // A successful ack is not the witness — the successor's registration is.
    // Leave the pending and the follow armed so adoption settles it.
    if (message['ok']! as bool) return;
    // A refused replacement will never produce a successor: fail the caller
    // and disarm the follow. Left armed with no pending to settle, it would
    // suppress every legitimate restore for 15 s, and a `session-gone` for
    // the id would skip the re-arm.
    ctx.pending.takeCommand(id);
    pending.timer?.cancel();
    if (!pending.completer.isCompleted) {
      pending.completer.complete(
        CommandResult(ok: false, error: message['error'] as String?),
      );
    }
    if (ctx.pending.awaitingReplacementFrom == pending.sessionId &&
        !ctx.pending.hasFollowForSession(pending.sessionId)) {
      ctx.pending.clearReplacementFollow();
    }
    return;
  }
  ctx.pending.takeCommand(id);
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

void _onDirListing(RouterContext ctx, Map<String, Object?> message) {
  final id = message['id']! as String;
  final pending = ctx.pending.takeListing(id);
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

void _onResyncRequired(RouterContext ctx, String sessionId) {
  final count = ctx.store.resyncCount(sessionId) + 1;
  ctx.store.setResyncCount(sessionId, count);
  if (count > ctx.resyncCap) {
    // Re-requesting forever is the livelock; stop and surface it instead.
    ctx.setError(
      'gave up resyncing $sessionId after ${ctx.resyncCap} attempts',
      connection: false,
    );
    return;
  }
  ctx.historyPages.requestHistory(sessionId);
}

void _onSessionGone(RouterContext ctx, String sessionId) {
  ctx.store.removeResyncCount(sessionId);
  final count = ctx.store.goneCount(sessionId) + 1;
  ctx.store.setGoneCount(sessionId, count);
  final gaveUp = count > ctx.goneCap;
  // The awaited session vanishing is the replacement's first witness: the
  // session is meant to be gone, so its pending is settled rather than
  // failed, and the follow stays armed until the successor names it (or the
  // follow times out). `ctx.store.resubscribed` is deliberately left alone —
  // the successor's push must not lose to a restore of the dead id.
  final awaiting = ctx.pending.awaitingReplacementFrom == sessionId;
  if (awaiting) ctx.pending.settleReplacement(sessionId);
  // A `session-gone` answering an automatic restore is the re-subscribe
  // racing the agent's re-registration; only once the cap is past — or when
  // the user subscribed directly and the session is simply gone — is the
  // transcript genuinely obsolete.
  final keepTranscript = !gaveUp && ctx.store.isRestored(sessionId);
  if (gaveUp) {
    // The session is genuinely gone. Re-arming again would resend
    // subscribe+history on every registry push forever, so clear the desired
    // session and say so rather than looping silently.
    ctx.store.removeRestored(sessionId);
    if (ctx.store.desiredSessionId == sessionId) ctx.store.desiredSessionId = null;
  } else if (!awaiting && ctx.store.desiredSessionId == sessionId) {
    // A gone session may come back (an agent restart, or a re-subscribe that
    // raced the agent's re-registration): drop the one-shot guard so the next
    // `sessions` push re-attaches to the session the user was viewing.
    ctx.store.resubscribed = false;
  }
  ctx.pending.failPending('session gone', sessionId: sessionId);
  final sessions = ctx.store.state.sessions
      .where((summary) => summary.sessionId != sessionId)
      .toList();
  final transcripts = {...ctx.store.state.transcripts};
  if (!keepTranscript) {
    transcripts.remove(sessionId);
    ctx.store.removeDerivation(sessionId);
    ctx.historyPages.dropPending(sessionId);
  }
  // Only the genuinely-gone branch drops the cache: under the cap the session
  // may come back (the re-subscribe race), and a kept key avoids a flicker.
  final commands = gaveUp
      ? ({...ctx.store.state.commands}..remove(sessionId))
      : ctx.store.state.commands;
  ctx.store.update(
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
    ctx.setError(
      'the session $sessionId is gone; pick another session to view',
      connection: false,
    );
  } else {
    ctx.notify.schedule();
  }
}
