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
/// The behaviour is split across four `part` files of this library, each a
/// private collaborator holding a back-reference to [HubClient]:
/// `hub_client_connection.dart` (dial, race, auth, timers),
/// `hub_client_routing.dart` (inbound frames), `hub_client_requests.dart`
/// (commands and results), and `hub_client_history.dart` (history paging).
/// Every mutable field stays on [HubClient]; the parts read and write them
/// directly.
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
import 'backoff.dart';
import 'endpoint_store.dart';
import 'hub_socket.dart';
import 'scheduler.dart';
import 'token_store.dart';
import 'context_usage.dart';
import 'transcript.dart';
import 'hub_client_view.dart';
export 'hub_models.dart';

part 'hub_client_history.dart';
part 'hub_client_requests.dart';
part 'hub_client_routing.dart';
part 'hub_client_connection.dart';

/// The close code the hub sends for a capability violation. Retrying a bridge
/// bug at capped backoff would reconnect forever, so this one never reconnects.
const int closeCapability = 4003;

/// The close code the hub sends when the credential attempt cap is reached.
const int closeRateLimited = 4008;

/// The fixed wait after a `4008` close. The hub delayed that close on purpose;
/// retrying sooner would only add load.
const Duration rateLimitedReconnectDelay = Duration(milliseconds: 30000);

class HubClient implements HubClientView {
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

  // Collaborators. Each holds a back-reference to this client and touches its
  // (library-private) fields directly; every mutable field stays here. See the
  // part files for the view each one uses.
  late final _HubHistory _history = _HubHistory(this);
  late final _HubRequests _requests = _HubRequests(this);
  late final _HubRouter _router = _HubRouter(this);
  late final _HubConnection _connection = _HubConnection(this);

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
  @override
  HubClientState get state => _state;

  /// Whether [state]'s [HubClientState.lastError] came from the connection path
  /// (dial, auth, send) rather than a session/operation. A new deliberate dial
  /// clears a connection-scoped error and leaves a session notice alone.
  @override
  bool get lastErrorFromConnection => _lastErrorFromConnection;

  /// Coalesced notifications: at most one per scheduled frame, regardless of how
  /// many deltas arrived.
  @override
  Stream<HubClientState> get changes => _changesController.stream;

  /// Settle notifications: one event per `agent-settled` frame the hub sends,
  /// regardless of which session is active. Broadcast, so several listeners are
  /// possible; it closes with [stop], never with [disconnect].
  @override
  Stream<AgentSettledEvent> get settles => _settlesController.stream;

  /// Leaf moves: one event per `leaf` frame, carrying the session it is
  /// attributed to and the new leaf id (`null` for the root). Broadcast, so
  /// several listeners are possible; it closes with [stop], never with
  /// [disconnect].
  @override
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
  @override
  Future<void> startCandidates(
    List<HubEndpoint> candidates, {
    String? ticket,
    HubEndpoint? prefer,
  }) => _connection.startCandidates(candidates, ticket: ticket, prefer: prefer);

  /// Stops reconnecting, closes the socket, and closes [changes].
  Future<void> stop() => _connection.stop();

  /// Like [stop], but leaves [changes] open so the app can point at a different
  /// hub and [start] again. Resets the client to its initial snapshot.
  ///
  /// [stop] closes [changes] forever, so it cannot be used to change hubs.
  Future<void> disconnect() => _connection.disconnect();

