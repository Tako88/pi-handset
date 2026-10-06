part of 'hub_client.dart';

const int _backoffBaseMs = 500;
const int _backoffCapMs = 30000;

/// Bounded wait for `paired` or `sessions` after dialing. A wrong or stale
/// token gets silence on an open socket — the hub charges one attempt per
/// `hello` and this client sends exactly one — so without this the client would
/// stay `authenticating` forever with no error.
const Duration _authTimeout = Duration(seconds: 10);

/// Bounded wait for the socket factory to produce a socket. Without it an
/// unroutable host hangs until Android's own TCP timeout (minutes, not
/// seconds).
const Duration _connectTimeout = Duration(seconds: 10);

/// Bounded wait for one candidate in a parallel race, and the bound on how long
/// a held non-preferred socket waits for the preferred candidate to answer.
/// Shorter than [_connectTimeout]: a race has other sockets to fall back on, so
/// a single slow candidate must not stall the attempt for ten seconds.
const Duration _candidateConnectTimeout = Duration(seconds: 2);

/// Connection: dial (single and raced), adopt, authenticate, and the timers
/// that bound and recover an attempt.
///
/// View it uses on [HubClient]: reads _state, _derivations, _socket,
/// _subscription, _candidates, _prefer, _credential, _scheduler, _tokenStore,
/// _socketFactory, _rng, _dialSeq, _stopped, _connectTimers, _reconnectTimer,
/// _authTimer, _heldCandidate, _heldSeq, _raceDecision, _changesController,
/// _settlesController, _leafEventsController; writes _state, _socket,
/// _attempt, _resubscribed, _credential, _candidates, _prefer, _desiredSessionId,
/// _resyncCounts, _sessionGoneCounts, _restoredSessions, _derivations,
/// _lastErrorFromConnection; calls _setStatus, _setError, _clearConnectionError,
/// _flushNotify, _subscribe, _requests.*, _history.*, _router.*.
class _HubConnection {
  _HubConnection(this._c);

  final HubClient _c;
  Future<void> startCandidates(
    List<HubEndpoint> candidates, {
    String? ticket,
    HubEndpoint? prefer,
  }) async {
    if (candidates.isEmpty) {
      throw StateError('at least one candidate address is required to connect');
    }
    _cancelReconnect();
    _cancelAuthWatchdog();
    _cancelConnectDeadline();
    _c._dialSeq++;
    _releaseSupersededHold();
    // A follow armed on a previous hub names a foreign session id; left set, it
    // would suppress every restore on the new hub until its timer fired.
    _c._requests._clearReplacementFollow();
    // The follow was just cleared, so a `followsReplacement` pending can never be
    // settled by the abandoned hub: deliberately no `skipReplacement: true`
    // (unlike `_onSocketDone`, whose successor still arrives after a reconnect).
    _c._requests._failPending('connection replaced');
    _c._history._clearPendingHistoryPages();
    await _dropConnection();

    _c._candidates = List<HubEndpoint>.of(candidates);
    _c._prefer = prefer != null && _c._candidates.contains(prefer) ? prefer : null;
    if (ticket != null) {
      _c._credential = {'ticket': ticket};
    } else {
      final stored = await _c._tokenStore.read();
      if (stored == null || stored.isEmpty) {
        throw StateError('a ticket or a stored token is required to connect');
      }
      _c._credential = {'token': stored};
    }
    _c._clearConnectionError();
    _c._stopped = false;
    _c._attempt = 0;
    await _dial();
  }

  Future<void> stop() async {
    _c._stopped = true;
    _cancelReconnect();
    _cancelAuthWatchdog();
    _cancelConnectDeadline();
    _c._dialSeq++;
    _releaseSupersededHold();
    _c._candidates = <HubEndpoint>[];
    _c._prefer = null;
    _c._requests._clearReplacementFollow();
    // `stop()` closes `changes` for good and never resets `_c._state`, so nothing
    // else would ever drop the derivations; they die here.
    _c._derivations.clear();
    _c._history._clearPendingHistoryPages();
    // Every in-flight command fails rather than hanging the caller forever.
    _c._requests._failPending('client stopped');
    await _dropConnection(reason: 'client stopped');
    _c._setStatus(HubConnectionStatus.disconnected);
    // Emit the terminal state now: cancelling the pending notify would close
    // `changes` without anyone ever observing `disconnected`.
    _c._flushNotify();
    if (!_c._changesController.isClosed) await _c._changesController.close();
    if (!_c._settlesController.isClosed) await _c._settlesController.close();
    if (!_c._leafEventsController.isClosed) await _c._leafEventsController.close();
  }

