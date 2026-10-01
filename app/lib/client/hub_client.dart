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
import 'context_usage.dart';
import 'transcript.dart';

/// Where the connection is in its lifecycle.
enum HubConnectionStatus { disconnected, connecting, authenticating, connected }

/// One entry in the hub's `sessions` push. Deliberately no `lastSeq`.
class SessionSummary {
  final String sessionId;
  final String label;
  final String agentState;

  /// Who started the session: `'app'` (the hub spawned it) or `'pc'`. Defaults
  /// to `'pc'` so a hub that predates the field never strands a viewer.
  final String origin;

  const SessionSummary({
    required this.sessionId,
    required this.label,
    required this.agentState,
    this.origin = 'pc',
  });

  factory SessionSummary.fromJson(Map<String, Object?> json) => SessionSummary(
    sessionId: json['sessionId']! as String,
    label: json['label']! as String,
    agentState: json['agentState']! as String,
    origin: json['origin'] as String? ?? 'pc',
  );
}

/// One `agent-settled` broadcast: a session settled and the app may notify.
/// Viewer-scoped rather than subscriber-scoped, so it may name a session the
/// client is not viewing. Carries the bridge's snippet and its truncation flag.
class AgentSettledEvent {
  final String sessionId;
  final String label;
  final String text;
  final bool truncated;

  const AgentSettledEvent({
    required this.sessionId,
    required this.label,
    required this.text,
    required this.truncated,
  });
}

/// The renderer-agnostic transcript for one session.
///
/// [entries] hold raw relayed values exactly as they arrived (history/snapshot
/// entries, relayed `message` bodies, and raw `status`/`tool` payloads), so the
/// UI layer can decide how to render them. Markdown, if it is ever rendered, is
/// a UI decision this type does not make.
class SessionTranscript {
  final List<Object?> entries;

  /// The ordered display blocks derived from [entries]. Recomputed only when
  /// entries change — never per stream delta.
  final List<TranscriptBlock> blocks;

  /// Text accumulated from `stream` deltas since the last baseline.
  final String streamingText;

  /// Reasoning accumulated from `phase: 'thinking'` stream deltas since the last
  /// baseline. Kept separate from [streamingText] so a reasoning chunk can never
  /// be mistaken for the reply. Only the committed assistant message retires it
  /// mid-turn — a settle, an error status or a snapshot also clears it as
  /// teardown, exactly as they clear the reply buffer.
  final String streamingThinking;

  /// True while deltas are being appended; cleared on `agent_settled` (the
  /// protocol's terminal state), never on a message-level completion.
  final bool streaming;

  /// True while the bridge has signalled the thinking phase and no text has
  /// streamed yet. Set by a content-free `stream` phase frame.
  final bool thinking;

  final String agentState;
  final int lastSeq;
  final bool historyLoaded;
  final bool truncated;

  /// The model's context usage for this session, or null while the bridge has
  /// not reported one. Ambient state rather than a transcript row: it is
  /// rendered in the app bar, never in the message list.
  final ContextUsage? contextUsage;

  const SessionTranscript({
    this.entries = const [],
    this.blocks = const [],
    this.streamingText = '',
    this.streamingThinking = '',
    this.streaming = false,
    this.thinking = false,
    this.agentState = 'idle',
    this.lastSeq = 0,
    this.historyLoaded = false,
    this.truncated = false,
    this.contextUsage,
  });

