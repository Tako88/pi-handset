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
/// The behaviour is split across collaborators: `hub_connection.dart`
/// (dial, race, auth, timers) owns the socket/credential/timer cluster;
/// `hub_router.dart` (inbound frames) receives a `RouterContext`; the
/// separate libraries `pending_registry.dart` (pending-command/listing
/// bookkeeping), `hub_commands.dart` (the request builders) and
/// `history_pages.dart` (history paging) are handed their dependencies. The
/// state they share is owned by `SessionStateStore`.
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
import 'hub_commands.dart';
import 'history_pages.dart';
import 'hub_connection.dart';
import 'hub_router.dart';
import 'hub_socket.dart';
import 'pending_registry.dart';
import 'scheduler.dart';
import 'token_store.dart';
import 'notify_coalescer.dart';
import 'session_state.dart';
import 'hub_client_view.dart';
export 'close_codes.dart';
export 'hub_models.dart';

/// Consecutive `resync-required` answers a session may provoke before the
/// client stops re-requesting and surfaces an error. A resync whose snapshot is
/// itself dropped would otherwise loop forever.
const int _maxConsecutiveResyncs = 3;

/// Consecutive `session-gone` answers a session may provoke before the client
/// stops re-subscribing and surfaces an error. Under the cap a rejection re-arms
/// the re-subscribe (which recovers the race the M10b fix targeted); past it the
/// session is genuinely gone and retrying forever only churns the registry.
const int _maxConsecutiveSessionGone = 3;

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

  /// The single writer of the state the client and its collaborators own.
  late final SessionStateStore _store = SessionStateStore();

  /// Coalesces the state notifications the client emits on [changes].
  late final NotifyCoalescer _notify = NotifyCoalescer(
    scheduler: _scheduler,
    interval: _frameInterval,
    current: () => _store.state,
    emit: (state) {
      if (!_changesController.isClosed) _changesController.add(state);
    },
  );

  /// In-flight command/listing bookkeeping and the replacement follow.
  late final PendingRegistry _pending = PendingRegistry(
    scheduler: _scheduler,
    store: _store,
    isConnected: _isConnected,
    trySend: _trySend,
  );

  /// The request builders the public API delegates to.
  late final CommandSender _commands = CommandSender(
    store: _store,
    pending: _pending,
    notify: _notify,
  );

  /// History paging: the single-flight older-page request and its bounded wait.
  late final HistoryPages _historyPages = HistoryPages(
    scheduler: _scheduler,
    store: _store,
    notify: _notify,
    isConnected: _isConnected,
    trySend: _trySend,
  );

  /// Connection: dial (single and raced), adopt, authenticate, and the timers
  /// that bound and recover an attempt. Declared after the collaborators it is
  /// handed, and before the router context, whose seams forward to it.
  late final HubConnection _connection = HubConnection(
    socketFactory: _socketFactory,
    scheduler: _scheduler,
    tokenStore: _tokenStore,
    rng: _rng,
    store: _store,
    pending: _pending,
    historyPages: _historyPages,
    onFrame: _onFrame,
    setStatus: _setStatus,
    setError: _setError,
    clearConnectionError: _clearConnectionError,
    flushNotify: _flushNotify,
    closeControllers: _closeControllers,
    subscribe: _subscribe,
  );

  /// The collaborators and seams the routing functions write through. Built
  /// last, after every collaborator it names exists.
  late final RouterContext _routerContext = RouterContext(
    store: _store,
    pending: _pending,
    historyPages: _historyPages,
    notify: _notify,
    subscribe: _subscribe,
    markConnected: _markConnected,
    setError: _setError,
    cancelAuthWatchdog: _cancelAuthWatchdog,
    restoreSubscription: _restoreSubscription,
    persistToken: _persistToken,
    emitSettled: _emitSettled,
    emitLeaf: _emitLeaf,
    resyncCap: HubClient.maxConsecutiveResyncs,
    goneCap: HubClient.maxConsecutiveSessionGone,
  );

  final StreamController<HubClientState> _changesController =
      StreamController<HubClientState>.broadcast(sync: true);

  final StreamController<AgentSettledEvent> _settlesController =
      StreamController<AgentSettledEvent>.broadcast(sync: true);

  final StreamController<LeafEvent> _leafEventsController =
      StreamController<LeafEvent>.broadcast(sync: true);

  /// The current snapshot.
  @override
  HubClientState get state => _store.state;

  /// Whether [state]'s [HubClientState.lastError] came from the connection path
  /// (dial, auth, send) rather than a session/operation. A new deliberate dial
  /// clears a connection-scoped error and leaves a session notice alone.
  @override
  bool get lastErrorFromConnection => _store.lastErrorFromConnection;

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
      _store.transcript(sessionId);

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
    final awaited = _pending.awaitingReplacementFrom;
    if (awaited != null && awaited != sessionId) {
      _pending.clearReplacementFollow();
      _pending.abandonReplacement(
        (pending) => pending.sessionId == awaited,
        'superseded',
      );
    }
    // A user picking a session is a fresh start: a gone streak from an earlier
    // automatic retry must not count against it.
    _store.removeGoneCount(sessionId);
    _subscribe(sessionId);
  }

  /// The shared body of [subscribe]. The automatic restore after a
  /// `session-gone` reuses it *without* clearing the gone counter, so
  /// consecutive rejections accumulate to the give-up cap.
  void _subscribe(String sessionId, {bool restoring = false}) {
    final previous = _store.state.activeSessionId;
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
    _store.removeResyncCount(sessionId);
    _store.desiredSessionId = sessionId;
    _store.setRestored(sessionId, restoring);
    _store.ensureTranscript(sessionId);
    _store.update((state) => state.copyWith(activeSessionId: sessionId));
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

  @override
  void unsubscribe(String sessionId) {
    // Unsubscribing the awaited id abandons the replacement it was waiting on.
    if (_pending.awaitingReplacementFrom == sessionId) {
      _pending.clearReplacementFollow();
      _pending.abandonReplacement(
        (pending) => pending.sessionId == sessionId,
        'superseded',
      );
    }
    _trySend({
      'protocolVersion': protocolVersion,
      'type': 'unsubscribe',
      'sessionId': sessionId,
    });
    if (_store.desiredSessionId == sessionId) _store.desiredSessionId = null;
    if (_store.state.activeSessionId == sessionId) {
      _store.update((state) => state.copyWith(activeSessionId: null));
      _scheduleNotify();
    }
  }

  /// Sends a `history-request`. The hub answers with a `snapshot`.
  ///
  /// Returns the send error (`null` when the frame went out), so [loadOlder]
  /// can clear its in-flight state when the write failed. [cursor] is the older
  /// page's opaque token and is placed on the frame only when non-null.
  Object? requestHistory(String sessionId, {int? sinceSeq, String? cursor}) =>
      _historyPages.requestHistory(sessionId, sinceSeq: sinceSeq, cursor: cursor);

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
  void loadOlder(String sessionId) => _historyPages.loadOlder(sessionId);

  /// Sends one allowlisted command and completes when its `command-result`
  /// arrives. The correlation id is generated here unless [id] is supplied.
  @override
  Future<CommandResult> sendCommand(
    String sessionId,
    String name, {
    Map<String, Object?>? args,
    String? id,
  }) => _commands.sendCommand(sessionId, name, args: args, id: id);

  /// Asks the hub for [sessionId]'s real pi commands and completes with them.
  ///
  /// Routed through [PendingRegistry.command] so the result correlates like any
  /// other command and `session-gone` can fail it; the cache write is
  /// [loadCommands]'s.
  Future<CommandResult> listCommands(String sessionId, {String? id}) =>
      _commands.listCommands(sessionId, id: id);

  /// Asks the hub for pi's auth-configured models and completes with them.
  ///
  /// The picker is a one-shot, not a per-keystroke list, so nothing is cached
  /// here — unlike [listCommands].
  @override
  Future<CommandResult> listModels(String sessionId, {String? id}) =>
      _commands.listModels(sessionId, id: id);

  /// Asks the hub for [sessionId]'s session tree as a flat, bounded node list.
  ///
  /// A `/fork` picks its fork point from this list; the tree carries only user
  /// and assistant messages, already relinked to their nearest emitted
  /// ancestor.
  @override
  Future<CommandResult> listTree(String sessionId, {String? id}) =>
      _commands.listTree(sessionId, id: id);

  /// Asks pi to replace [sessionId] with a fresh session, in place.
  ///
  /// The ack only means the bridge accepted the command; success is the
  /// replacement itself, so the returned future is settled by the successor's
  /// registration (or by the old session's `session-gone` while the follow is
  /// armed), never by the ack. The follow fails after `_replacementTimeout`.
  @override
  Future<CommandResult> sessionNew(String sessionId, {String? id}) =>
      _commands.sessionNew(sessionId, id: id);

  /// Asks pi to fork [sessionId] at [entryId], replacing it in place. Same
  /// replacement-follow contract as [sessionNew].
  @override
  Future<CommandResult> sessionFork(
    String sessionId,
    String entryId, {
    String? id,
  }) => _commands.sessionFork(sessionId, entryId, id: id);

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
  }) => _commands.sessionTree(sessionId, entryId, id: id);

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
      _commands.loadCommands(sessionId);

  /// Asks the hub to spawn a headless app-started session.
  ///
  /// The hub answers directly to this connection; there is no session to key
  /// the pending result into, so it is registered under the empty-session
  /// convention ([PendingRegistry.command]'s `sessionId`) and a `session-gone` for any
  /// session cannot fail it.
  ///
  /// With a [cwd] or [trust] this needs the hub's `project-session` capability:
  /// an old hub would silently ignore the field and temp-spawn, so without it
  /// the call is refused locally and no frame is sent. `trust` is a
  /// project-session-era field too — the hub validates it alongside `cwd` — so
  /// it is only ever sent together with `cwd`.
  @override
  Future<CommandResult> startSession({String? id, String? cwd, bool? trust}) =>
      _commands.startSession(id: id, cwd: cwd, trust: trust);

  /// Lists the directories under the hub's browse root, or under [path] when
  /// given. A null or empty [path] means the root.
  ///
  /// Refuses locally without the hub's `list-dirs` capability: an old hub takes
  /// an unknown viewer type as a capability violation and closes `4003`, which
  /// this client treats as terminal (no reconnect). The id is namespaced
  /// `dirs-N`, distinct from [PendingRegistry.command]'s `cmd-N`.
  @override
  Future<DirListingResult> listDirs({String? path, String? id}) =>
      _commands.listDirs(path: path, id: id);

  /// Asks the hub to kill an app-started session. Same empty-session pending
  /// convention as [startSession].
  @override
  Future<CommandResult> killSession(String sessionId, {String? id}) =>
      _commands.killSession(sessionId, id: id);

  // ---------------------------------------------------------------------------
  // Outbound + state plumbing
  // ---------------------------------------------------------------------------

  /// Whether a live socket is adopted. Kept a method (not a closure over the
  /// connection's socket) so its body can forward to `HubConnection` without
  /// the collaborator's tear-off changing.
  bool _isConnected() => _connection.isConnected;

  /// Sends [message] through the connection, converting the synchronous throw
  /// of a closing socket into a recorded error rather than letting it escape
  /// into the UI. Returns the thrown error, or null when the frame went out.
  Object? _trySend(Map<String, Object?> message) =>
      _connection.trySend(message);

  /// Persists a `paired` token. The credential is set synchronously, before the
  /// write is awaited: later reconnects authenticate with the token, not the
  /// spent ticket, and a frame arriving during the await already sees it.
  Future<void> _persistToken(String token) async {
    _connection.credential = {'token': token};
    await _tokenStore.write(token);
  }

  /// Emits a settle event for notification, unless [settles] has closed.
  void _emitSettled(AgentSettledEvent event) {
    if (!_settlesController.isClosed) _settlesController.add(event);
  }

  /// Emits a leaf move, unless [leafEvents] has closed.
  void _emitLeaf(LeafEvent event) {
    if (!_leafEventsController.isClosed) _leafEventsController.add(event);
  }

  /// Routes one inbound frame. A method (not a direct call) so the connection
  /// collaborator's tear-off survives the router moving out of this library.
  void _onFrame(Object? frame) => handleInboundFrame(frame, _routerContext);

  void _setStatus(HubConnectionStatus status) {
    if (_store.state.status == status) return;
    _store.update((state) => state.copyWith(status: status));
    _scheduleNotify();
  }

  /// Records a user-visible error and whether a later authenticated connection
  /// supersedes it. Dial, auth and send failures are connection-scoped; session
  /// and operation notices are not.
  void _setError(String message, {required bool connection}) {
    _store.setError(message, connection: connection);
    _scheduleNotify();
  }

  /// Clears a connection-scoped error, leaving a session/operation notice where
  /// it is: a new dial does not fix a session that is gone or a token that would
  /// not persist. Called when a new deliberate attempt starts, so a stale
  /// failure cannot outlive the attempt that recorded it.
  void _clearConnectionError() {
    if (_store.clearConnectionError()) _scheduleNotify();
  }

  /// Called once a connection is authenticated. A stale connection error is
  /// cleared; a session/operation notice is left exactly where it was.
  void _markConnected() {
    _clearConnectionError();
    _setStatus(HubConnectionStatus.connected);
  }

  /// Cancels the authentication watchdog of the current attempt. A seam so the
  /// router's tear-off survives the body moving to `HubConnection`.
  void _cancelAuthWatchdog() => _connection.cancelAuthWatchdog();

  /// Restores the previous connection's subscription once authenticated. A
  /// seam so the router's tear-off survives the body moving to `HubConnection`.
  void _restoreSubscription() => _connection.restoreSubscription();

  void _scheduleNotify() => _notify.schedule();

  /// Emits the current state immediately, cancelling any coalescing wait. Used
  /// where a terminal state must be observed before [changes] closes.
  void _flushNotify() => _notify.flush();

  /// Closes [changes], [settles] and [leafEvents] unless already closed.
  Future<void> _closeControllers() async {
    if (!_changesController.isClosed) await _changesController.close();
    if (!_settlesController.isClosed) await _settlesController.close();
    if (!_leafEventsController.isClosed) await _leafEventsController.close();
  }
}