  Future<void> disconnect() async {
    _c._stopped = true;
    _cancelReconnect();
    _cancelAuthWatchdog();
    _cancelConnectDeadline();
    _c._dialSeq++;
    _releaseSupersededHold();
    _c._candidates = <HubEndpoint>[];
    _c._prefer = null;
    _c._requests._failPending('disconnected');
    // Not awaited: closing the socket below ends delivery, and awaiting a
    // subscription cancel leaves a UI-initiated disconnect pending under a
    // widget-test clock.
    await _dropConnection(awaitSubscription: false, reason: 'disconnected');
    _c._credential = null;
    _c._requests._clearReplacementFollow();
    _c._resubscribed = false;
    _c._desiredSessionId = null;
    _c._attempt = 0;
    _c._resyncCounts.clear();
    _c._sessionGoneCounts.clear();
    _c._restoredSessions.clear();
    _c._derivations.clear();
    _c._history._clearPendingHistoryPages();
    _c._lastErrorFromConnection = false;
    _c._state = const HubClientState();
    _c._flushNotify();
  }

  /// Closes the current socket and cancels its subscription. Socket teardown
  /// **only** — deliberately no credential, state, pending or `_c._stopped`
  /// resets, so [start] can reuse it to displace an in-flight attempt without
  /// wiping the credential it is about to send or stopping the dial it is about
  /// to make.
  Future<void> _dropConnection({
    bool awaitSubscription = true,
    String reason = 'disconnected',
  }) async {
    final socket = _c._socket;
    _c._socket = null;
    final subscription = _c._subscription;
    _c._subscription = null;
    if (awaitSubscription) {
      await subscription?.cancel();
    } else {
      unawaited(subscription?.cancel() ?? Future<void>.value());
    }
    if (socket != null) {
      try {
        await socket.close(1000, reason);
      } catch (_) {
        // Already gone; nothing to do.
      }
    }
  }

  /// Restores the subscription the previous connection held, once this
  /// connection is authenticated.
  ///
  /// The hub drops a closed connection from a session's subscriber set, so
  /// after a redial the client would otherwise keep its `activeSessionId` and
  /// transcript while the hub delivers nothing — a transcript that silently
  /// stops updating. Re-subscribing alone is not enough: the drop may have
  /// gapped the transcript, so history is re-requested too.
  ///
  /// Runs once per dial, and again only after a `session-gone` clears the guard
  /// (past the give-up cap it never runs again). It leaves the gone streak
  /// intact, so an automatic retry cannot reset its own cap.
  void _restoreSubscription() {
    if (_c._resubscribed) return;
    _c._resubscribed = true;
    final sessionId = _c._desiredSessionId ?? _c._state.activeSessionId;
    if (sessionId == null) return;
    // `_c._subscribe` re-subscribes and re-requests history. Requesting it again
    // here would send a duplicate frame.
    _c._subscribe(sessionId, restoring: true);
  }

  Future<void> _dial() async {
    if (_c._stopped || _c._candidates.isEmpty) return;
    final seq = ++_c._dialSeq;
    _c._setStatus(HubConnectionStatus.connecting);
    if (_c._candidates.length > 1) {
      await _dialRace(seq);
      return;
    }
    HubSocket socket;
    try {
      socket = await _dialSocket(_wsUri(_c._candidates.first));
    } catch (error) {
      // A superseded dial reports nothing: its failure is not this attempt's.
      if (_c._stopped || seq != _c._dialSeq) return;
      _c._setError('$error', connection: true);
      _scheduleReconnect();
      return;
    }
    if (_c._stopped || seq != _c._dialSeq) {
      // Superseded while the factory was pending: close the late socket rather
      // than adopting it. Swallow the close's own error — an unhandled
      // rejection inside a scheduler task is a zone error.
      await socket.close().catchError((Object _) {});
      return;
    }
    _adoptSocket(socket);
  }

