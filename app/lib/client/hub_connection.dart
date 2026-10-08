// ignore_for_file: prefer_initializing_formals
// The dependency fields are private, and a private *named* parameter is illegal
// in Dart, so the initializer list is the only way to bind them (the lint's
// suggested fix does not compile).

/// Connection: dial (single and raced), adopt, authenticate, and the timers
/// that bound and recover an attempt.
///
/// Extracted from the hub client into a separate library: it owns the live
/// socket, its message subscription, the credential, the candidate list, the
/// dial-race hold, the attempt/generation counters and the reconnect, connect
/// and auth timers. It reaches the client only through the callbacks and
/// collaborators handed to its constructor, never a `HubClient`.
library;

import 'dart:async';

import '../protocol/protocol.dart';
import 'backoff.dart';
import 'close_codes.dart';
import 'endpoint_store.dart';
import 'history_pages.dart';
import 'hub_models.dart';
import 'hub_socket.dart';
import 'pending_registry.dart';
import 'scheduler.dart';
import 'session_state.dart';
import 'token_store.dart';

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

/// Owns the socket/credential/dial-race/timer cluster of the hub client.
class HubConnection {
  HubConnection({
    required HubSocketFactory socketFactory,
    required HubScheduler scheduler,
    required TokenStore tokenStore,
    required double Function() rng,
    required SessionStateStore store,
    required PendingRegistry pending,
    required HistoryPages historyPages,
    required void Function(Object?) onFrame,
    required void Function(HubConnectionStatus) setStatus,
    required void Function(String, {required bool connection}) setError,
    required void Function() clearConnectionError,
    required void Function() flushNotify,
    required Future<void> Function() closeControllers,
    required void Function(String sessionId, {bool restoring}) subscribe,
  }) : _socketFactory = socketFactory,
       _scheduler = scheduler,
       _tokenStore = tokenStore,
       _rng = rng,
       _store = store,
       _pending = pending,
       _historyPages = historyPages,
       _onFrame = onFrame,
       _setStatus = setStatus,
       _setError = setError,
       _clearConnectionError = clearConnectionError,
       _flushNotify = flushNotify,
       _closeControllers = closeControllers,
       _subscribe = subscribe;

  final HubSocketFactory _socketFactory;
  final HubScheduler _scheduler;
  final TokenStore _tokenStore;
  final double Function() _rng;
  final SessionStateStore _store;
  final PendingRegistry _pending;
  final HistoryPages _historyPages;
  final void Function(Object?) _onFrame;
  final void Function(HubConnectionStatus) _setStatus;
  final void Function(String, {required bool connection}) _setError;
  final void Function() _clearConnectionError;
  final void Function() _flushNotify;
  final Future<void> Function() _closeControllers;
  final void Function(String sessionId, {bool restoring}) _subscribe;

  Map<String, Object?>? _credential;
  HubSocket? _socket;
  StreamSubscription<Object?>? _subscription;
  HubTimer? _reconnectTimer;
  HubTimer? _authTimer;

  /// One dial deadline per in-flight dial. A dial removes its own entry when it
  /// fires, is cancelled, or its socket arrives; the only blanket cancel is
  /// [_cancelConnectDeadline], run solely at attempt start, stop and
  /// disconnect, before a successor's timers exist.
  final List<HubTimer> _connectTimers = <HubTimer>[];

  /// The candidate addresses of the current attempt, in preference order. Set
  /// by [startCandidates], retained across reconnects so [_scheduleReconnect]
  /// re-races the whole list, and cleared by [stop] and [disconnect].
  List<HubEndpoint> _candidates = <HubEndpoint>[];

  /// The candidate a race prefers, or null for first-answer. Only honoured
  /// when it is in [_candidates]; otherwise it is treated as absent.
  HubEndpoint? _prefer;

