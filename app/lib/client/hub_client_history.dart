part of 'hub_client.dart';

/// Bounded wait for an older page. A live socket is not a live agent: the
/// bridge returns silently when it has no `ctx`, so without this an unanswered
/// page would leave the control loading (and single-flight blocking a retry)
/// until some unrelated baseline landed.
const Duration _historyPageTimeout = Duration(seconds: 30);

/// History paging: the newest-page request, the single-flight older-page
/// request, and the bounded wait that re-enables the control when the hub never
/// answers.
///
/// View it uses on [HubClient]: reads `_c._store`, `_socket`; writes
/// `_c._store`, `_pendingHistoryCursor`, `_historyPageTimers`; calls
/// `_scheduleNotify`, `_trySend`; uses `_scheduler`.
class _HubHistory {
  _HubHistory(this._c);

  final HubClient _c;

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
    return _c._trySend(message);
  }

  /// Requests one older page for [sessionId] and prepends it when it arrives.
  ///
  /// Does nothing when the transcript is absent, is already at the session's
  /// beginning ([SessionTranscript.olderCursor] is null), or a page is already
  /// in flight (single-flight).
  ///
  /// The null-socket check runs BEFORE `historyLoading` is set: `_send`
  /// silently drops on a null socket and `_trySend` reports that as success, so
  /// setting loading there would disable the control with nothing in flight.
  /// A non-null socket can still be a dead agent, so a successful send is
  /// bounded by a page timeout that re-enables the control instead of hanging
  /// it forever.
  void loadOlder(String sessionId) {
    final transcript = _c._store.transcript(sessionId);
    if (transcript == null) return;
    final cursor = transcript.olderCursor;
    if (cursor == null) return;
    if (_c._pendingHistoryCursor.containsKey(sessionId)) return;
    if (_c._socket == null) return;

    _c._pendingHistoryCursor[sessionId] = cursor;
    _c._store.putTranscript(sessionId, transcript.copyWith(historyLoading: true));
    _c._scheduleNotify();
    final error = requestHistory(sessionId, cursor: cursor);
    if (error != null) {
      _c._pendingHistoryCursor.remove(sessionId);
      _c._store.putTranscript(sessionId, transcript.copyWith(historyLoading: false));
      _c._scheduleNotify();
      return;
    }
    _cancelHistoryPageTimeout(sessionId);
    _c._historyPageTimers[sessionId] = _c._scheduler.schedule(
      _historyPageTimeout,
      () {
        _c._historyPageTimers.remove(sessionId);
        if (_c._pendingHistoryCursor.remove(sessionId) == null) return;
        final current = _c._store.transcript(sessionId);
        if (current == null) return;
        _c._store.putTranscript(sessionId, current.copyWith(historyLoading: false));
        _c._scheduleNotify();
      },
      kind: HubTimerKind.historyPage,
    );
  }

  void _cancelHistoryPageTimeout(String sessionId) {
    _c._historyPageTimers.remove(sessionId)?.cancel();
  }

  void _cancelHistoryPageTimeouts() {
    for (final timer in _c._historyPageTimers.values) {
      timer.cancel();
    }
    _c._historyPageTimers.clear();
  }

  /// Drops every in-flight older-page request: the single-flight cursor, the
  /// bounded wait, and the `historyLoading` flag (or the control stays disabled
  /// with no page in flight). A page's reply can only arrive on the socket that
  /// asked, so a replaced connection must never leave one of these behind.
  void _clearPendingHistoryPages() {
    for (final sessionId in _c._pendingHistoryCursor.keys) {
      final transcript = _c._store.transcript(sessionId);
      if (transcript != null && transcript.historyLoading) {
        _c._store.putTranscript(sessionId, transcript.copyWith(historyLoading: false));
      }
    }
    _c._pendingHistoryCursor.clear();
    _cancelHistoryPageTimeouts();
  }
}
