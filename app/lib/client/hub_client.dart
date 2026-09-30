// ignore_for_file: prefer_initializing_formals
// The dependency fields are private, and a private *named* parameter is illegal
// in Dart, so the initializer list is the only way to bind them (the lint's
// suggested fix does not compile).

/// The hub client — the app's connection to the supervisor.
///
/// Pure `dart:async`/`dart:convert`/`dart:math`: no Flutter imports, so it tests
/// without a widget binding. The socket factory, the scheduler and the RNG are
/// injected; the token store is a seam.
///
/// # Responsibilities
///
/// - Dial `ws://host:port`, authenticate with a ticket (first pairing) or a
///   stored token (every later run), and persist the token on `paired`.
/// - Decode every inbound frame through `protocol/protocol.dart` (never a
///   hand-rolled shape) and route it to typed state.
/// - Hold connection status, the session list fed by the hub's `sessions` push,
///   and a per-session transcript.
/// - Coalesce stream deltas: they accumulate synchronously, but observers are
///   notified at most once per scheduled frame, never once per token.
/// - Reconnect with capped jittered backoff; never on a `4003` capability close;
///   with a longer fixed wait on a `4008` rate-limited close.
/// - Correlate `command` → `command-result` back to the issuing caller.
/// - Re-request history on `resync-required`, and drop `session-gone` sessions.
///
/// # How a widget consumes this
///
/// Read [state] for the current snapshot and listen to [changes] for coalesced
/// notifications. A widget rebuilds from `state` on each [changes] event; the
/// coalescing lives here, not in the widget, so a burst of tokens yields one
/// rebuild per frame.
library;

import 'dart:async';
import 'dart:math';

import '../protocol/protocol.dart';
import 'hub_socket.dart';
import 'scheduler.dart';
import 'token_store.dart';

/// Where the connection is in its lifecycle.
enum HubConnectionStatus { disconnected, connecting, authenticating, connected }

/// One entry in the hub's `sessions` push. Deliberately no `lastSeq`.
class SessionSummary {
  final String sessionId;
  final String label;
  final String agentState;

  const SessionSummary({
    required this.sessionId,
    required this.label,
    required this.agentState,
  });

  factory SessionSummary.fromJson(Map<String, Object?> json) => SessionSummary(
    sessionId: json['sessionId']! as String,
    label: json['label']! as String,
    agentState: json['agentState']! as String,
  );
}

/// The renderer-agnostic transcript for one session.
///
/// [entries] hold raw relayed values exactly as they arrived (history/snapshot
/// entries, relayed `message` bodies, and raw `status`/`tool` payloads), so the
/// UI layer can decide how to render them. Markdown, if it is ever rendered, is
/// a UI decision this type does not make.
class SessionTranscript {
  final List<Object?> entries;

  /// Text accumulated from `stream` deltas since the last baseline.
  final String streamingText;

  /// True while deltas are being appended; cleared on `agent_settled` (the
  /// protocol's terminal state), never on a message-level completion.
  final bool streaming;

  final String agentState;
  final int lastSeq;
  final bool historyLoaded;
  final bool truncated;

  const SessionTranscript({
    this.entries = const [],
    this.streamingText = '',
    this.streaming = false,
    this.agentState = 'idle',
    this.lastSeq = 0,
    this.historyLoaded = false,
    this.truncated = false,
  });

  SessionTranscript copyWith({
    List<Object?>? entries,
    String? streamingText,
    bool? streaming,
    String? agentState,
    int? lastSeq,
    bool? historyLoaded,
    bool? truncated,
  }) => SessionTranscript(
    entries: entries ?? this.entries,
    streamingText: streamingText ?? this.streamingText,
    streaming: streaming ?? this.streaming,
    agentState: agentState ?? this.agentState,
    lastSeq: lastSeq ?? this.lastSeq,
    historyLoaded: historyLoaded ?? this.historyLoaded,
    truncated: truncated ?? this.truncated,
  );
}

const Object _unset = Object();

/// An immutable snapshot of everything the client knows.
class HubClientState {
  final HubConnectionStatus status;
  final List<SessionSummary> sessions;
  final Map<String, SessionTranscript> transcripts;
  final String? activeSessionId;
  final String? lastError;

  const HubClientState({
    this.status = HubConnectionStatus.disconnected,
    this.sessions = const [],
    this.transcripts = const {},
    this.activeSessionId,
    this.lastError,
  });