  /// Dials every candidate in parallel and resolves once a socket is adopted or
  /// every dial has failed — never on a straggler.
  ///
  /// [seq] is the attempt's generation, captured by [_dial]. It is re-checked
  /// before every adoption, so a race the user superseded closes every socket
  /// it owns and adopts nothing. With [_c._prefer] set, the first non-preferred
  /// success is held (no `hello`, so the single-use ticket is untouched) while
  /// the preferred candidate settles; the preferred's own 2 s deadline bounds
  /// that hold, and on its failure the held socket is adopted.
  ///
  /// A superseding [startCandidates], [stop] or [disconnect] closes the held
  /// socket and settles this race through [_releaseSupersededHold], so even a
  /// preferred dial whose factory never resolves cannot leak the hold or hang
  /// the caller.
  Future<void> _dialRace(int seq) async {
    final candidates = List<HubEndpoint>.of(_c._candidates);
    final prefer = _c._prefer;
    final decision = Completer<void>();
    var remaining = candidates.length;
    var preferFailed = false;
    HubSocket? held;

    bool superseded() => _c._stopped || seq != _c._dialSeq;

    Future<void> closeSocket(HubSocket? socket) async {
      if (socket == null) return;
      try {
        await socket.close();
      } catch (_) {
        // Already gone; nothing to do.
      }
    }

    // The held socket is mirrored in `_c._heldCandidate` so a lifecycle method
    // that supersedes this race can close it: a stalled preferred dial never
    // calls `evaluate`, so the local would otherwise be unreachable.
    void hold(HubSocket socket) {
      held = socket;
      _c._heldCandidate = socket;
      _c._heldSeq = seq;
    }

    void dropHeld() {
      held = null;
      _c._heldCandidate = null;
      _c._heldSeq = 0;
    }

    void finish() {
      if (identical(_c._raceDecision, decision)) _c._raceDecision = null;
      if (!decision.isCompleted) decision.complete();
    }

    void fail() {
      final addresses = candidates
          .map((candidate) => '${candidate.host}:${candidate.port}')
          .join(', ');
      _c._setError(
        'could not reach $addresses within '
        '${_candidateConnectTimeout.inSeconds} seconds',
        connection: true,
      );
      _scheduleReconnect();
      finish();
    }

    void adopt(HubSocket socket) {
      _adoptSocket(socket);
      finish();
    }

    void evaluate() {
      if (decision.isCompleted) return;
      if (superseded()) {
        final stale = held;
        dropHeld();
        unawaited(closeSocket(stale));
        finish();
        return;
      }
      if (prefer == null) {
        if (remaining == 0) fail();
        return;
      }
      if (held != null && preferFailed) {
        final socket = held!;
        dropHeld();
        adopt(socket);
        return;
      }
      if (remaining == 0) {
        final socket = held;
        dropHeld();
        if (socket != null) {
          adopt(socket);
        } else {
          fail();
        }
      }
    }

    for (final candidate in candidates) {
      final isPreferred = prefer != null && candidate == prefer;
      unawaited(
        _dialSocket(
          _wsUri(candidate),
          timeout: _candidateConnectTimeout,
        ).then<void>((socket) {
          remaining--;
          if (decision.isCompleted) {
            unawaited(closeSocket(socket));
            return;
          }
          if (superseded()) {
            unawaited(closeSocket(socket));
            evaluate();
            return;
          }
          if (isPreferred) {
            final stale = held;
            dropHeld();
            unawaited(closeSocket(stale));
            adopt(socket);
            return;
          }
          if (prefer == null) {
            // First answer wins.
            adopt(socket);
            return;
          }
          // A non-preferred success: hold the first, close any extras.
          if (held == null) {
            hold(socket);
          } else {
            unawaited(closeSocket(socket));
          }
          evaluate();
        }, onError: (Object error, StackTrace stackTrace) {
          remaining--;
          if (isPreferred) preferFailed = true;
          evaluate();
        }),
      );
    }

    _c._raceDecision = decision;
    await decision.future;
  }