  /// The non-preferred socket the in-flight race is holding while the preferred
  /// candidate settles, and the generation that holds it. Kept in a field so a
  /// superseding [startCandidates], [stop] or [disconnect] can close it: a
  /// stalled preferred dial never runs the race's own `evaluate`, so otherwise
  /// the hold would leak forever.
  HubSocket? _heldCandidate;
  int _heldSeq = 0;

  /// Settles the in-flight race when its generation is superseded, so a caller
  /// awaiting a race whose preferred dial is stalled does not hang. Null when no
  /// race is in flight.
  Completer<void>? _raceDecision;

  int _attempt = 0;
  bool _stopped = true;

  /// Bumped per dial attempt, and again on every path that invalidates an
  /// in-flight dial ([start], [stop], [disconnect]). A dial that resumes after
  /// its generation moved must close its socket, never adopt it.
  int _dialSeq = 0;

  /// Whether a live socket is adopted.
  bool get isConnected => _socket != null;

  /// The credential the next `hello` authenticates with, or null before a
  /// start and after a [disconnect]. The accessor pair is deliberate — the
  /// private field stays the connection's own — so the wrapper is not
  /// redundant here.
  // ignore: unnecessary_getters_setters
  Map<String, Object?>? get credential => _credential;
  set credential(Map<String, Object?>? value) => _credential = value;

  /// Sends [message] over the live socket, silently dropping when there is
  /// none.
  void send(Map<String, Object?> message) {
    final socket = _socket;
    if (socket == null) return;
    socket.send(encode(message));
  }

  /// Sends [message], converting the synchronous throw of a closing socket into
  /// a recorded error rather than letting it escape into the UI. Returns the
  /// thrown error, or null when the frame went out.
  Object? trySend(Map<String, Object?> message) {
    try {
      send(message);
      return null;
    } catch (error) {
      _setError('$error', connection: true);
      return error;
    }
  }

  Map<String, Object?> _hello() => <String, Object?>{
    'protocolVersion': protocolVersion,
    'type': 'hello',
    ...?_credential,
  };

  Future<void> startCandidates(
    List<HubEndpoint> candidates, {
    String? ticket,
    HubEndpoint? prefer,
  }) async {
    if (candidates.isEmpty) {
      throw StateError('at least one candidate address is required to connect');
    }
    _cancelReconnect();
    cancelAuthWatchdog();
    _cancelConnectDeadline();
    _dialSeq++;
    _releaseSupersededHold();
    // A follow armed on a previous hub names a foreign session id; left set, it
    // would suppress every restore on the new hub until its timer fired.
    _pending.clearReplacementFollow();
    // The follow was just cleared, so a `followsReplacement` pending can never be
    // settled by the abandoned hub: deliberately no `skipReplacement: true`
    // (unlike `_onSocketDone`, whose successor still arrives after a reconnect).
    _pending.failPending('connection replaced');
    _historyPages.clearAllPending();
    await _dropConnection();

    _candidates = List<HubEndpoint>.of(candidates);
    _prefer = prefer != null && _candidates.contains(prefer) ? prefer : null;
    if (ticket != null) {
      _credential = {'ticket': ticket};
    } else {
      final stored = await _tokenStore.read();
      if (stored == null || stored.isEmpty) {
        throw StateError('a ticket or a stored token is required to connect');
      }
      _credential = {'token': stored};
    }
    _clearConnectionError();
    _stopped = false;
    _attempt = 0;
    await _dial();
  }

  Future<void> stop() async {
    _stopped = true;
    _cancelReconnect();
    cancelAuthWatchdog();
    _cancelConnectDeadline();
    _dialSeq++;
    _releaseSupersededHold();
    _candidates = <HubEndpoint>[];
    _prefer = null;
    _pending.clearReplacementFollow();
    // `stop()` closes `changes` for good and never resets the state, so nothing
    // else would ever drop the derivations; they die here.
    _store.clearDerivations();
    _historyPages.clearAllPending();
    // Every in-flight command fails rather than hanging the caller forever.
    _pending.failPending('client stopped');
    await _dropConnection(reason: 'client stopped');
    _setStatus(HubConnectionStatus.disconnected);
    // Emit the terminal state now: cancelling the pending notify would close
    // `changes` without anyone ever observing `disconnected`.
    _flushNotify();
    await _closeControllers();
  }