  HubClientState copyWith({
    HubConnectionStatus? status,
    List<SessionSummary>? sessions,
    Map<String, SessionTranscript>? transcripts,
    Object? activeSessionId = _unset,
    Object? lastError = _unset,
  }) => HubClientState(
    status: status ?? this.status,
    sessions: sessions ?? this.sessions,
    transcripts: transcripts ?? this.transcripts,
    activeSessionId: identical(activeSessionId, _unset)
        ? this.activeSessionId
        : activeSessionId as String?,
    lastError: identical(lastError, _unset)
        ? this.lastError
        : lastError as String?,
  );
}

/// The outcome of one dispatched command.
class CommandResult {
  final bool ok;
  final String? error;
  const CommandResult({required this.ok, this.error});
}

/// The close code the hub sends for a capability violation. Retrying a bridge
/// bug at capped backoff would reconnect forever, so this one never reconnects.
const int closeCapability = 4003;

/// The close code the hub sends when the credential attempt cap is reached.
const int closeRateLimited = 4008;

/// The fixed wait after a `4008` close. The hub delayed that close on purpose;
/// retrying sooner would only add load.
const Duration rateLimitedReconnectDelay = Duration(milliseconds: 30000);

const int _backoffBaseMs = 500;
const int _backoffCapMs = 30000;

/// Consecutive `resync-required` answers a session may provoke before the
/// client stops re-requesting and surfaces an error. A resync whose snapshot is
/// itself dropped would otherwise loop forever.
const int _maxConsecutiveResyncs = 3;

/// Bounded wait for `paired` or `sessions` after dialing. A wrong or stale
/// token gets silence on an open socket — the hub charges one attempt per
/// `hello` and this client sends exactly one — so without this the client would
/// stay `authenticating` forever with no error.
const Duration _authTimeout = Duration(seconds: 10);

/// Bounded wait for a `command-result` before the caller's future fails.
const Duration _commandTimeout = Duration(seconds: 30);

/// One in-flight `command`, with the session it belongs to (so `session-gone`
/// can fail it) and its timeout handle.
class _PendingCommand {
  _PendingCommand(this.sessionId, this.completer);

  final String sessionId;
  final Completer<CommandResult> completer;
  HubTimer? timer;
}

class HubClient {
  HubClient({
    required HubSocketFactory socketFactory,
    required HubScheduler scheduler,
    required TokenStore tokenStore,
    double Function()? rng,
    Duration frameInterval = Duration.zero,
  }) : _socketFactory = socketFactory,
       _scheduler = scheduler,
       _tokenStore = tokenStore,
       _rng = rng ?? Random().nextDouble,
       _frameInterval = frameInterval;

  final HubSocketFactory _socketFactory;
  final HubScheduler _scheduler;
  final TokenStore _tokenStore;
  final double Function() _rng;
  final Duration _frameInterval;

  final StreamController<HubClientState> _changesController =
      StreamController<HubClientState>.broadcast(sync: true);

  HubClientState _state = const HubClientState();
  final Map<String, _PendingCommand> _pendingCommands = {};

  /// Consecutive resync answers per session, reset by a `snapshot` or a fresh
  /// `subscribe`.
  final Map<String, int> _resyncCounts = {};

  Uri? _url;
  Map<String, Object?>? _credential;
  HubSocket? _socket;
  StreamSubscription<Object?>? _subscription;
  HubTimer? _notifyTimer;
  HubTimer? _reconnectTimer;
  HubTimer? _authTimer;
  int _attempt = 0;
  bool _stopped = true;
  int _commandCounter = 0;
  bool _resubscribed = false;

  /// The current snapshot.
  HubClientState get state => _state;

  /// Coalesced notifications: at most one per scheduled frame, regardless of how
  /// many deltas arrived.
  Stream<HubClientState> get changes => _changesController.stream;

  /// The number of consecutive resyncs a session is allowed before the client
  /// gives up. Exposed for the tests that drive the cap.
  static const int maxConsecutiveResyncs = _maxConsecutiveResyncs;

  SessionTranscript? transcript(String sessionId) =>
      _state.transcripts[sessionId];