  SessionTranscript copyWith({
    List<Object?>? entries,
    List<TranscriptBlock>? blocks,
    String? streamingText,
    String? streamingThinking,
    bool? streaming,
    bool? thinking,
    String? agentState,
    int? lastSeq,
    bool? historyLoaded,
    bool? truncated,
    ContextUsage? contextUsage,
  }) => SessionTranscript(
    entries: entries ?? this.entries,
    blocks: blocks ?? this.blocks,
    streamingText: streamingText ?? this.streamingText,
    streamingThinking: streamingThinking ?? this.streamingThinking,
    streaming: streaming ?? this.streaming,
    thinking: thinking ?? this.thinking,
    agentState: agentState ?? this.agentState,
    lastSeq: lastSeq ?? this.lastSeq,
    historyLoaded: historyLoaded ?? this.historyLoaded,
    truncated: truncated ?? this.truncated,
    contextUsage: contextUsage ?? this.contextUsage,
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

  /// The hub's advertised capabilities, read from the post-auth `sessions`
  /// frame. Empty for a hub that predates the field, which hides folder
  /// browsing and its `start-session{cwd}` form rather than sending a frame an
  /// old hub would answer with a terminal `4003` close.
  final Set<String> capabilities;

  const HubClientState({
    this.status = HubConnectionStatus.disconnected,
    this.sessions = const [],
    this.transcripts = const {},
    this.activeSessionId,
    this.lastError,
    this.capabilities = const {},
  });

  HubClientState copyWith({
    HubConnectionStatus? status,
    List<SessionSummary>? sessions,
    Map<String, SessionTranscript>? transcripts,
    Object? activeSessionId = _unset,
    Object? lastError = _unset,
    Set<String>? capabilities,
  }) => HubClientState(
    status: status ?? this.status,
    sessions: sessions ?? this.sessions,
    transcripts: transcripts ?? this.transcripts,
    capabilities: capabilities ?? this.capabilities,
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

/// One directory listing: the resolved directory, the browse root, whether a
/// trust decision exists, whether the directory requires one, its entry names,
/// and whether the cap truncated the listing.
class DirListing {
  final String path;
  final String root;

  /// The nearest trust decision (`true`/`false`), or null when there is none.
  final bool? trust;

  final bool trustRequired;
  final List<String> entries;
  final bool truncated;

  const DirListing({
    required this.path,
    required this.root,
    required this.trust,
    required this.trustRequired,
    required this.entries,
    required this.truncated,
  });
}

/// The outcome of one `list-dirs`: the listing on success, or an error.
class DirListingResult {
  final bool ok;
  final String? error;
  final DirListing? listing;
  const DirListingResult({required this.ok, this.error, this.listing});
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

  HubClientState _state = const HubClientState();
  final Map<String, _PendingCommand> _pendingCommands = {};

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

  /// The current snapshot.
  HubClientState get state => _state;

  /// Coalesced notifications: at most one per scheduled frame, regardless of how
  /// many deltas arrived.
  Stream<HubClientState> get changes => _changesController.stream;

  /// Settle notifications: one event per `agent-settled` frame the hub sends,
  /// regardless of which session is active. Broadcast, so several listeners are
  /// possible; it closes with [stop], never with [disconnect].
  Stream<AgentSettledEvent> get settles => _settlesController.stream;

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
    if (!_settlesController.isClosed) await _settlesController.close();
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
    _desiredSessionId = null;
    _attempt = 0;
    _resyncCounts.clear();
    _sessionGoneCounts.clear();
    _restoredSessions.clear();
    _lastErrorFromConnection = false;
    _state = const HubClientState();
    _flushNotify();
  }

  /// Subscribes to [sessionId], makes it the session events are attributed to,
  /// and requests its history so the prior conversation is visible on open.
  ///
  /// Relayed `event` frames carry no `sessionId`, so the client can only
  /// attribute them to the session it is currently viewing.
  void subscribe(String sessionId) {
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
    _scheduleNotify();
  }

  void unsubscribe(String sessionId) {
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
    Map<String, Object?> Function(String commandId) build,
  ) {
    if (_socket == null) {
      // Dropping the request silently would leave the UI spinning forever.
      return Future.value(
        const CommandResult(ok: false, error: 'not connected'),
      );
    }
    final commandId = id ?? 'cmd-${++_commandCounter}';
    final completer = Completer<CommandResult>();
    final pending = _PendingCommand(pendingSessionId, completer);
    _pendingCommands[commandId] = pending;
    pending.timer = _scheduler.schedule(_commandTimeout, () {
      final removed = _pendingCommands.remove(commandId);
      if (removed == null || removed.completer.isCompleted) return;
      removed.completer.complete(
        const CommandResult(ok: false, error: 'timed out'),
      );
    }, kind: HubTimerKind.command);
    final error = _trySend(build(commandId));
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
    final url = _url;
    if (_stopped || url == null) return;
    _setStatus(HubConnectionStatus.connecting);
    HubSocket socket;
    try {
      socket = await _socketFactory(url);
    } catch (error) {
      _setError('$error', connection: true);
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
    _restoreSubscription();
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
        if (window is num && window > 0) {
          _putTranscript(
            sessionId,
            transcript.copyWith(
              contextUsage: ContextUsage(
                tokens: tokens is num ? tokens.toInt() : null,
                contextWindow: window.toInt(),
              ),
            ),
          );
        }
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
          _withEntries(transcript, [...transcript.entries, message]).copyWith(
            streamingText: fromAssistant ? '' : transcript.streamingText,
            // Cleared in the SAME update that commits the message: the commit
            // carries the reasoning block itself, so a later clear would render
            // the same reasoning twice.
            streamingThinking: fromAssistant ? '' : transcript.streamingThinking,
            streaming: fromAssistant ? false : transcript.streaming,
            thinking: fromAssistant ? false : transcript.thinking,
          ),
        );
      default:
        // `status`/`tool` are relayed raw so the renderer can decide. An error
        // status ends the turn without a settle, so clear the thinking phase
        // here or `Thinking…` would stick forever.
        final isErrorStatus =
            payload['kind'] == 'status' && payload['event'] == 'error';
        _putTranscript(
          sessionId,
          _withEntries(transcript, [...transcript.entries, payload]).copyWith(
            thinking: isErrorStatus ? false : transcript.thinking,
            streamingThinking: isErrorStatus ? '' : transcript.streamingThinking,
          ),
        );
    }
    _scheduleNotify();
  }

  void _onSnapshot(Map<String, Object?> message) {
    final sessionId = message['sessionId']! as String;
    // A delivered baseline breaks any resync or gone streak.
    _resyncCounts.remove(sessionId);
    _sessionGoneCounts.remove(sessionId);
    final entries = (message['entries']! as List).cast<Object?>();
    _putTranscript(
      sessionId,
      SessionTranscript(
        entries: entries,
        blocks: deriveBlocks(entries),
        lastSeq: (message['lastSeq']! as num).toInt(),
        agentState: message['agentState']! as String,
        truncated: message['truncated']! as bool,
        historyLoaded: true,
        // A snapshot re-baselines the transcript, so the usage reading has to be
        // carried across explicitly — and from THIS session's transcript, never
        // from whatever is currently active.
        contextUsage: _state.transcripts[sessionId]?.contextUsage,
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
    } else if (_desiredSessionId == sessionId) {
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
    if (!keepTranscript) transcripts.remove(sessionId);
    _state = _state.copyWith(
      sessions: sessions,
      transcripts: transcripts,
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

  void _failPending(String error, {String? sessionId}) {
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

  /// Replaces [transcript]'s entries and re-derives its blocks in one place, so
  /// a new entry site cannot forget the block model.
  SessionTranscript _withEntries(
    SessionTranscript transcript,
    List<Object?> entries,
  ) => transcript.copyWith(entries: entries, blocks: deriveBlocks(entries));

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

  /// Called once a connection is authenticated. A stale connection error is
  /// cleared; a session/operation notice is left exactly where it was.
  void _markConnected() {
    if (_lastErrorFromConnection) {
      _lastErrorFromConnection = false;
      _state = _state.copyWith(lastError: null);
    }
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
