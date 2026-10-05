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
import 'endpoint_store.dart';
import 'hub_socket.dart';
import 'scheduler.dart';
import 'token_store.dart';
import 'context_usage.dart';
import 'transcript.dart';
import 'hub_models.dart';
export 'hub_models.dart';

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

/// Consecutive `session-gone` answers a session may provoke before the client
/// stops re-subscribing and surfaces an error. Under the cap a rejection re-arms
/// the re-subscribe (which recovers the race the M10b fix targeted); past it the
/// session is genuinely gone and retrying forever only churns the registry.
const int _maxConsecutiveSessionGone = 3;

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

/// Bounded wait for a `command-result` before the caller's future fails.
const Duration _commandTimeout = Duration(seconds: 30);

/// Bounded wait for an older page. A live socket is not a live agent: the
/// bridge returns silently when it has no `ctx`, so without this an unanswered
/// page would leave the control loading (and single-flight blocking a retry)
/// until some unrelated baseline landed.
const Duration _historyPageTimeout = Duration(seconds: 30);

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

  final StreamController<AgentSettledEvent> _settlesController =
      StreamController<AgentSettledEvent>.broadcast(sync: true);

  final StreamController<LeafEvent> _leafEventsController =
      StreamController<LeafEvent>.broadcast(sync: true);

  HubClientState _state = const HubClientState();
  final Map<String, _PendingCommand> _pendingCommands = {};

  /// One incremental derivation per live session, put and removed in lockstep
  /// with `_state.transcripts`. See `_withEntries` for the staleness contract.
  final Map<String, TranscriptDerivation> _derivations = {};

  /// The cursor of the one in-flight older page per session, keyed by session.
  /// Set by [loadOlder] and cleared by an applied snapshot, the page timeout,
  /// a send failure, `session-gone`, `stop` and `disconnect`.
  final Map<String, String> _pendingHistoryCursor = {};

  /// The page-timeout handle per session, in lockstep with
  /// [_pendingHistoryCursor].
  final Map<String, HubTimer> _historyPageTimers = {};

  /// In-flight `list-dirs`, keyed by their `dirs-N` id. Kept separate from
  /// [_pendingCommands] because the two share the wire `id` field: a
  /// `command-result` for a listing id must not complete a command.
  final Map<String, _PendingListing> _pendingListings = {};

  /// Consecutive resync answers per session, reset by a `snapshot` or a fresh
  /// `subscribe`.
  final Map<String, int> _resyncCounts = {};

  /// Consecutive `session-gone` answers per session, reset by a `snapshot`, a
  /// user-initiated `subscribe`, or `disconnect`.
  final Map<String, int> _sessionGoneCounts = {};

  /// Sessions whose current subscription was restored automatically after a
  /// reconnect, rather than chosen by the user. A `session-gone` answering one
  /// of these is the re-subscribe racing the agent's re-registration, not a
  /// deletion, so its transcript is kept until the give-up cap.
  final Set<String> _restoredSessions = {};

  Map<String, Object?>? _credential;
  HubSocket? _socket;
  StreamSubscription<Object?>? _subscription;
  HubTimer? _notifyTimer;
  HubTimer? _reconnectTimer;
  HubTimer? _authTimer;

  /// One dial deadline per in-flight dial. A dial removes its own entry when it
  /// fires, is cancelled, or its socket arrives; the only blanket cancel is
  /// [_cancelConnectDeadline], run solely at attempt start, stop and
  /// disconnect, before a successor's timers exist.
  final List<HubTimer> _connectTimers = <HubTimer>[];

  /// The candidate addresses of the current attempt, in preference order. Set
  /// by [startCandidates] (and [start], which delegates with one), retained
  /// across reconnects so [_scheduleReconnect] re-races the whole list, and
  /// cleared by [stop] and [disconnect].
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
  int _commandCounter = 0;
  int _listingCounter = 0;
  bool _resubscribed = false;

  /// Whether [HubClientState.lastError] came from the connection path (dial,
  /// auth, send) rather than a session/operation. A later authenticated
  /// connection clears the former; it never clears the latter, because a
  /// reconnect does not fix a session that is gone or a token that would not
  /// persist.
  bool _lastErrorFromConnection = false;

  /// The session the user last asked to view. Unlike [HubClientState.activeSessionId]
  /// it survives a `session-gone`, so a re-subscribe that raced the agent's
  /// re-registration after a hub restart can be retried when the session
  /// reappears instead of leaving the client silently unsubscribed.
  String? _desiredSessionId;

  /// The old session id a `/new` or `/fork` is waiting to be replaced, or null
  /// when no replacement is in flight. While set, `_onSessions` adopts a
  /// summary whose `replacesSessionId` matches it and never re-subscribes the
  /// dead id.
  String? _awaitingReplacementFrom;
  HubTimer? _replacementTimer;

  /// The current snapshot.
  HubClientState get state => _state;

  /// Whether [state]'s [HubClientState.lastError] came from the connection path
  /// (dial, auth, send) rather than a session/operation. A new deliberate dial
  /// clears a connection-scoped error and leaves a session notice alone.
  bool get lastErrorFromConnection => _lastErrorFromConnection;

  /// Coalesced notifications: at most one per scheduled frame, regardless of how
  /// many deltas arrived.
  Stream<HubClientState> get changes => _changesController.stream;

  /// Settle notifications: one event per `agent-settled` frame the hub sends,
  /// regardless of which session is active. Broadcast, so several listeners are
  /// possible; it closes with [stop], never with [disconnect].
  Stream<AgentSettledEvent> get settles => _settlesController.stream;

  /// Leaf moves: one event per `leaf` frame, carrying the session it is
  /// attributed to and the new leaf id (`null` for the root). Broadcast, so
  /// several listeners are possible; it closes with [stop], never with
  /// [disconnect].
  Stream<LeafEvent> get leafEvents => _leafEventsController.stream;

  /// The number of consecutive resyncs a session is allowed before the client
  /// gives up. Exposed for the tests that drive the cap.
  static const int maxConsecutiveResyncs = _maxConsecutiveResyncs;

  /// The number of consecutive `session-gone` answers a session is allowed
  /// before the client gives up. Exposed for the tests that drive the cap.
  static const int maxConsecutiveSessionGone = _maxConsecutiveSessionGone;

  SessionTranscript? transcript(String sessionId) =>
      _state.transcripts[sessionId];

  /// Dials the hub. Uses [ticket] when given, otherwise the stored token.
  ///
  /// Single-candidate shorthand for [startCandidates], so every existing call
  /// site keeps its behaviour: one address, the 10 s connect deadline, and the
  /// same error string.
  Future<void> start(String host, {int port = 8787, String? ticket}) =>
      startCandidates(
        [HubEndpoint(host: host, port: port)],
        ticket: ticket,
      );

  /// Dials every candidate in parallel and adopts the first that opens, or
  /// [prefer] when it is in [candidates] and answers.
  ///
  /// Any attempt already in flight is disposed first: its timers are cancelled
  /// and its socket and subscription are closed. Cancelling the auth watchdog
  /// here is not load-bearing today — `_onAuthTimeout` no-ops on a null
  /// `_socket`, and arming the next watchdog cancels its predecessor — but a
  /// timer that outlives the attempt it was armed for is a trap for the next
  /// edit, so every timer goes up front.
  ///
  /// Returns after the race is decided; reconnects after that happen in the
  /// background. Throws [StateError] when [candidates] is empty or neither
  /// credential is available.
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
    _dialSeq++;
    _releaseSupersededHold();
    // A follow armed on a previous hub names a foreign session id; left set, it
    // would suppress every restore on the new hub until its timer fired.
    _clearReplacementFollow();
    // The follow was just cleared, so a `followsReplacement` pending can never be
    // settled by the abandoned hub: deliberately no `skipReplacement: true`
    // (unlike `_onSocketDone`, whose successor still arrives after a reconnect).
    _failPending('connection replaced');
    _clearPendingHistoryPages();
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

  /// Stops reconnecting, closes the socket, and closes [changes].
  Future<void> stop() async {
    _stopped = true;
    _cancelReconnect();
    _cancelAuthWatchdog();
    _cancelConnectDeadline();
    _dialSeq++;
    _releaseSupersededHold();
    _candidates = <HubEndpoint>[];
    _prefer = null;
    _clearReplacementFollow();
    // `stop()` closes `changes` for good and never resets `_state`, so nothing
    // else would ever drop the derivations; they die here.
    _derivations.clear();
    _clearPendingHistoryPages();
    // Every in-flight command fails rather than hanging the caller forever.
    _failPending('client stopped');
    await _dropConnection(reason: 'client stopped');
    _setStatus(HubConnectionStatus.disconnected);
    // Emit the terminal state now: cancelling the pending notify would close
    // `changes` without anyone ever observing `disconnected`.
    _flushNotify();
    if (!_changesController.isClosed) await _changesController.close();
    if (!_settlesController.isClosed) await _settlesController.close();
    if (!_leafEventsController.isClosed) await _leafEventsController.close();
  }

  /// Like [stop], but leaves [changes] open so the app can point at a different
  /// hub and [start] again. Resets the client to its initial snapshot.
  ///
  /// [stop] closes [changes] forever, so it cannot be used to change hubs.
  Future<void> disconnect() async {
    _stopped = true;
    _cancelReconnect();
    _cancelAuthWatchdog();
    _cancelConnectDeadline();
    _dialSeq++;
    _releaseSupersededHold();
    _candidates = <HubEndpoint>[];
    _prefer = null;
    _failPending('disconnected');
    // Not awaited: closing the socket below ends delivery, and awaiting a
    // subscription cancel leaves a UI-initiated disconnect pending under a
    // widget-test clock.
    await _dropConnection(awaitSubscription: false, reason: 'disconnected');
    _credential = null;
    _clearReplacementFollow();
    _resubscribed = false;
    _desiredSessionId = null;
    _attempt = 0;
    _resyncCounts.clear();
    _sessionGoneCounts.clear();
    _restoredSessions.clear();
    _derivations.clear();
    _clearPendingHistoryPages();
    _lastErrorFromConnection = false;
    _state = const HubClientState();
    _flushNotify();
  }

  /// Closes the current socket and cancels its subscription. Socket teardown
  /// **only** — deliberately no credential, state, pending or `_stopped`
  /// resets, so [start] can reuse it to displace an in-flight attempt without
  /// wiping the credential it is about to send or stopping the dial it is about
  /// to make.
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

  /// Subscribes to [sessionId], makes it the session events are attributed to,
  /// and requests its history so the prior conversation is visible on open.
  ///
  /// Relayed `event` frames carry no `sessionId`, so the client can only
  /// attribute them to the session it is currently viewing.
  void subscribe(String sessionId) {
    // Picking a session is an explicit navigation: a replacement follow for a
    // different session must not later yank the user onto its successor. Clear
    // it and fail the caller, whose witness can no longer arrive.
    final awaited = _awaitingReplacementFrom;
    if (awaited != null && awaited != sessionId) {
      _clearReplacementFollow();
      _abandonReplacementPendings(
        (pending) => pending.sessionId == awaited,
        'superseded',
      );
    }
    // A user picking a session is a fresh start: a gone streak from an earlier
    // automatic retry must not count against it.
    _sessionGoneCounts.remove(sessionId);
    _subscribe(sessionId);
  }

  /// The shared body of [subscribe]. The automatic restore after a
  /// `session-gone` reuses it *without* clearing [_sessionGoneCounts], so
  /// consecutive rejections accumulate to the give-up cap.
  void _subscribe(String sessionId, {bool restoring = false}) {
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
    _desiredSessionId = sessionId;
    if (restoring) {
      _restoredSessions.add(sessionId);
    } else {
      _restoredSessions.remove(sessionId);
    }
    _ensureTranscript(sessionId);
    _state = _state.copyWith(activeSessionId: sessionId);
    _trySend({
      'protocolVersion': protocolVersion,
      'type': 'subscribe',
      'sessionId': sessionId,
    });
    // Subscribing alone yields live events only; the backlog needs an explicit
    // request. Done here, in the shared body, so every open path (a user's
    // choice and the automatic restore) requests it exactly once.
    requestHistory(sessionId);
    // Fire-and-forget: the overlay shows nothing until the list arrives, and a
    // refusal (an old hub's `unknown command`) is deliberately surfaced nowhere.
    unawaited(loadCommands(sessionId));
    _scheduleNotify();
  }

  void unsubscribe(String sessionId) {
    // Unsubscribing the awaited id abandons the replacement it was waiting on.
    if (_awaitingReplacementFrom == sessionId) {
      _clearReplacementFollow();
      _abandonReplacementPendings(
        (pending) => pending.sessionId == sessionId,
        'superseded',
      );
    }
    _trySend({
      'protocolVersion': protocolVersion,
      'type': 'unsubscribe',
      'sessionId': sessionId,
    });
    if (_desiredSessionId == sessionId) _desiredSessionId = null;
    if (_state.activeSessionId == sessionId) {
      _state = _state.copyWith(activeSessionId: null);
      _scheduleNotify();
    }
  }

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
    final transcript = _state.transcripts[sessionId];
    if (transcript == null) return;
    final cursor = transcript.olderCursor;
    if (cursor == null) return;
    if (_pendingHistoryCursor.containsKey(sessionId)) return;
    if (_socket == null) return;

    _pendingHistoryCursor[sessionId] = cursor;
    _putTranscript(sessionId, transcript.copyWith(historyLoading: true));
    _scheduleNotify();
    final error = requestHistory(sessionId, cursor: cursor);
    if (error != null) {
      _pendingHistoryCursor.remove(sessionId);
      _putTranscript(sessionId, transcript.copyWith(historyLoading: false));
      _scheduleNotify();
      return;
    }
    _cancelHistoryPageTimeout(sessionId);
    _historyPageTimers[sessionId] = _scheduler.schedule(_historyPageTimeout, () {
      _historyPageTimers.remove(sessionId);
      if (_pendingHistoryCursor.remove(sessionId) == null) return;
      final current = _state.transcripts[sessionId];
      if (current == null) return;
      _putTranscript(sessionId, current.copyWith(historyLoading: false));
      _scheduleNotify();
    }, kind: HubTimerKind.historyPage);
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
  void _clearPendingHistoryPages() {
    for (final sessionId in _pendingHistoryCursor.keys) {
      final transcript = _state.transcripts[sessionId];
      if (transcript != null && transcript.historyLoading) {
        _putTranscript(sessionId, transcript.copyWith(historyLoading: false));
      }
    }
    _pendingHistoryCursor.clear();
    _cancelHistoryPageTimeouts();
  }

  /// Sends one allowlisted command and completes when its `command-result`
  /// arrives. The correlation id is generated here unless [id] is supplied.
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

  /// Asks the hub for [sessionId]'s real pi commands and completes with them.
  ///
  /// Routed through [_request] so the result correlates like any other command
  /// and `session-gone` can fail it; the cache write is [loadCommands]'s.
  Future<CommandResult> listCommands(String sessionId, {String? id}) {
    return _request(sessionId, id, (commandId) => <String, Object?>{
      'protocolVersion': protocolVersion,
      'type': 'command',
      'id': commandId,
      'sessionId': sessionId,
      'name': 'listCommands',
    });
  }

  /// Asks the hub for pi's auth-configured models and completes with them.
  ///
  /// The picker is a one-shot, not a per-keystroke list, so nothing is cached
  /// here — unlike [listCommands].
  Future<CommandResult> listModels(String sessionId, {String? id}) {
    return _request(sessionId, id, (commandId) => <String, Object?>{
      'protocolVersion': protocolVersion,
      'type': 'command',
      'id': commandId,
      'sessionId': sessionId,
      'name': 'listModels',
    });
  }

  /// Asks the hub for [sessionId]'s session tree as a flat, bounded node list.
  ///
  /// A `/fork` picks its fork point from this list; the tree carries only user
  /// and assistant messages, already relinked to their nearest emitted
  /// ancestor.
  Future<CommandResult> listTree(String sessionId, {String? id}) {
    return _request(sessionId, id, (commandId) => <String, Object?>{
      'protocolVersion': protocolVersion,
      'type': 'command',
      'id': commandId,
      'sessionId': sessionId,
      'name': 'listTree',
    });
  }

  /// Asks pi to replace [sessionId] with a fresh session, in place.
  ///
  /// The ack only means the bridge accepted the command; success is the
  /// replacement itself, so the returned future is settled by the successor's
  /// registration (or by the old session's `session-gone` while the follow is
  /// armed), never by the ack. The follow fails after [_replacementTimeout].
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

  /// Asks pi to fork [sessionId] at [entryId], replacing it in place. Same
  /// replacement-follow contract as [sessionNew].
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

  /// Asks pi to move [sessionId]'s leaf to [entryId], in place.
  ///
  /// A navigation does not replace the session, so this is a plain request: the
  /// ack settles it. The re-baseline is the bridge's separate `leaf` event, not
  /// a history request issued here.
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

  /// Fetches [sessionId]'s commands and caches them under the id that asked —
  /// never the currently active one.
  ///
  /// Also called by the shell when the `/` overlay opens, so the list is fresh
  /// at the point of use (a PC-side `/reload` or a new extension is otherwise
  /// invisible to the app's open socket). The cached list is left untouched
  /// until a successful reply overwrites it; a refusal leaves the previous
  /// cache in place. Each call arms the usual 30s `command` timer.
  ///
  /// The live-session check is defence in depth, not a reachable branch: every
  /// path that drops a transcript (`session-gone` past the cap, `disconnect`,
  /// `stop`, a lost socket) fails that session's pending commands first, and a
  /// successful result can only come from `_onCommandResult`, so the transcript
  /// is still present when this continuation runs. It stays because that
  /// ordering is a cross-function invariant, not a local one.
  Future<void> loadCommands(String sessionId) async {
    final result = await listCommands(sessionId);
    if (!result.ok || result.commands == null) return;
    if (!_state.transcripts.containsKey(sessionId)) return;
    _state = _state.copyWith(
      commands: {..._state.commands, sessionId: result.commands!},
    );
    _scheduleNotify();
  }

  /// Asks the hub to spawn a headless app-started session.
  ///
  /// The hub answers directly to this connection; there is no session to key
  /// the pending result into, so it is registered under the empty-session
  /// convention (`_request`'s `pendingSessionId`) and a `session-gone` for any
  /// session cannot fail it.
  ///
  /// With a [cwd] or [trust] this needs the hub's `project-session` capability:
  /// an old hub would silently ignore the field and temp-spawn, so without it
  /// the call is refused locally and no frame is sent. `trust` is a
  /// project-session-era field too — the hub validates it alongside `cwd` — so
  /// it is only ever sent together with `cwd`.
  Future<CommandResult> startSession({String? id, String? cwd, bool? trust}) {
    if ((cwd != null || trust != null) &&
        !_state.capabilities.contains(capabilityProjectSession)) {
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

  /// Lists the directories under the hub's browse root, or under [path] when
  /// given. A null or empty [path] means the root.
  ///
  /// Refuses locally without the hub's `list-dirs` capability: an old hub takes
  /// an unknown viewer type as a capability violation and closes `4003`, which
  /// this client treats as terminal (no reconnect). The id is namespaced
  /// `dirs-N`, distinct from `_request`'s `cmd-N`.
  Future<DirListingResult> listDirs({String? path, String? id}) {
    if (!_state.capabilities.contains(capabilityListDirs)) {
      return Future.value(
        const DirListingResult(ok: false, error: 'this hub cannot browse folders'),
      );
    }
    if (_socket == null) {
      return Future.value(
        const DirListingResult(ok: false, error: 'not connected'),
      );
    }
    final listingId = id ?? 'dirs-${++_listingCounter}';
    final completer = Completer<DirListingResult>();
    final pending = _PendingListing(completer);
    _pendingListings[listingId] = pending;
    pending.timer = _scheduler.schedule(_commandTimeout, () {
      final removed = _pendingListings.remove(listingId);
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
      _pendingListings.remove(listingId);
      pending.timer?.cancel();
      completer.complete(DirListingResult(ok: false, error: '$error'));
    }
    return completer.future;
  }

  /// Asks the hub to kill an app-started session. Same empty-session pending
  /// convention as [startSession].
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
    if (_socket == null) {
      // Dropping the request silently would leave the UI spinning forever.
      return Future.value(
        const CommandResult(ok: false, error: 'not connected'),
      );
    }
    final commandId = id ?? 'cmd-${++_commandCounter}';
    final completer = Completer<CommandResult>();
    final pending = _PendingCommand(
      pendingSessionId,
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
    if (followsReplacement) _beginReplacementFollow(pendingSessionId);
    final error = _trySend(build(commandId));
    if (error != null) {
      // A closing socket must not leave the caller with a thrown exception and
      // an entry that only the 30s timeout would clear.
      _pendingCommands.remove(commandId);
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
    _replacementTimer?.cancel();
    _awaitingReplacementFrom = oldId;
    _replacementTimer = _scheduler.schedule(_replacementTimeout, () {
      final old = _awaitingReplacementFrom;
      if (old == null) return;
      _clearReplacementFollow();
      // Re-enable the normal restore path *without* moving `_desiredSessionId`:
      // the next `sessions` push re-subscribes the old id, the hub answers
      // `session-gone`, and the existing cap machinery takes it from there.
      _resubscribed = false;
      _failPending('the session did not come back', sessionId: old);
    }, kind: HubTimerKind.replacement);
  }

  /// Clears the replacement follow: no successor was adopted (or none is still
  /// awaited), so a later restore must not depend on it.
  void _clearReplacementFollow() {
    _replacementTimer?.cancel();
    _replacementTimer = null;
    _awaitingReplacementFrom = null;
  }

  /// Completes every still-outstanding `followsReplacement` pending for
  /// [oldId] as `ok`. Called at both replacement witnesses — adoption in
  /// `_onSessions` and `_onSessionGone` while the follow is armed — so the two
  /// arrival orders converge on the same outcome.
  void _settleReplacementPendings(String oldId) {
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
  void _abandonReplacementPendings(
    bool Function(_PendingCommand pending) matches,
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
    if (_resubscribed) return;
    _resubscribed = true;
    final sessionId = _desiredSessionId ?? _state.activeSessionId;
    if (sessionId == null) return;
    // `_subscribe` re-subscribes and re-requests history. Requesting it again
    // here would send a duplicate frame.
    _subscribe(sessionId, restoring: true);
  }

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

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
        _state.status == HubConnectionStatus.authenticating;
    _cancelAuthWatchdog();
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
    _failPending('connection lost', skipReplacement: true);
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
    if (wasAuthenticating && _state.lastError == null) {
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
      // A frame-handling fault is a protocol/logic bug, not a connection
      // failure; reconnecting will not fix it, so it must outlive one.
      _setError('$error', connection: false);
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
    }
  }

  /// Surfaces a settle for notification. Deliberately no state change and no
  /// `_scheduleNotify`: it must not rebuild the transcript, and it must reach
  /// the app even for a session it is not viewing or subscribed to.
  void _onAgentSettled(Map<String, Object?> message) {
    if (_settlesController.isClosed) return;
    _settlesController.add(
      AgentSettledEvent(
        sessionId: message['sessionId']! as String,
        label: message['label']! as String,
        text: message['text']! as String,
        truncated: message['truncated']! as bool,
      ),
    );
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
      _setError('could not persist token: $error', connection: false);
      return;
    }
    _markConnected();
    _restoreSubscription();
  }

  void _onSessions(Map<String, Object?> message) {
    _cancelAuthWatchdog();
    final raw = message['sessions']! as List;
    final summaries = raw
        .map(
          (entry) =>
              SessionSummary.fromJson((entry as Map).cast<String, Object?>()),
        )
        .toList();
    // Absent means a hub that predates the field: an empty set, so the folder
    // feature is hidden rather than probed with a frame that would disconnect.
    final rawCapabilities = message['capabilities'];
    final capabilities = rawCapabilities is List
        ? rawCapabilities.whereType<String>().toSet()
        : <String>{};
    _state = _state.copyWith(
      sessions: summaries,
      capabilities: capabilities,
    );
    // The hub pushes `sessions` on authentication; its arrival is how a
    // token-authenticated connection is confirmed (there is no `paired`).
    _markConnected();
    final awaited = _awaitingReplacementFrom;
    if (awaited != null) {
      // A replacement is in flight: adopt its successor and *never* fall back
      // to `_restoreSubscription`, which would re-subscribe the dead id and
      // walk the give-up counter against a session that is deliberately gone.
      SessionSummary? successor;
      for (final summary in summaries) {
        if (summary.replacesSessionId == awaited) {
          successor = summary;
          break;
        }
      }
      if (successor != null) {
        _settleReplacementPendings(awaited);
        _clearReplacementFollow();
        _resubscribed = true;
        // Adoption puts/removes no predecessor transcript, so it must not touch
        // the predecessor derivation: the predecessor's own `session-gone`
        // classifies it (drop or keep) and the derivation follows its
        // transcript there.
        _subscribe(successor.sessionId, restoring: true);
      }
    } else {
      _restoreSubscription();
    }
    // Explicitly, and not left to `_markConnected`: `_setStatus` early-returns
    // when the status is unchanged, so it notifies only on the first push of a
    // connection. Without this line every later registry change (a session
    // registering, dying, or changing agent state) updates the list in memory
    // and never reaches the UI.
    _scheduleNotify();
  }

  void _onEvent(Map<String, Object?> payload) {
    final sessionId = _state.activeSessionId;
    if (sessionId == null) return;
    final transcript =
        _state.transcripts[sessionId] ?? const SessionTranscript();
    switch (payload['kind']) {
      case 'stream':
        final seq = (payload['seq']! as num).toInt();
        final lastSeq = seq > transcript.lastSeq ? seq : transcript.lastSeq;
        final text = payload['text'];
        final isThinking = payload['phase'] == 'thinking';
        if (text is String && isThinking) {
          // Reasoning streams like the reply but into its own buffer, so the
          // two can never be confused on the wire or on screen.
          _putTranscript(
            sessionId,
            transcript.copyWith(
              streamingThinking: transcript.streamingThinking + text,
              thinking: true,
              lastSeq: lastSeq,
            ),
          );
        } else if (text is String) {
          _putTranscript(
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
          _putTranscript(
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
        _putTranscript(
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
        _putTranscript(
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
        _putTranscript(
          sessionId,
          _withEntries(sessionId, transcript, message).copyWith(
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
          _putTranscript(
            sessionId,
            transcript.copyWith(compacting: payload['active'] == true),
          );
          break;
        }
        // Any other `status` is relayed raw so the renderer can decide. An error
        // status ends the turn without a settle, so clear the thinking phase
        // here or `Thinking…` would stick forever.
        final isErrorStatus = payload['event'] == 'error';
        _putTranscript(
          sessionId,
          _withEntries(sessionId, transcript, payload).copyWith(
            thinking: isErrorStatus ? false : transcript.thinking,
            streamingThinking: isErrorStatus ? '' : transcript.streamingThinking,
          ),
        );
      case 'tool':
        // A bridge-normalized tool annotation: retained raw in `entries`, where
        // the transcript model pairs its view to the call/result row. Appended
        // in arrival order, like any other entry.
        _putTranscript(
          sessionId,
          _withEntries(sessionId, transcript, payload),
        );
      case 'leaf':
        // The bridge moved the leaf (or pi did, on the PC). A signal, not a row:
        // re-request history so the transcript re-baselines to the new branch,
        // and announce the move so the shell can settle a pending tree tap.
        if (!_leafEventsController.isClosed) {
          _leafEventsController.add(
            LeafEvent(
              sessionId: sessionId,
              leafId: payload['leafId'] as String?,
            ),
          );
        }
        requestHistory(sessionId);
      default:
        // An unknown payload is retained rather than dropped, so a future
        // renderer can consume it; nothing in this build does.
        _putTranscript(
          sessionId,
          _withEntries(sessionId, transcript, payload),
        );
    }
    _scheduleNotify();
  }

  void _onSnapshot(Map<String, Object?> message) {
    final sessionId = message['sessionId']! as String;
    // Routing fields first: a discarded frame must not be decoded (round 2's
    // missed edge), so `entries` is only touched on an apply path.
    final token = message['cursor'] as String?;
    final older = message['older'] == true;
    final olderCursor = message['olderCursor'] as String?;

    if (older) {
      final existing = _state.transcripts[sessionId];
      // Apply only the page this session actually asked for. Anything else — an
      // absent token, a stale one, or no transcript — is discarded touching
      // nothing, so a stale page cannot reset the resync livelock streak (R5)
      // nor fabricate a baseline.
      if (token == null ||
          _pendingHistoryCursor[sessionId] != token ||
          existing == null) {
        return;
      }
      _pendingHistoryCursor.remove(sessionId);
      _cancelHistoryPageTimeout(sessionId);
      _resyncCounts.remove(sessionId);
      _sessionGoneCounts.remove(sessionId);
      final entries = (message['entries']! as List).cast<Object?>();
      // Prepend through the session's own derivation. `copyWith` carries the
      // in-flight stream and every ambient field across (design D + fact 13);
      // the lists are copied so a retained snapshot is a true value.
      final derivation = _derivations[sessionId]!;
      derivation.rebuild([...entries, ...existing.entries]);
      _putTranscript(
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
      _scheduleNotify();
      return;
    }

    // No `older` flag is the newest-page baseline: a REPLACE that also
    // invalidates any page in flight for this session.
    _pendingHistoryCursor.remove(sessionId);
    _cancelHistoryPageTimeout(sessionId);
    // A delivered baseline breaks any resync or gone streak.
    _resyncCounts.remove(sessionId);
    _sessionGoneCounts.remove(sessionId);
    final entries = (message['entries']! as List).cast<Object?>();
    final derivation = TranscriptDerivation()..rebuild(entries);
    _derivations[sessionId] = derivation;
    _putTranscript(
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
        contextUsage: _state.transcripts[sessionId]?.contextUsage,
        thinkingLevel: _state.transcripts[sessionId]?.thinkingLevel,
        currentModel: _state.transcripts[sessionId]?.currentModel,
        compacting: _state.transcripts[sessionId]?.compacting ?? false,
      ),
    );
    _scheduleNotify();
  }

  /// A listing's rejection (an invalid path, a trust-store fault) arrives as a
  /// `command-result` carrying the listing's id, so listings are consulted
  /// first: the id spaces are disjoint by construction, but the routing order
  /// is the guarantee. A listing failure never carries `ok:true`.
  void _onCommandResult(Map<String, Object?> message) {
    final id = message['id']! as String;
    final listing = _pendingListings.remove(id);
    if (listing != null) {
      if (listing.completer.isCompleted) return;
      listing.timer?.cancel();
      listing.completer.complete(
        DirListingResult(ok: false, error: message['error'] as String?),
      );
      return;
    }
    final pending = _pendingCommands[id];
    if (pending == null || pending.completer.isCompleted) return;
    if (pending.followsReplacement) {
      // A successful ack is not the witness — the successor's registration is.
      // Leave the pending and the follow armed so adoption settles it.
      if (message['ok']! as bool) return;
      // A refused replacement will never produce a successor: fail the caller
      // and disarm the follow. Left armed with no pending to settle, it would
      // suppress every legitimate restore for 15 s, and a `session-gone` for
      // the id would skip the re-arm.
      _pendingCommands.remove(id);
      pending.timer?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.complete(
          CommandResult(ok: false, error: message['error'] as String?),
        );
      }
      if (_awaitingReplacementFrom == pending.sessionId &&
          !_pendingCommands.values.any(
            (other) =>
                other.followsReplacement &&
                other.sessionId == pending.sessionId,
          )) {
        _clearReplacementFollow();
      }
      return;
    }
    _pendingCommands.remove(id);
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
    final pending = _pendingListings.remove(id);
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
    final count = (_resyncCounts[sessionId] ?? 0) + 1;
    _resyncCounts[sessionId] = count;
    if (count > _maxConsecutiveResyncs) {
      // Re-requesting forever is the livelock; stop and surface it instead.
      _setError(
        'gave up resyncing $sessionId after $_maxConsecutiveResyncs attempts',
        connection: false,
      );
      return;
    }
    requestHistory(sessionId);
  }

  void _onSessionGone(String sessionId) {
    _resyncCounts.remove(sessionId);
    final count = (_sessionGoneCounts[sessionId] ?? 0) + 1;
    _sessionGoneCounts[sessionId] = count;
    final gaveUp = count > _maxConsecutiveSessionGone;
    // The awaited session vanishing is the replacement's first witness: the
    // session is meant to be gone, so its pending is settled rather than
    // failed, and the follow stays armed until the successor names it (or the
    // follow times out). `_resubscribed` is deliberately left alone — the
    // successor's push must not lose to a restore of the dead id.
    final awaiting = _awaitingReplacementFrom == sessionId;
    if (awaiting) _settleReplacementPendings(sessionId);
    // A `session-gone` answering an automatic restore is the re-subscribe
    // racing the agent's re-registration; only once the cap is past — or when
    // the user subscribed directly and the session is simply gone — is the
    // transcript genuinely obsolete.
    final keepTranscript = !gaveUp && _restoredSessions.contains(sessionId);
    if (gaveUp) {
      // The session is genuinely gone. Re-arming again would resend
      // subscribe+history on every registry push forever, so clear the desired
      // session and say so rather than looping silently.
      _restoredSessions.remove(sessionId);
      if (_desiredSessionId == sessionId) _desiredSessionId = null;
    } else if (!awaiting && _desiredSessionId == sessionId) {
      // A gone session may come back (an agent restart, or a re-subscribe that
      // raced the agent's re-registration): drop the one-shot guard so the next
      // `sessions` push re-attaches to the session the user was viewing.
      _resubscribed = false;
    }
    _failPending('session gone', sessionId: sessionId);
    final sessions = _state.sessions
        .where((summary) => summary.sessionId != sessionId)
        .toList();
    final transcripts = {..._state.transcripts};
    if (!keepTranscript) {
      transcripts.remove(sessionId);
      _derivations.remove(sessionId);
      _pendingHistoryCursor.remove(sessionId);
      _cancelHistoryPageTimeout(sessionId);
    }
    // Only the genuinely-gone branch drops the cache: under the cap the session
    // may come back (the re-subscribe race), and a kept key avoids a flicker.
    final commands = gaveUp
        ? ({..._state.commands}..remove(sessionId))
        : _state.commands;
    _state = _state.copyWith(
      sessions: sessions,
      transcripts: transcripts,
      commands: commands,
      activeSessionId: _state.activeSessionId == sessionId
          ? null
          : _state.activeSessionId,
    );
    if (gaveUp) {
      _setError(
        'the session $sessionId is gone; pick another session to view',
        connection: false,
      );
    } else {
      _scheduleNotify();
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
      _setError('$error', connection: true);
      return error;
    }
  }

  void _ensureTranscript(String sessionId) {
    if (_state.transcripts.containsKey(sessionId)) return;
    _putTranscript(sessionId, const SessionTranscript());
  }

  /// Extends [transcript]'s session by [entry] through that session's
  /// derivation instead of re-deriving the whole list. Returns a transcript
  /// holding *copies* of the derivation's lists, so a retained old transcript
  /// can never observe a later append. `transcript.entries` is consulted only
  /// when the derivation is missing or does not match the incoming baseline.
  SessionTranscript _withEntries(
    String sessionId,
    SessionTranscript transcript,
    Object? entry,
  ) {
    var derivation = _derivations[sessionId];
    if (derivation == null ||
        !_matchesDerivation(derivation, transcript.entries)) {
      derivation = TranscriptDerivation()..rebuild(transcript.entries);
      _derivations[sessionId] = derivation;
    }
    derivation.append(entry);
    return transcript.copyWith(
      entries: List<Object?>.of(derivation.entries),
      blocks: List<TranscriptBlock>.of(derivation.blocks),
    );
  }

  /// Cheap staleness net. Under design D the transcript always holds a fresh
  /// copy, so `identical(entries)` is useless; the copy preserves element
  /// *objects*, so tail identity plus length detects a replaced baseline. The
  /// primary mechanism is explicit invalidation at every replacement point
  /// (snapshot, the `session-gone` drop branch, `disconnect`, `stop`); this
  /// catches a path that did not. It cannot see a same-length, same-tail
  /// interior change — no current path produces one, and any future one must
  /// invalidate explicitly.
  bool _matchesDerivation(TranscriptDerivation d, List<Object?> entries) {
    if (d.entries.length != entries.length) return false;
    if (entries.isEmpty) return true;
    return identical(d.entries.last, entries.last);
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

  /// Records a user-visible error and whether a later authenticated connection
  /// supersedes it. Dial, auth and send failures are connection-scoped; session
  /// and operation notices are not.
  void _setError(String message, {required bool connection}) {
    _lastErrorFromConnection = connection;
    _state = _state.copyWith(lastError: message);
    _scheduleNotify();
  }

  /// Clears a connection-scoped error, leaving a session/operation notice where
  /// it is: a new dial does not fix a session that is gone or a token that would
  /// not persist. Called when a new deliberate attempt starts, so a stale
  /// failure cannot outlive the attempt that recorded it.
  void _clearConnectionError() {
    if (!_lastErrorFromConnection) return;
    _lastErrorFromConnection = false;
    _state = _state.copyWith(lastError: null);
    _scheduleNotify();
  }

  /// Called once a connection is authenticated. A stale connection error is
  /// cleared; a session/operation notice is left exactly where it was.
  void _markConnected() {
    _clearConnectionError();
    _setStatus(HubConnectionStatus.connected);
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