  /// Subscribes to [sessionId], makes it the session events are attributed to,
  /// and requests its history so the prior conversation is visible on open.
  ///
  /// Relayed `event` frames carry no `sessionId`, so the client can only
  /// attribute them to the session it is currently viewing.
  @override
  void subscribe(String sessionId) {
    // Picking a session is an explicit navigation: a replacement follow for a
    // different session must not later yank the user onto its successor. Clear
    // it and fail the caller, whose witness can no longer arrive.
    final awaited = _awaitingReplacementFrom;
    if (awaited != null && awaited != sessionId) {
      _requests._clearReplacementFollow();
      _requests._abandonReplacementPendings(
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
      _requests._trySend({
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
    _requests._trySend({
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

  @override
  void unsubscribe(String sessionId) {
    // Unsubscribing the awaited id abandons the replacement it was waiting on.
    if (_awaitingReplacementFrom == sessionId) {
      _requests._clearReplacementFollow();
      _requests._abandonReplacementPendings(
        (pending) => pending.sessionId == sessionId,
        'superseded',
      );
    }
    _requests._trySend({
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
  Object? requestHistory(String sessionId, {int? sinceSeq, String? cursor}) =>
      _history.requestHistory(sessionId, sinceSeq: sinceSeq, cursor: cursor);

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
  @override
  void loadOlder(String sessionId) => _history.loadOlder(sessionId);

  /// Sends one allowlisted command and completes when its `command-result`
  /// arrives. The correlation id is generated here unless [id] is supplied.
  @override
  Future<CommandResult> sendCommand(
    String sessionId,
    String name, {
    Map<String, Object?>? args,
    String? id,
  }) => _requests.sendCommand(sessionId, name, args: args, id: id);

  /// Asks the hub for [sessionId]'s real pi commands and completes with them.
  ///
  /// Routed through [_request] so the result correlates like any other command
  /// and `session-gone` can fail it; the cache write is [loadCommands]'s.
  Future<CommandResult> listCommands(String sessionId, {String? id}) =>
      _requests.listCommands(sessionId, id: id);

  /// Asks the hub for pi's auth-configured models and completes with them.
  ///
  /// The picker is a one-shot, not a per-keystroke list, so nothing is cached
  /// here — unlike [listCommands].
  @override
  Future<CommandResult> listModels(String sessionId, {String? id}) =>
      _requests.listModels(sessionId, id: id);

  /// Asks the hub for [sessionId]'s session tree as a flat, bounded node list.
  ///
  /// A `/fork` picks its fork point from this list; the tree carries only user
  /// and assistant messages, already relinked to their nearest emitted
  /// ancestor.
  @override
  Future<CommandResult> listTree(String sessionId, {String? id}) =>
      _requests.listTree(sessionId, id: id);

  /// Asks pi to replace [sessionId] with a fresh session, in place.
  ///
  /// The ack only means the bridge accepted the command; success is the
  /// replacement itself, so the returned future is settled by the successor's
  /// registration (or by the old session's `session-gone` while the follow is
  /// armed), never by the ack. The follow fails after [_replacementTimeout].
  @override
  Future<CommandResult> sessionNew(String sessionId, {String? id}) =>
      _requests.sessionNew(sessionId, id: id);

  /// Asks pi to fork [sessionId] at [entryId], replacing it in place. Same
  /// replacement-follow contract as [sessionNew].
  @override
  Future<CommandResult> sessionFork(
    String sessionId,
    String entryId, {
    String? id,
  }) => _requests.sessionFork(sessionId, entryId, id: id);

  /// Asks pi to move [sessionId]'s leaf to [entryId], in place.
  ///
  /// A navigation does not replace the session, so this is a plain request: the
  /// ack settles it. The re-baseline is the bridge's separate `leaf` event, not
  /// a history request issued here.
  @override
  Future<CommandResult> sessionTree(
    String sessionId,
    String entryId, {
    String? id,
  }) => _requests.sessionTree(sessionId, entryId, id: id);

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
  @override
  Future<void> loadCommands(String sessionId) =>
      _requests.loadCommands(sessionId);

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
  @override
  Future<CommandResult> startSession({String? id, String? cwd, bool? trust}) =>
      _requests.startSession(id: id, cwd: cwd, trust: trust);

  /// Lists the directories under the hub's browse root, or under [path] when
  /// given. A null or empty [path] means the root.
  ///
  /// Refuses locally without the hub's `list-dirs` capability: an old hub takes
  /// an unknown viewer type as a capability violation and closes `4003`, which
  /// this client treats as terminal (no reconnect). The id is namespaced
  /// `dirs-N`, distinct from `_request`'s `cmd-N`.
  @override
  Future<DirListingResult> listDirs({String? path, String? id}) =>
      _requests.listDirs(path: path, id: id);

  /// Asks the hub to kill an app-started session. Same empty-session pending
  /// convention as [startSession].
  @override
  Future<CommandResult> killSession(String sessionId, {String? id}) =>
      _requests.killSession(sessionId, id: id);

  // ---------------------------------------------------------------------------
  // Outbound + state plumbing
  // ---------------------------------------------------------------------------

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