  Future<void> disconnect() async {
    _stopped = true;
    _cancelReconnect();
    cancelAuthWatchdog();
    _cancelConnectDeadline();
    _dialSeq++;
    _releaseSupersededHold();
    _candidates = <HubEndpoint>[];
    _prefer = null;
    _pending.failPending('disconnected');
    // Not awaited: closing the socket below ends delivery, and awaiting a
    // subscription cancel leaves a UI-initiated disconnect pending under a
    // widget-test clock.
    await _dropConnection(awaitSubscription: false, reason: 'disconnected');
    _credential = null;
    _pending.clearReplacementFollow();
    _attempt = 0;
    // Clears `historyLoading` off the transcripts, so it must run before the
    // store reset below wipes them.
    _historyPages.clearAllPending();
    _store.resetForDisconnect();
    _flushNotify();
  }

  /// Closes the current socket and cancels its subscription. Socket teardown
  /// **only** — deliberately no credential, state, pending or `_stopped`
  /// resets, so [startCandidates] can reuse it to displace an in-flight attempt
  /// without wiping the credential it is about to send or stopping the dial it
  /// is about to make.
  Future<void> _dropConnection({
    bool awaitSubscription = true,
    String reason = 'disconnected',
  }) async {
    final socket = _socket;
    _socket = null;
    final subscription = _subscription;
    _subscription = null;
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
  void restoreSubscription() {
    if (_store.resubscribed) return;
    _store.resubscribed = true;
    final sessionId = _store.desiredSessionId ?? _store.state.activeSessionId;
    if (sessionId == null) return;
    // `_subscribe` re-subscribes and re-requests history. Requesting it again
    // here would send a duplicate frame.
    _subscribe(sessionId, restoring: true);
  }

  Future<void> _dial() async {
    if (_stopped || _candidates.isEmpty) return;
    final seq = ++_dialSeq;
    _setStatus(HubConnectionStatus.connecting);
    if (_candidates.length > 1) {
      await _dialRace(seq);
      return;
    }
    HubSocket socket;
    try {
      socket = await _dialSocket(_wsUri(_candidates.first));
    } catch (error) {
      // A superseded dial reports nothing: its failure is not this attempt's.
      if (_stopped || seq != _dialSeq) return;
      _setError('$error', connection: true);
      _scheduleReconnect();
      return;
    }
    if (_stopped || seq != _dialSeq) {
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
  /// it owns and adopts nothing. With [_prefer] set, the first non-preferred
  /// success is held (no `hello`, so the single-use ticket is untouched) while
  /// the preferred candidate settles; the preferred's own 2 s deadline bounds
  /// that hold, and on its failure the held socket is adopted.
  ///
  /// A superseding [startCandidates], [stop] or [disconnect] closes the held
  /// socket and settles this race through [_releaseSupersededHold], so even a
  /// preferred dial whose factory never resolves cannot leak the hold or hang
  /// the caller.
  Future<void> _dialRace(int seq) async {
    final candidates = List<HubEndpoint>.of(_candidates);
    final prefer = _prefer;
    final decision = Completer<void>();
    var remaining = candidates.length;
    var preferFailed = false;
    HubSocket? held;

    bool superseded() => _stopped || seq != _dialSeq;

    Future<void> closeSocket(HubSocket? socket) async {
      if (socket == null) return;
      try {
        await socket.close();
      } catch (_) {
        // Already gone; nothing to do.
      }
    }

    // The held socket is mirrored in `_heldCandidate` so a lifecycle method
    // that supersedes this race can close it: a stalled preferred dial never
    // calls `evaluate`, so the local would otherwise be unreachable.
    void hold(HubSocket socket) {
      held = socket;
      _heldCandidate = socket;
      _heldSeq = seq;
    }

    void dropHeld() {
      held = null;
      _heldCandidate = null;
      _heldSeq = 0;
    }

    void finish() {
      if (identical(_raceDecision, decision)) _raceDecision = null;
      if (!decision.isCompleted) decision.complete();
    }

    void fail() {
      final addresses = candidates
          .map((candidate) => '${candidate.host}:${candidate.port}')
          .join(', ');
      _setError(
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

    _raceDecision = decision;
    await decision.future;
  }

  /// Adopts [socket]: makes it the live connection and sends the `hello`. The
  /// extracted tail of the old single-candidate `_dial`, unchanged so the
  /// single path stays behaviourally identical.
  void _adoptSocket(HubSocket socket) {
    _socket = socket;
    _attempt = 0;
    _store.resubscribed = false;
    _setStatus(HubConnectionStatus.authenticating);
    send(_hello());
    _armAuthWatchdog();
    _subscription = socket.messages.listen(
      _onFrame,
      onError: (Object _) {},
      onDone: () => _onSocketDone(socket),
    );
  }

  Uri _wsUri(HubEndpoint endpoint) =>
      Uri(scheme: 'ws', host: endpoint.host, port: endpoint.port);

  /// Dials through [_socketFactory] but bounds the wait with [timeout] (the
  /// 10 s default, or the shorter candidate bound inside a race).
  ///
  /// The deadline is scheduled through the injected scheduler so a test can
  /// drive it. If it expires first, the returned future fails and a socket that
  /// arrives afterwards is closed and dropped — never adopted, and never sent a
  /// `hello`.
  ///
  /// Its timer is added to [_connectTimers] and removes its own entry when it
  /// fires, is cancelled, or its socket arrives — never a blanket cancel, so a
  /// race can never kill a successor attempt's deadlines.
  ///
  /// A generation bump (a stop, or a new [startCandidates]) cancels the timer
  /// but does not settle the completer, so a `_dial` still awaiting a stalled
  /// factory stays pending until the factory itself resolves. That is
  /// deliberate: the caller is superseded and its result is discarded by the
  /// generation guard in `_dial`, and the factory is bounded in production by
  /// the OS connect timeout. Failing it here would be extra machinery for no
  /// observable gain.
  Future<HubSocket> _dialSocket(Uri url, {Duration? timeout}) {
    final effective = timeout ?? _connectTimeout;
    final completer = Completer<HubSocket>();
    // Captured now, not read from a field at expiry: the candidate list is
    // replaced by every `start()`, so a superseded dial would otherwise name
    // the wrong host.
    final endpoint = '${url.host}:${url.port}';
    late final HubTimer timer;
    timer = _scheduler.schedule(effective, () {
      _connectTimers.remove(timer);
      if (completer.isCompleted) return;
      completer.completeError(
        TimeoutException(
          'could not reach $endpoint within ${effective.inSeconds} seconds',
        ),
      );
    }, kind: HubTimerKind.connect);
    _connectTimers.add(timer);
    unawaited(() async {
      try {
        final socket = await _socketFactory(url);
        timer.cancel();
        _connectTimers.remove(timer);
        if (completer.isCompleted) {
          // The deadline already failed this dial; the socket is too late.
          unawaited(socket.close().catchError((Object _) {}));
          return;
        }
        completer.complete(socket);
      } catch (error, stackTrace) {
        timer.cancel();
        _connectTimers.remove(timer);
        if (completer.isCompleted) return;
        completer.completeError(error, stackTrace);
      }
    }());
    return completer.future;
  }

  Future<void> _onSocketDone(HubSocket socket) async {
    final close = await socket.closed;
    if (_socket != socket) return;
    _socket = null;
    final wasAuthenticating =
        _store.state.status == HubConnectionStatus.authenticating;
    cancelAuthWatchdog();
    // Not awaited: the socket is already done, and awaiting a subscription
    // cancel leaves the close path (and the error it records) pending.
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel() ?? Future<void>.value());
    if (_stopped) return;
    // A lost socket can never deliver a result; fail rather than hang. A
    // `followsReplacement` pending is exempt: the replacement proceeds on the
    // server regardless of this viewer's reconnect, so failing it here would
    // report an error while the successor still arrives minutes later. It is
    // bounded by the 15 s replacement timer instead.
    _pending.failPending('connection lost', skipReplacement: true);
    if (close.code == closeCapability) {
      _setStatus(HubConnectionStatus.disconnected);
      return;
    }
    if (close.code == closeRateLimited) {
      // The hub delayed this close on purpose; say so, or the longer wait looks
      // like a generic reconnect loop.
      _setError(
        'the hub is rate-limiting authentication; retrying in '
        '${rateLimitedReconnectDelay.inSeconds} seconds',
        connection: true,
      );
      _setStatus(HubConnectionStatus.connecting);
      _scheduleReconnect(fixed: rateLimitedReconnectDelay);
      return;
    }
    if (wasAuthenticating && _store.state.lastError == null) {
      // A rejected ticket closes without a `paired` and cancels the watchdog, so
      // unless an error is recorded here the pairing form spins forever.
      _setError(
        'the hub closed the connection before authenticating; the pairing '
        'code may be invalid — enter a new one',
        connection: true,
      );
    }
    _setStatus(HubConnectionStatus.connecting);
    _scheduleReconnect();
  }

  void _armAuthWatchdog() {
    cancelAuthWatchdog();
    _authTimer = _scheduler.schedule(_authTimeout, () {
      _authTimer = null;
      _onAuthTimeout();
    }, kind: HubTimerKind.auth);
  }

  /// Cancels the authentication watchdog of the current attempt.
  void cancelAuthWatchdog() {
    _authTimer?.cancel();
    _authTimer = null;
  }

  void _cancelConnectDeadline() {
    for (final timer in _connectTimers) {
      timer.cancel();
    }
    _connectTimers.clear();
  }

  /// Releases whatever a superseded race is holding. A stalled preferred dial
  /// never runs the race's own `evaluate`, so [startCandidates], [stop] and
  /// [disconnect] must close the held socket and settle the race here —
  /// otherwise the socket leaks and the race's awaiting caller hangs forever.
  ///
  /// A no-op when no race is in flight. The generation check is defensive: the
  /// callers bump [_dialSeq] first, so a held candidate always belongs to a
  /// superseded generation.
  void _releaseSupersededHold() {
    final socket = _heldCandidate;
    if (socket != null && _heldSeq != _dialSeq) {
      _heldCandidate = null;
      _heldSeq = 0;
      unawaited(socket.close().catchError((Object _) {}));
    }
    final decision = _raceDecision;
    _raceDecision = null;
    if (decision != null && !decision.isCompleted) decision.complete();
  }

  void _onAuthTimeout() {
    final socket = _socket;
    if (socket == null) return;
    _setError(
      'timed out waiting for the hub to authenticate; the pairing token '
      'may be stale',
      connection: true,
    );
    // Closing lets the normal socket-done path schedule a backoff redial.
    unawaited(socket.close().catchError((Object _) {}));
  }

  void _scheduleReconnect({Duration? fixed}) {
    if (_stopped || _reconnectTimer != null) return;
    final Duration delay;
    if (fixed != null) {
      delay = fixed;
    } else {
      delay = computeBackoff(_attempt, rng: _rng);
      _attempt++;
    }
    _reconnectTimer = _scheduler.schedule(delay, () {
      _reconnectTimer = null;
      unawaited(_dial());
    }, kind: HubTimerKind.reconnect);
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }
}