  /// Dials the hub. Uses [ticket] when given, otherwise the stored token.
  ///
  /// Returns after the first dial attempt; reconnects after that happen in the
  /// background. Throws [StateError] when neither credential is available.
  Future<void> start(String host, {int port = 8787, String? ticket}) async {
    _url = Uri(scheme: 'ws', host: host, port: port);
    if (ticket != null) {
      _credential = {'ticket': ticket};
    } else {
      final stored = await _tokenStore.read();
      if (stored == null || stored.isEmpty) {
        throw StateError('a ticket or a stored token is required to connect');
      }
      _credential = {'token': stored};
    }
    _stopped = false;
    _attempt = 0;
    await _dial();
  }

  /// Stops reconnecting, closes the socket, and closes [changes].
  Future<void> stop() async {
    _stopped = true;
    _cancelReconnect();
    _cancelAuthWatchdog();
    // Every in-flight command fails rather than hanging the caller forever.
    _failPending('client stopped');
    final socket = _socket;
    _socket = null;
    await _subscription?.cancel();
    _subscription = null;
    if (socket != null) {
      try {
        await socket.close(1000, 'client stopped');
      } catch (_) {
        // Already gone; nothing to do.
      }
    }
    _setStatus(HubConnectionStatus.disconnected);
    // Emit the terminal state now: cancelling the pending notify would close
    // `changes` without anyone ever observing `disconnected`.
    _flushNotify();
    if (!_changesController.isClosed) await _changesController.close();
  }

  /// Like [stop], but leaves [changes] open so the app can point at a different
  /// hub and [start] again. Resets the client to its initial snapshot.
  ///
  /// [stop] closes [changes] forever, so it cannot be used to change hubs.
  Future<void> disconnect() async {
    _stopped = true;
    _cancelReconnect();
    _cancelAuthWatchdog();
    _failPending('disconnected');
    final socket = _socket;
    _socket = null;
    final subscription = _subscription;
    _subscription = null;
    // Not awaited: closing the socket below ends delivery, and awaiting a
    // subscription cancel leaves the UI's change-hub action pending under a
    // widget-test clock.
    unawaited(subscription?.cancel() ?? Future<void>.value());
    if (socket != null) {
      try {
        await socket.close(1000, 'disconnected');
      } catch (_) {
        // Already gone; nothing to do.
      }
    }
    _credential = null;
    _resubscribed = false;
    _attempt = 0;
    _resyncCounts.clear();
    _state = const HubClientState();
    _flushNotify();
  }

  /// Subscribes to [sessionId] and makes it the session events are attributed to.
  ///
  /// Relayed `event` frames carry no `sessionId`, so the client can only
  /// attribute them to the session it is currently viewing.
  void subscribe(String sessionId) {
    final previous = _state.activeSessionId;
    if (previous != null && previous != sessionId) {
      // The hub only ever adds subscribers, and relayed events carry no
      // sessionId, so leaving the old subscription in place would attribute its
      // events to the newly active session. Enforce the one-session model here
      // rather than tagging events with a sessionId.
      _trySend({
        'protocolVersion': protocolVersion,
        'type': 'unsubscribe',
        'sessionId': previous,
      });
    }
    _resyncCounts.remove(sessionId);
    _ensureTranscript(sessionId);
    _state = _state.copyWith(activeSessionId: sessionId);
    _trySend({
      'protocolVersion': protocolVersion,
      'type': 'subscribe',
      'sessionId': sessionId,
    });
    _scheduleNotify();
  }

  void unsubscribe(String sessionId) {
    _trySend({
      'protocolVersion': protocolVersion,
      'type': 'unsubscribe',
      'sessionId': sessionId,
    });
    if (_state.activeSessionId == sessionId) {
      _state = _state.copyWith(activeSessionId: null);
      _scheduleNotify();
    }
  }

  /// Sends a `history-request`. The hub answers with a `snapshot`.
  void requestHistory(String sessionId, {int? sinceSeq}) {
    final message = <String, Object?>{
      'protocolVersion': protocolVersion,
      'type': 'history-request',
      'sessionId': sessionId,
    };
    // `sinceSeq` must be a positive safe integer; 0 or a negative is a
    // guaranteed hub `4002` self-kick, so clamp to the valid floor.
    if (sinceSeq != null) message['sinceSeq'] = sinceSeq < 1 ? 1 : sinceSeq;
    _trySend(message);
  }