  /// Adopts [socket]: makes it the live connection and sends the `hello`. The
  /// extracted tail of the old single-candidate `_dial`, unchanged so the
  /// single path stays behaviourally identical.
  void _adoptSocket(HubSocket socket) {
    _c._socket = socket;
    _c._attempt = 0;
    _c._resubscribed = false;
    _c._setStatus(HubConnectionStatus.authenticating);
    _c._requests._send(_c._requests._hello());
    _armAuthWatchdog();
    _c._subscription = socket.messages.listen(
      _c._router._onFrame,
      onError: (Object _) {},
      onDone: () => _onSocketDone(socket),
    );
  }

  Uri _wsUri(HubEndpoint endpoint) =>
      Uri(scheme: 'ws', host: endpoint.host, port: endpoint.port);

  /// Dials through [_c._socketFactory] but bounds the wait with [timeout] (the
  /// 10 s default, or the shorter candidate bound inside a race).
  ///
  /// The deadline is scheduled through the injected scheduler so a test can
  /// drive it. If it expires first, the returned future fails and a socket that
  /// arrives afterwards is closed and dropped — never adopted, and never sent a
  /// `hello`.
  ///
  /// Its timer is added to [_c._connectTimers] and removes its own entry when it
  /// fires, is cancelled, or its socket arrives — never a blanket cancel, so a
  /// race can never kill a successor attempt's deadlines.
  ///
  /// A generation bump (a stop, or a new [start]) cancels the timer but does
  /// not settle the completer, so a `_dial` still awaiting a stalled factory
  /// stays pending until the factory itself resolves. That is deliberate: the
  /// caller is superseded and its result is discarded by the generation guard
  /// in `_dial`, and the factory is bounded in production by the OS connect
  /// timeout. Failing it here would be extra machinery for no observable gain.
  Future<HubSocket> _dialSocket(Uri url, {Duration? timeout}) {
    final effective = timeout ?? _connectTimeout;
    final completer = Completer<HubSocket>();
    // Captured now, not read from a field at expiry: the candidate list is
    // replaced by every `start()`, so a superseded dial would otherwise name
    // the wrong host.
    final endpoint = '${url.host}:${url.port}';
    late final HubTimer timer;
    timer = _c._scheduler.schedule(effective, () {
      _c._connectTimers.remove(timer);
      if (completer.isCompleted) return;
      completer.completeError(
        TimeoutException(
          'could not reach $endpoint within ${effective.inSeconds} seconds',
        ),
      );
    }, kind: HubTimerKind.connect);
    _c._connectTimers.add(timer);
    unawaited(() async {
      try {
        final socket = await _c._socketFactory(url);
        timer.cancel();
        _c._connectTimers.remove(timer);
        if (completer.isCompleted) {
          // The deadline already failed this dial; the socket is too late.
          unawaited(socket.close().catchError((Object _) {}));
          return;
        }
        completer.complete(socket);
      } catch (error, stackTrace) {
        timer.cancel();
        _c._connectTimers.remove(timer);
        if (completer.isCompleted) return;
        completer.completeError(error, stackTrace);
      }
    }());
    return completer.future;
  }

