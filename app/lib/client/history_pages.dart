// ignore_for_file: prefer_initializing_formals
// The dependency fields are private, and a private *named* parameter is illegal
// in Dart, so the initializer list is the only way to bind them (the lint's
// suggested fix does not compile).

/// History paging: the newest-page request, the single-flight older-page
/// request, and the bounded wait that re-enables the control when the hub never
/// answers.
///
/// Extracted from the hub client into a separate library: it owns the
/// per-session pending cursor and the page-timeout timers, and reaches the
/// client only through its dependencies ([store], [notify], [isConnected],
/// [trySend]), never a `HubClient`.
library;

import '../protocol/protocol.dart';
import 'notify_coalescer.dart';
import 'scheduler.dart';
import 'session_state.dart';

/// Bounded wait for an older page. A live socket is not a live agent: the
/// bridge returns silently when it has no `ctx`, so without this an unanswered
/// page would leave the control loading (and single-flight blocking a retry)
/// until some unrelated baseline landed.
const Duration _historyPageTimeout = Duration(seconds: 30);

/// The newest-page request, the single-flight older-page request, and the
/// bounded wait that re-enables the control when the hub never answers.
class HistoryPages {
  HistoryPages({
    required HubScheduler scheduler,
    required SessionStateStore store,
    required NotifyCoalescer notify,
    required bool Function() isConnected,
    required Object? Function(Map<String, Object?>) trySend,
  }) : _scheduler = scheduler,
       _store = store,
       _notify = notify,
       _isConnected = isConnected,
       _trySend = trySend;

  final HubScheduler _scheduler;
  final SessionStateStore _store;
  final NotifyCoalescer _notify;
  final bool Function() _isConnected;
  final Object? Function(Map<String, Object?>) _trySend;

  /// The cursor of the one in-flight older page per session, keyed by session.
  /// Set by [loadOlder] and cleared by an applied snapshot, the page timeout,
  /// a send failure, `session-gone`, `stop` and `disconnect`.
  final Map<String, String> _pendingHistoryCursor = {};

  /// The page-timeout handle per session, in lockstep with
  /// [_pendingHistoryCursor].
  final Map<String, HubTimer> _historyPageTimers = {};

  /// Sends a `history-request`. The hub answers with a `snapshot`.
  ///
  /// Returns the send error (`null` when the frame went out), so [loadOlder]
  /// can clear its in-flight state when the write failed. [cursor] is the older
  /// page's opaque token and is placed on the frame only when non-null.
  Object? requestHistory(String sessionId, {int? sinceSeq, String? cursor}) {
    final message = <String, Object?>{
      'protocolVersion': protocolVersion,
      'type': 'history-request',
      'sessionId': sessionId,
    };
    // `sinceSeq` must be a positive safe integer; 0 or a negative is a
    // guaranteed hub `4002` self-kick, so clamp to the valid floor.
    if (sinceSeq != null) message['sinceSeq'] = sinceSeq < 1 ? 1 : sinceSeq;
    if (cursor != null) message['cursor'] = cursor;
    return _trySend(message);
  }

  /// Requests one older page for [sessionId] and prepends it when it arrives.
  ///
  /// Does nothing when the transcript is absent, is already at the session's
  /// beginning (its `olderCursor` is null), or a page is already in flight
  /// (single-flight).
  ///
  /// The null-socket check runs BEFORE `historyLoading` is set: [trySend]
  /// silently drops on a null socket and reports that as success, so setting
  /// loading there would disable the control with nothing in flight. A non-null
  /// socket can still be a dead agent, so a successful send is bounded by a page
  /// timeout that re-enables the control instead of hanging it forever.
  void loadOlder(String sessionId) {
    final transcript = _store.transcript(sessionId);
    if (transcript == null) return;
    final cursor = transcript.olderCursor;
    if (cursor == null) return;
    if (_pendingHistoryCursor.containsKey(sessionId)) return;
    if (!_isConnected()) return;

    _pendingHistoryCursor[sessionId] = cursor;
    _store.putTranscript(sessionId, transcript.copyWith(historyLoading: true));
    _notify.schedule();
    final error = requestHistory(sessionId, cursor: cursor);
    if (error != null) {
      _pendingHistoryCursor.remove(sessionId);
      _store.putTranscript(sessionId, transcript.copyWith(historyLoading: false));
      _notify.schedule();
      return;
    }
    _cancelHistoryPageTimeout(sessionId);
    _historyPageTimers[sessionId] = _scheduler.schedule(
      _historyPageTimeout,
      () {
        _historyPageTimers.remove(sessionId);
        if (_pendingHistoryCursor.remove(sessionId) == null) return;
        final current = _store.transcript(sessionId);
        if (current == null) return;
        _store.putTranscript(sessionId, current.copyWith(historyLoading: false));
        _notify.schedule();
      },
      kind: HubTimerKind.historyPage,
    );
  }

  /// Whether [cursor] is the opaque token of the in-flight older page for
  /// [sessionId]. A null [cursor] never matches.
  bool matchesPending(String sessionId, String? cursor) =>
      cursor != null && _pendingHistoryCursor[sessionId] == cursor;

  /// Drops the in-flight older-page request for [sessionId]: the single-flight
  /// cursor and the bounded wait.
  void dropPending(String sessionId) {
    _pendingHistoryCursor.remove(sessionId);
    _cancelHistoryPageTimeout(sessionId);
  }

  void _cancelHistoryPageTimeout(String sessionId) {
    _historyPageTimers.remove(sessionId)?.cancel();
  }

  void _cancelHistoryPageTimeouts() {
    for (final timer in _historyPageTimers.values) {
      timer.cancel();
    }
    _historyPageTimers.clear();
  }

  /// Drops every in-flight older-page request: the single-flight cursor, the
  /// bounded wait, and the `historyLoading` flag (or the control stays disabled
  /// with no page in flight). A page's reply can only arrive on the socket that
  /// asked, so a replaced connection must never leave one of these behind.
  void clearAllPending() {
    for (final sessionId in _pendingHistoryCursor.keys) {
      final transcript = _store.transcript(sessionId);
      if (transcript != null && transcript.historyLoading) {
        _store.putTranscript(sessionId, transcript.copyWith(historyLoading: false));
      }
    }
    _pendingHistoryCursor.clear();
    _cancelHistoryPageTimeouts();
  }
}