  /// Sends one allowlisted command and completes when its `command-result`
  /// arrives. The correlation id is generated here unless [id] is supplied.
  Future<CommandResult> sendCommand(
    String sessionId,
    String name, {
    Map<String, Object?>? args,
    String? id,
  }) {
    if (_socket == null) {
      // Dropping the command silently would leave the UI spinning forever.
      return Future.value(
        const CommandResult(ok: false, error: 'not connected'),
      );
    }
    final commandId = id ?? 'cmd-${++_commandCounter}';
    final completer = Completer<CommandResult>();
    final pending = _PendingCommand(sessionId, completer);
    _pendingCommands[commandId] = pending;
    pending.timer = _scheduler.schedule(_commandTimeout, () {
      final removed = _pendingCommands.remove(commandId);
      if (removed == null || removed.completer.isCompleted) return;
      removed.completer.complete(
        const CommandResult(ok: false, error: 'timed out'),
      );
    }, kind: HubTimerKind.command);
    final message = <String, Object?>{
      'protocolVersion': protocolVersion,
      'type': 'command',
      'id': commandId,
      'sessionId': sessionId,
      'name': name,
    };
    if (args != null) message['args'] = args;
    final error = _trySend(message);
    if (error != null) {
      // A closing socket must not leave the caller with a thrown exception and
      // an entry that only the 30s timeout would clear.
      _pendingCommands.remove(commandId);
      pending.timer?.cancel();
      completer.complete(CommandResult(ok: false, error: '$error'));
    }
    return completer.future;
  }

  /// Restores the subscription the previous connection held, once this
  /// connection is authenticated.
  ///
  /// The hub drops a closed connection from a session's subscriber set, so
  /// after a redial the client would otherwise keep its `activeSessionId` and
  /// transcript while the hub delivers nothing — a transcript that silently
  /// stops updating. Re-subscribing alone is not enough: the drop may have
  /// gapped the transcript, so history is re-requested too. Idempotent per
  /// dial, because the token path confirms auth with a `sessions` push that
  /// also fires on every registry change.
  void _restoreSubscription() {
    if (_resubscribed) return;
    _resubscribed = true;
    final sessionId = _state.activeSessionId;
    if (sessionId == null) return;
    subscribe(sessionId);
    requestHistory(sessionId);
  }

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  Future<void> _dial() async {
    final url = _url;
    if (_stopped || url == null) return;
    _setStatus(HubConnectionStatus.connecting);
    HubSocket socket;
    try {
      socket = await _socketFactory(url);
    } catch (error) {
      _state = _state.copyWith(lastError: '$error');
      _scheduleNotify();
      _scheduleReconnect();
      return;
    }
    if (_stopped) {
      await socket.close();
      return;
    }
    _socket = socket;
    _attempt = 0;
    _resubscribed = false;
    _setStatus(HubConnectionStatus.authenticating);
    _send(_hello());
    _armAuthWatchdog();
    _subscription = socket.messages.listen(
      _onFrame,
      onError: (Object _) {},
      onDone: () => _onSocketDone(socket),
    );
  }