  Future<void> _onSocketDone(HubSocket socket) async {
    final close = await socket.closed;
    if (_c._socket != socket) return;
    _c._socket = null;
    final wasAuthenticating =
        _c._state.status == HubConnectionStatus.authenticating;
    _cancelAuthWatchdog();
    // Not awaited: the socket is already done, and awaiting a subscription
    // cancel leaves the close path (and the error it records) pending.
    final subscription = _c._subscription;
    _c._subscription = null;
    unawaited(subscription?.cancel() ?? Future<void>.value());
    if (_c._stopped) return;
    // A lost socket can never deliver a result; fail rather than hang. A
    // `followsReplacement` pending is exempt: the replacement proceeds on the
    // server regardless of this viewer's reconnect, so failing it here would
    // report an error while the successor still arrives minutes later. It is
    // bounded by the 15 s replacement timer instead.
    _c._requests._failPending('connection lost', skipReplacement: true);
    if (close.code == closeCapability) {
      _c._setStatus(HubConnectionStatus.disconnected);
      return;
    }
    if (close.code == closeRateLimited) {
      // The hub delayed this close on purpose; say so, or the longer wait looks
      // like a generic reconnect loop.
      _c._setError(
        'the hub is rate-limiting authentication; retrying in '
        '${rateLimitedReconnectDelay.inSeconds} seconds',
        connection: true,
      );
      _c._setStatus(HubConnectionStatus.connecting);
      _scheduleReconnect(fixed: rateLimitedReconnectDelay);
      return;
    }
    if (wasAuthenticating && _c._state.lastError == null) {
      // A rejected ticket closes without a `paired` and cancels the watchdog, so
      // unless an error is recorded here the pairing form spins forever.
      _c._setError(
        'the hub closed the connection before authenticating; the pairing '
        'code may be invalid — enter a new one',
        connection: true,
      );
    }
    _c._setStatus(HubConnectionStatus.connecting);
    _scheduleReconnect();
  }

  void _armAuthWatchdog() {
    _cancelAuthWatchdog();
    _c._authTimer = _c._scheduler.schedule(_authTimeout, () {
      _c._authTimer = null;
      _onAuthTimeout();
    }, kind: HubTimerKind.auth);
  }

  void _cancelAuthWatchdog() {
    _c._authTimer?.cancel();
    _c._authTimer = null;
  }

  void _cancelConnectDeadline() {
    for (final timer in _c._connectTimers) {
      timer.cancel();
    }
    _c._connectTimers.clear();
  }

  /// Releases whatever a superseded race is holding. A stalled preferred dial
  /// never runs the race's own `evaluate`, so [startCandidates], [stop] and
  /// [disconnect] must close the held socket and settle the race here —
  /// otherwise the socket leaks and the race's awaiting caller hangs forever.
  ///
  /// A no-op when no race is in flight. The generation check is defensive: the
  /// callers bump [_c._dialSeq] first, so a held candidate always belongs to a
  /// superseded generation.
  void _releaseSupersededHold() {
    final socket = _c._heldCandidate;
    if (socket != null && _c._heldSeq != _c._dialSeq) {
      _c._heldCandidate = null;
      _c._heldSeq = 0;
      unawaited(socket.close().catchError((Object _) {}));
    }
    final decision = _c._raceDecision;
    _c._raceDecision = null;
    if (decision != null && !decision.isCompleted) decision.complete();
  }

  void _onAuthTimeout() {
    final socket = _c._socket;
    if (socket == null) return;
    _c._setError(
      'timed out waiting for the hub to authenticate; the pairing token '
      'may be stale',
      connection: true,
    );
    // Closing lets the normal socket-done path schedule a backoff redial.
    unawaited(socket.close().catchError((Object _) {}));
  }

  void _scheduleReconnect({Duration? fixed}) {
    if (_c._stopped || _c._reconnectTimer != null) return;
    final Duration delay;
    if (fixed != null) {
      delay = fixed;
    } else {
      delay = _computeBackoff(_c._attempt);
      _c._attempt++;
    }
    _c._reconnectTimer = _c._scheduler.schedule(delay, () {
      _c._reconnectTimer = null;
      unawaited(_dial());
    }, kind: HubTimerKind.reconnect);
  }

  void _cancelReconnect() {
    _c._reconnectTimer?.cancel();
    _c._reconnectTimer = null;
  }

  /// Exponential backoff with full jitter, capped. `attempt` is 0-based.
  Duration _computeBackoff(int attempt) {
    final exponent = attempt < 0 ? 0 : attempt;
    final ceilingMs = min(
      _backoffCapMs,
      (_backoffBaseMs * pow(2, exponent)).toInt(),
    );
    final delayMs = (_c._rng() * ceilingMs).floor();
    return Duration(milliseconds: delayMs);
  }

}