  Future<void> _onSocketDone(HubSocket socket) async {
    final close = await socket.closed;
    if (_socket != socket) return;
    _socket = null;
    final wasAuthenticating =
        _state.status == HubConnectionStatus.authenticating;
    _cancelAuthWatchdog();
    // Not awaited: the socket is already done, and awaiting a subscription
    // cancel leaves the close path (and the error it records) pending.
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel() ?? Future<void>.value());
    if (_stopped) return;
    // A lost socket can never deliver a result; fail rather than hang.
    _failPending('connection lost');
    if (close.code == closeCapability) {
      _setStatus(HubConnectionStatus.disconnected);
      return;
    }
    if (close.code == closeRateLimited) {
      // The hub delayed this close on purpose; say so, or the longer wait looks
      // like a generic reconnect loop.
      _state = _state.copyWith(
        lastError:
            'the hub is rate-limiting authentication; retrying in '
            '${rateLimitedReconnectDelay.inSeconds} seconds',
      );
      _scheduleNotify();
      _setStatus(HubConnectionStatus.connecting);
      _scheduleReconnect(fixed: rateLimitedReconnectDelay);
      return;
    }
    if (wasAuthenticating && _state.lastError == null) {
      // A rejected ticket closes without a `paired` and cancels the watchdog, so
      // unless an error is recorded here the pairing form spins forever.
      _state = _state.copyWith(
        lastError:
            'the hub closed the connection before authenticating; the pairing '
            'code may be invalid — enter a new one',
      );
      _scheduleNotify();
    }
    _setStatus(HubConnectionStatus.connecting);
    _scheduleReconnect();
  }

  void _armAuthWatchdog() {
    _cancelAuthWatchdog();
    _authTimer = _scheduler.schedule(_authTimeout, () {
      _authTimer = null;
      _onAuthTimeout();
    }, kind: HubTimerKind.auth);
  }

  void _cancelAuthWatchdog() {
    _authTimer?.cancel();
    _authTimer = null;
  }

  void _onAuthTimeout() {
    final socket = _socket;
    if (socket == null) return;
    _state = _state.copyWith(
      lastError:
          'timed out waiting for the hub to authenticate; the pairing token '
          'may be stale',
    );
    _scheduleNotify();
    // Closing lets the normal socket-done path schedule a backoff redial.
    unawaited(socket.close().catchError((Object _) {}));
  }

  void _scheduleReconnect({Duration? fixed}) {
    if (_stopped || _reconnectTimer != null) return;
    final Duration delay;
    if (fixed != null) {
      delay = fixed;
    } else {
      delay = _computeBackoff(_attempt);
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

  /// Exponential backoff with full jitter, capped. `attempt` is 0-based.
  Duration _computeBackoff(int attempt) {
    final exponent = attempt < 0 ? 0 : attempt;
    final ceilingMs = min(
      _backoffCapMs,
      (_backoffBaseMs * pow(2, exponent)).toInt(),
    );
    final delayMs = (_rng() * ceilingMs).floor();
    return Duration(milliseconds: delayMs);
  }

  // ---------------------------------------------------------------------------
  // Inbound routing
  // ---------------------------------------------------------------------------

  /// Entry point for one inbound frame. Wrapped so a throw cannot escape into
  /// the socket's `listen` callback — an uncaught async error there is an
  /// unhandled zone error. A backstop: outbound sends have their own guard.
  void _onFrame(Object? frame) {
    try {
      _handleFrame(frame);
    } catch (error) {
      _state = _state.copyWith(lastError: '$error');
      _scheduleNotify();
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
        _onSessions(message['sessions']! as List);
      case 'event':
        _onEvent((message['payload']! as Map).cast<String, Object?>());
      case 'snapshot':
        _onSnapshot(message);
      case 'command-result':
        _onCommandResult(message);
      case 'resync-required':
        _onResyncRequired(message['sessionId']! as String);
      case 'session-gone':
        _onSessionGone(message['sessionId']! as String);
    }
  }

  Future<void> _onPaired(String token) async {
    _cancelAuthWatchdog();
    // Later reconnects authenticate with the token, not the spent ticket.
    _credential = {'token': token};
    try {
      // Report connected only once the token is durable: a kill in the
      // unawaited-write window would silently lose it and re-pair.
      await _tokenStore.write(token);
    } catch (error) {
      _state = _state.copyWith(lastError: 'could not persist token: $error');
      _scheduleNotify();
      return;
    }
    _setStatus(HubConnectionStatus.connected);
    _restoreSubscription();
  }

  void _onSessions(List<dynamic> raw) {
    _cancelAuthWatchdog();
    final summaries = raw
        .map(
          (entry) =>
              SessionSummary.fromJson((entry as Map).cast<String, Object?>()),
        )
        .toList();
    _state = _state.copyWith(sessions: summaries);
    // The hub pushes `sessions` on authentication; its arrival is how a
    // token-authenticated connection is confirmed (there is no `paired`).
    _setStatus(HubConnectionStatus.connected);
    _restoreSubscription();
  }

  void _onEvent(Map<String, Object?> payload) {
    final sessionId = _state.activeSessionId;
    if (sessionId == null) return;
    final transcript =
        _state.transcripts[sessionId] ?? const SessionTranscript();
    switch (payload['kind']) {
      case 'stream':
        final seq = (payload['seq']! as num).toInt();
        _putTranscript(
          sessionId,
          transcript.copyWith(
            streamingText:
                transcript.streamingText + (payload['text']! as String),
            streaming: true,
            lastSeq: seq > transcript.lastSeq ? seq : transcript.lastSeq,
          ),
        );
      case 'agent':
        final agentState = payload['state']! as String;
        // Terminal state is `settled`, never a message-level end. Clearing the
        // buffer too keeps a settle-without-message from hiding the text and
        // leaving the next stream appending to a stale buffer.
        final running = agentState == 'running';
        _putTranscript(
          sessionId,
          transcript.copyWith(
            agentState: agentState,
            streaming: running ? transcript.streaming : false,
            streamingText: running ? transcript.streamingText : '',
          ),
        );
      case 'message':
        _putTranscript(
          sessionId,
          transcript.copyWith(
            entries: [...transcript.entries, payload['message']],
            streamingText: '',
            streaming: false,
          ),
        );
      default:
        // `status`/`tool` are relayed raw so the renderer can decide.
        _putTranscript(
          sessionId,
          transcript.copyWith(entries: [...transcript.entries, payload]),
        );
    }
    _scheduleNotify();
  }

  void _onSnapshot(Map<String, Object?> message) {
    final sessionId = message['sessionId']! as String;
    // A delivered baseline breaks any resync streak.
    _resyncCounts.remove(sessionId);
    _putTranscript(
      sessionId,
      SessionTranscript(
        entries: (message['entries']! as List).cast<Object?>(),
        lastSeq: (message['lastSeq']! as num).toInt(),
        agentState: message['agentState']! as String,
        truncated: message['truncated']! as bool,
        historyLoaded: true,
      ),
    );
    _scheduleNotify();
  }

  void _onCommandResult(Map<String, Object?> message) {
    final id = message['id']! as String;
    final pending = _pendingCommands.remove(id);
    if (pending == null || pending.completer.isCompleted) return;
    pending.timer?.cancel();
    pending.completer.complete(
      CommandResult(
        ok: message['ok']! as bool,
        error: message['error'] as String?,
      ),
    );
  }

  void _onResyncRequired(String sessionId) {
    final count = (_resyncCounts[sessionId] ?? 0) + 1;
    _resyncCounts[sessionId] = count;
    if (count > _maxConsecutiveResyncs) {
      // Re-requesting forever is the livelock; stop and surface it instead.
      _state = _state.copyWith(
        lastError:
            'gave up resyncing $sessionId after $_maxConsecutiveResyncs attempts',
      );
      _scheduleNotify();
      return;
    }
    requestHistory(sessionId);
  }

  void _onSessionGone(String sessionId) {
    _resyncCounts.remove(sessionId);
    _failPending('session gone', sessionId: sessionId);
    final sessions = _state.sessions
        .where((summary) => summary.sessionId != sessionId)
        .toList();
    final transcripts = {..._state.transcripts}..remove(sessionId);
    _state = _state.copyWith(
      sessions: sessions,
      transcripts: transcripts,
      activeSessionId: _state.activeSessionId == sessionId
          ? null
          : _state.activeSessionId,
    );
    _scheduleNotify();
  }

  void _failPending(String error, {String? sessionId}) {
    for (final entry in [..._pendingCommands.entries]) {
      final pending = entry.value;
      if (sessionId != null && pending.sessionId != sessionId) continue;
      _pendingCommands.remove(entry.key);
      pending.timer?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.complete(CommandResult(ok: false, error: error));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Outbound + state plumbing
  // ---------------------------------------------------------------------------

  Map<String, Object?> _hello() => <String, Object?>{
    'protocolVersion': protocolVersion,
    'type': 'hello',
    ...?_credential,
  };

  void _send(Map<String, Object?> message) {
    final socket = _socket;
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
      _state = _state.copyWith(lastError: '$error');
      _scheduleNotify();
      return error;
    }
  }

  void _ensureTranscript(String sessionId) {
    if (_state.transcripts.containsKey(sessionId)) return;
    _putTranscript(sessionId, const SessionTranscript());
  }

  void _putTranscript(String sessionId, SessionTranscript transcript) {
    _state = _state.copyWith(
      transcripts: {..._state.transcripts, sessionId: transcript},
    );
  }

  void _setStatus(HubConnectionStatus status) {
    if (_state.status == status) return;
    _state = _state.copyWith(status: status);
    _scheduleNotify();
  }

  void _scheduleNotify() {
    if (_notifyTimer != null) return;
    _notifyTimer = _scheduler.schedule(_frameInterval, () {
      _notifyTimer = null;
      if (!_changesController.isClosed) _changesController.add(_state);
    }, kind: HubTimerKind.notify);
  }

  /// Emits the current state immediately, cancelling any coalescing wait. Used
  /// where a terminal state must be observed before [changes] closes.
  void _flushNotify() {
    _notifyTimer?.cancel();
    _notifyTimer = null;
    if (!_changesController.isClosed) _changesController.add(_state);
  }
}
