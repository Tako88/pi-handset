/// The app root.
///
/// Bootstraps from a remembered endpoint (and a token the client already has),
/// then renders pairing, the session list, or the open session's transcript.
/// Everything is driven by the client's coalesced `changes` stream — the widgets
/// never poll and the client owns the state.
///
/// Fully injectable: `main.dart` passes the real socket/scheduler/stores; tests
/// pass fakes, so no test opens a real socket.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../client/endpoint_store.dart';
import '../client/attachment.dart';
import '../client/context_usage.dart';
import '../client/hub_client_view.dart';
import '../client/notification_policy.dart';
import '../client/notification_presenter.dart';
import '../client/settle_notification.dart';
import '../client/token_store.dart';
import '../client/transcript.dart';
import '../platform/qr_scanner.dart';
import '../protocol/protocol.dart';
import 'attachment_actions.dart';
import 'command_suggestions.dart';
import 'compose_bar.dart';
import 'model_actions.dart';
import 'pairing_screen.dart';
import 'session_actions.dart';
import 'session_list.dart';
import 'session_menu.dart';
import 'status_indicator.dart';
import 'theme.dart';
import 'transcript_view.dart';
import 'tree_actions.dart';

class PiDroidApp extends StatefulWidget {
  const PiDroidApp({
    super.key,
    required this.client,
    required this.tokenStore,
    required this.notifications,
    this.initialSessionId,
    this.pickImage,
    this.scanQr = scanPairingQr,
  });

  final HubClientView client;
  final TokenStore tokenStore;

  /// The platform notification surface. `main.dart` passes the real one; tests
  /// pass a fake.
  final NotificationPresenter notifications;

  /// A session to open once authenticated, from a notification tap that cold
  /// started the app, or null for an ordinary launch.
  final String? initialSessionId;

  /// Picks one gallery image. Defaults to [pickGalleryImage]; tests inject a
  /// fake so no test opens a real picker.
  final Future<PickedImage?> Function()? pickImage;

  /// Opens the camera and resolves a scanned pairing string. Defaults to the
  /// real plugin; tests inject a fake so no test opens a camera.
  final QrScanner scanQr;

  @override
  State<PiDroidApp> createState() => _PiDroidAppState();
}

class _PiDroidAppState extends State<PiDroidApp> with WidgetsBindingObserver {
  late HubClientState _state = widget.client.state;
  StreamSubscription<HubClientState>? _subscription;
  StreamSubscription<String>? _openRequests;
  StreamSubscription<AgentSettledEvent>? _settlesSub;
  StreamSubscription<LeafEvent>? _leafSub;
  bool _loading = true;
  bool _authenticated = false;

  /// The candidate addresses the client is racing (or last raced). The header
  /// names the first; the pairing picker renders them all.
  List<HubEndpoint> _candidates = const [];

  /// A session requested by a tap (cold `initialSessionId` or a warm
  /// `openSessionRequests` event) that must wait for authentication before it
  /// can be subscribed. Sending `subscribe` on a socket the hub has not
  /// authenticated closes it `4002` and loops the reconnect.
  String? _pendingOpenSessionId;

  /// Whether the foreground service has been started for this hub; started once
  /// on the first authenticated connection, never restarted from the
  /// background.
  bool _foregroundStarted = false;

  /// The app's foreground/background reading, driving the notify rule.
  AppPresence _presence = AppPresence.foreground;

  /// The persisted engagement/mute policy. Restored in [_bootstrap] before the
  /// endpoint read so a `sessions` push cannot migrate against an empty policy.
  NotificationPolicy _notifyPolicy = NotificationPolicy();

  /// The addresses of an in-flight typed pairing. Persisted only once
  /// authentication succeeds, so a typo'd host is never saved and auto-dialled.
  /// A hub-minted scanned list is persisted at scan time instead.
  List<HubEndpoint> _pendingEndpoints = const [];

  /// The ticket accompanying the pending attempt, reused when the user forces a
  /// candidate from the picker.
  String? _pendingTicket;

  /// Whether a successful authentication should persist [_pendingEndpoints].
  /// True for typed input; false for a scanned list, which is already stored.
  bool _persistOnConnect = false;

  /// A bootstrap failure that is not a client error.
  String? _bootstrapError;

  /// The last error the user dismissed, so the banner does not re-show it.
  String? _dismissedError;

  /// The root Navigator, so the transcript route can be pushed and popped from
  /// the active session rather than from a tap.
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// The installed transcript route, or null when it is not up. Mirrors the
  /// Navigator stack: non-null iff the transcript route is installed.
  Route<void>? _transcriptRoute;

  /// The installed pairing route, or null when it is not up. Non-destructive:
  /// opening pairing leaves the list connected underneath. Mirrors the
  /// Navigator stack so the push is idempotent and the pop can be reconciled.
  Route<void>? _pairingRoute;

  /// Whether a deliberate pairing (typed, scanned or a forced candidate) is in
  /// flight. Set when the attempt starts; a `connected` state with it set pops
  /// the pushed pairing route. A background reconnect never sets it, so it
  /// cannot close a pairing screen the user is still filling in.
  bool _pairingAttempt = false;

  /// The last non-null active session. Kept so the outgoing transcript stays
  /// rendered during the pop animation, after `_close()` nulls the live id.
  String? _lastActiveSessionId;

  /// The composer draft. The shell owns it because the suggestion panel reads
  /// the text to filter and writes a picked `/name ` back into the field.
  final TextEditingController _composer = TextEditingController();

  /// The composer field's focus, held here so a command pick can return focus
  /// to the field.
  final FocusNode _composerFocus = FocusNode();

  /// The image picked for the next send, or null. Cleared on a session change
  /// and after each send, so it cannot leak into the wrong session or a later
  /// message.
  PickedImage? _attachment;

  /// The tree node the user tapped, waiting for the `leaf` event that proves pi
  /// navigated to it. Single-slot: a newer tap, a session switch, or a refusal
  /// clears it. The prefill runs from the leaf signal, never the ack, because
  /// the ack means accepted — not navigated.
  PendingTreeTap? _pendingTreeTap;

  /// Whether the composer currently holds a command draft (a leading `/` with
  /// no whitespace). The shell refetches the command list on the transition
  /// into this state, so the `/` overlay is fresh at the point of use.
  bool _commandDraftOpen = false;

  /// Whether the find-in-transcript query field is open.
  bool _searchOpen = false;

  /// The find-in-transcript query. Cleared when the search opens, closes, or
  /// the session switches.
  final TextEditingController _searchController = TextEditingController();

  /// The query field's focus, held so opening the search can focus it.
  final FocusNode _searchFocus = FocusNode();

  /// The id of the current match, or null. Tracked by id (not index) so a
  /// prepend or append keeps the current row; an id that disappears falls back
  /// to the first match.
  String? _searchCurrentBlockId;

  /// The memoised matches for [_searchMatchesQuery]/[_searchBlocksForMatches].
  List<TranscriptBlock> _searchMatches = const [];

  /// The **blocks list** [_searchMatches] was computed from - not the matches.
  /// The identity check against this is what keeps streaming frames (whose
  /// `blocks` identity is stable) from re-scanning the transcript.
  List<TranscriptBlock>? _searchBlocksForMatches;

  /// The query [_searchMatches] was computed for, so a rebuild with an
  /// unchanged query and blocks reuses the list.
  String _searchMatchesQuery = '';

  /// The extracted composer/dialog actions. Constructed in [initState] with the
  /// shell's live probes once, so each controller reads current state at the
  /// point of use rather than at construction.
  late final AttachmentActions _attachmentActions;
  late final ModelActions _modelActions;
  late final SessionActions _sessionActions;
  late final TreeActions _treeActions;

  @override
  void initState() {
    super.initState();
    _attachmentActions = AttachmentActions(isMounted: () => mounted);
    _modelActions = ModelActions(
      client: widget.client,
      isMounted: () => mounted,
      transcriptOf: (id) =>
          _state.transcripts[id] ?? const SessionTranscript(),
    );
    _sessionActions = SessionActions(
      client: widget.client,
      isMounted: () => mounted,
      activeSessionId: () => _state.activeSessionId,
      labelOf: _sessionLabel,
    );
    _treeActions = TreeActions(client: widget.client, isMounted: () => mounted);
    _pendingOpenSessionId = widget.initialSessionId;
    _subscription = widget.client.changes.listen(_onState);
    _openRequests = widget.notifications.openSessionRequests.listen(_queueOpen);
    _settlesSub = widget.client.settles.listen(_onSettle);
    _leafSub = widget.client.leafEvents.listen(_onLeaf);
    _composer.addListener(_onComposerChanged);
    WidgetsBinding.instance.addObserver(this);
    unawaited(widget.notifications.requestPermission());
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    _openRequests?.cancel();
    _settlesSub?.cancel();
    _leafSub?.cancel();
    _composer.removeListener(_onComposerChanged);
    _composer.dispose();
    _composerFocus.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` is the notification shade and split-screen/foldable
    // transitions, both of which still have the app on screen, so it counts as
    // foreground.
    _presence = switch (state) {
      AppLifecycleState.resumed || AppLifecycleState.inactive =>
        AppPresence.foreground,
      _ => AppPresence.background,
    };
  }

  /// Queues [sessionId] to open; [ _drainOpen] subscribes once connected.
  void _queueOpen(String sessionId) {
    _pendingOpenSessionId = sessionId;
    _drainOpen();
  }

  /// Opens the pending session if — and only if — the hub has authenticated
  /// this connection. Cold-start and warm taps both route through here.
  void _drainOpen() {
    if (_state.status != HubConnectionStatus.connected) return;
    final sessionId = _pendingOpenSessionId;
    if (sessionId == null) return;
    _pendingOpenSessionId = null;
    widget.client.subscribe(sessionId);
    // Opening is engagement: remembered across restarts, fire-and-forget like
    // the endpoint write.
    _notifyPolicy.engage(sessionId);
    unawaited(widget.tokenStore.writeNotifyState(_notifyPolicy.encode()));
    // The user is now looking at this session, so any shade entry for it is
    // stale. `cancel` on a missing id is a no-op.
    unawaited(
      widget.notifications.cancel(id: notificationIdForSession(sessionId)),
    );
  }

  /// A settle broadcast: notify only for a session the user engaged and has not
  /// muted, and never while it is on screen.
  void _onSettle(AgentSettledEvent event) {
    if (!mounted) return;
    final engaged =
        _hasAppOrigin(event.sessionId) ||
        _notifyPolicy.isEngaged(event.sessionId);
    final muted = _notifyPolicy.isMuted(event.sessionId);
    if (!_notifyPolicy.shouldNotify(
      presence: _presence,
      activeSessionId: _state.activeSessionId,
      sessionId: event.sessionId,
      engaged: engaged,
      muted: muted,
    )) {
      // The session is on screen or muted; clear any entry a backgrounded
      // settle left.
      unawaited(
        widget.notifications.cancel(
          id: notificationIdForSession(event.sessionId),
        ),
      );
      return;
    }
    unawaited(
      widget.notifications.show(
        id: notificationIdForSession(event.sessionId),
        title: event.label,
        body: notificationBody(event.text, truncated: event.truncated),
        sessionId: event.sessionId,
      ),
    );
  }

  /// A leaf move: the navigation a pending tree tap asked for actually ran.
  ///
  /// Prefill happens here, not on the `sessionTree` ack, because the bridge
  /// acks before it navigates: a cancel, a throw or a stale same-leaf tap all
  /// land after the ack. The single-slot tap is consumed whether or not it
  /// prefilled, and only when it belongs to the moved session.
  void _onLeaf(LeafEvent event) {
    if (!mounted) return;
    final pending = _pendingTreeTap;
    if (pending == null || pending.sessionId != event.sessionId) return;
    _pendingTreeTap = null;
    // pi restores the text only into an empty editor, and only for a user
    // message; an assistant node moves the leaf without prefilling.
    if (pending.node.role != 'user') return;
    if (_composer.text.trim().isNotEmpty) return;
    _composer.value = TextEditingValue(
      text: pending.node.text,
      selection: TextSelection.collapsed(offset: pending.node.text.length),
    );
    _composerFocus.requestFocus();
  }

  void _onState(HubClientState state) {
    if (!mounted) return;
    // A `/new`//`/fork` successor carries the id it replaced: inherit the
    // predecessor's engagement and mute. Null-guarded — most sessions are not
    // replacements, and `replacesSessionId` is null for an ordinary one.
    var changed = false;
    for (final s in state.sessions) {
      final from = s.replacesSessionId;
      if (from == null) continue;
      if (_notifyPolicy.migrate(from: from, to: s.sessionId)) changed = true;
    }
    final previous = _state.activeSessionId;
    final persist =
        state.status == HubConnectionStatus.connected && _persistOnConnect;
    final pendingEndpoints = persist ? _pendingEndpoints : const <HubEndpoint>[];
    setState(() {
      _state = state;
      // A deliberate pairing that ended in failure is over: drop the flag so
      // the button reverts to "Pair" and can spin again on a retry. Only a
      // connection-scoped error ends the attempt — a session notice that
      // outlived it (e.g. a resync give-up) is not this dial failing, and
      // clearing on it would hide the spinner and skip a successful pop.
      // Success is handled below, after the `connected` check — clearing it
      // here would skip that pop.
      if (_pairingAttempt &&
          state.status != HubConnectionStatus.connected &&
          state.lastError != null &&
          widget.client.lastErrorFromConnection) {
        _pairingAttempt = false;
      }
      // Open/close/switch/replacement: a picked image belongs to the session it
      // was picked in, and the pre-existing draft text is deliberately global.
      if (state.activeSessionId != previous) {
        _attachment = null;
        // A pending tree tap belongs to the session it was made in; a switch
        // abandons it rather than letting a later leaf prefill it.
        _pendingTreeTap = null;
        // A find-in-transcript query belongs to the session it was typed in.
        _searchOpen = false;
        _searchCurrentBlockId = null;
        _searchController.clear();
      }
      // A hub that loses the capability must not resurrect a stale pick if the
      // capability later returns.
      if (!state.capabilities.contains(capabilityAttachments)) _attachment = null;
      if (state.status == HubConnectionStatus.connected) {
        // Sticky: once paired, a later drop shows the main UI with a banner
        // rather than throwing the user back to pairing.
        _authenticated = true;
        // The (single-use) ticket has been redeemed; a later forced candidate
        // must never re-present a spent one.
        _pendingTicket = null;
        if (persist) {
          _pendingEndpoints = const [];
          _persistOnConnect = false;
        }
      }
    });
    // A deliberate pairing just reached `connected`: clear the flag and close
    // the pushed pairing route, if one is open. The flag is cleared whether or
    // not a route is open (a pairing from the root form sets it too). It is the
    // flag, not a bare `connected` check, that keeps a background reconnect
    // from popping a pairing screen the user is still filling in.
    if (_pairingAttempt && state.status == HubConnectionStatus.connected) {
      _pairingAttempt = false;
      final route = _pairingRoute;
      if (route != null) {
        _pairingRoute = null;
        final navigator = _navigatorKey.currentState;
        if (navigator != null) {
          if (route.isCurrent) {
            navigator.pop();
          } else {
            navigator.removeRoute(route);
          }
        }
      }
    }
    if (pendingEndpoints.isNotEmpty) {
      unawaited(widget.tokenStore.writeEndpoints(pendingEndpoints));
    }
    // Only a real migration writes: an ordinary push must not churn the store.
    if (changed) {
      unawaited(widget.tokenStore.writeNotifyState(_notifyPolicy.encode()));
    }
    if (state.status == HubConnectionStatus.connected && !_foregroundStarted) {
      // Started here, while the app is foregrounded, never from the background:
      // Android forbids a background FGS start on API 31+.
      _foregroundStarted = true;
      unawaited(widget.notifications.startForeground());
    }
    _drainOpen();
    // Remember the last non-null session, then reconcile the route with the
    // active id. `_lastActiveSessionId` keeps the outgoing transcript rendered
    // during the pop animation, after `_close()` nulls the live id. The route
    // reads `_state` directly; the `setState` above rebuilds the Navigator,
    // which forces every installed route to rebuild its page.
    final activeId = state.activeSessionId;
    if (activeId != null) _lastActiveSessionId = activeId;
    _syncTranscriptRoute();
  }

  /// Flips the active session's mute override and persists it.
  void _toggleNotify(String sessionId) {
    setState(
      () => _notifyPolicy.setMuted(
        sessionId,
        !_notifyPolicy.isMuted(sessionId),
      ),
    );
    unawaited(widget.tokenStore.writeNotifyState(_notifyPolicy.encode()));
  }

  /// Whether the hub registered [sessionId] as started from the app.
  ///
  /// Reads the live client snapshot, not the coalesced shell `_state`:
  /// `widget.client.state` is updated synchronously when the `sessions` frame is
  /// parsed, before the coalesced `changes` emit, while `_state` lags to that
  /// emit. A settle emitted in the same frame as a registration would see a
  /// stale `_state` and deny an app-started session its engagement.
  bool _hasAppOrigin(String sessionId) {
    for (final s in widget.client.state.sessions) {
      if (s.sessionId == sessionId) return s.origin == 'app';
    }
    return false;
  }

  Future<void> _bootstrap() async {
    // Load the notify policy before the endpoint read, hence before
    // `client.start`: the first `sessions` push may carry a replacement, so the
    // policy must exist before a socket does, or that push would migrate
    // against an empty policy and then be overwritten by the stale blob.
    try {
      final blob = await widget.tokenStore.readNotifyState();
      if (mounted) _notifyPolicy = NotificationPolicy.decode(blob);
    } catch (_) {
      // A broken store yields an empty policy rather than blocking boot.
    }
    List<HubEndpoint> endpoints;
    try {
      endpoints = await widget.tokenStore.readEndpoints();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _bootstrapError = 'could not read the saved hub address: $error';
        _loading = false;
      });
      return;
    }
    if (!mounted) return;
    if (endpoints.isNotEmpty) {
      _candidates = endpoints;
      try {
        await widget.client.startCandidates(endpoints);
      } on StateError {
        // A remembered address with no stored token: pairing is still required.
      } catch (error) {
        // The keystore could not hand the token back (a platform failure, not
        // a missing token). Surface it and return to pairing rather than
        // leaving the spinner spinning forever.
        if (!mounted) return;
        setState(() {
          _bootstrapError = 'could not read the saved token: $error';
          _loading = false;
        });
        return;
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _pair(String host, int port, String code) async {
    final endpoint = HubEndpoint(host: host, port: port);
    _pendingEndpoints = [endpoint];
    _pendingTicket = code;
    _persistOnConnect = true;
    _pairingAttempt = true;
    setState(() => _candidates = [endpoint]);
    await widget.client.startCandidates([endpoint], ticket: code);
  }

  /// A scanned pairing: the hub minted this list, so it is persisted before the
  /// race — a typo is not a concern, and a total-failure race must not lose the
  /// tailnet address.
  Future<void> _pairScanned(List<HubEndpoint> candidates, String code) async {
    if (candidates.isEmpty) return;
    setState(() {
      _candidates = List.of(candidates);
      _pendingTicket = code;
      _persistOnConnect = false;
      // A typed attempt's prospective list is superseded by this one; it must
      // not be written as if it belonged to the scan.
      _pendingEndpoints = const [];
    });
    await widget.tokenStore.writeEndpoints(candidates);
    if (!mounted) return;
    _pairingAttempt = true;
    await widget.client.startCandidates(candidates, ticket: code);
  }

  /// Re-races the candidate list, preferring the tapped one.
  Future<void> _connectCandidate(HubEndpoint candidate) async {
    try {
      _pairingAttempt = true;
      await widget.client.startCandidates(
        _candidates,
        ticket: _pendingTicket,
        prefer: candidate,
      );
    } on StateError {
      // The scan persisted the list but the race never paired, so after a
      // restart there are candidates and neither a ticket nor a stored token.
      // Forcing one cannot connect; surface it rather than letting the
      // fire-and-forget callback throw into the void. The attempt is over, so
      // its flag must go too: left set, a later genuine `connected` would be
      // mistaken for this failed pairing and close the screen.
      if (!mounted) return;
      _pairingAttempt = false;
      setState(() {
        _bootstrapError =
            'could not connect: no pairing code or saved token for this hub';
      });
    } catch (error) {
      // The keystore could not hand a token back (a platform failure, not a
      // missing one). Same contract as the StateError arm: surface it and end
      // the attempt, or the already-dropped socket leaves a permanent spinner
      // no reconnect can clear.
      if (!mounted) return;
      _pairingAttempt = false;
      setState(() {
        _bootstrapError = 'could not read the saved token: $error';
      });
    }
  }

  /// Opens the pairing screen as a pushed route over the live session list.
  ///
  /// Non-destructive: nothing is disconnected or cleared, so back always
  /// returns to the list with the pairing intact. The latch makes the push
  /// idempotent, and the route's `PopScope` clears it on a real pop.
  void _openPairing() {
    if (_pairingRoute != null) return;
    final route = MaterialPageRoute<void>(
      builder: (_) => PopScope<void>(
        canPop: true,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) _pairingRoute = null;
        },
        child: _pairingScreen(showBack: true),
      ),
    );
    _pairingRoute = route;
    _navigatorKey.currentState?.push(route);
  }

  /// Refetches the active session's command list when the `/` overlay opens.
  ///
  /// Only the transition into a command draft triggers a request — not every
  /// keystroke — so toggling `/` off and on again costs two requests. The
  /// cached list stays visible until a successful reply overwrites it; a
  /// refusal (an old hub) leaves it untouched.
  ///
  /// Switching sessions mid-draft fires no transition, so the new session
  /// relies solely on its subscribe-time fetch; if that fetch was refused (an
  /// old hub) the already-open overlay stays empty until the user clears and
  /// retypes `/`.
  void _onComposerChanged() {
    final open = isCommandDraft(_composer.text);
    if (open && !_commandDraftOpen) {
      final activeId = _state.activeSessionId;
      if (activeId != null) unawaited(widget.client.loadCommands(activeId));
    }
    _commandDraftOpen = open;
  }

  /// The matches for [blocks], memoised so a streaming frame (which keeps the
  /// same `blocks` identity) does not re-scan the transcript. Closed means no
  /// matches.
  List<TranscriptBlock> _matchesFor(List<TranscriptBlock> blocks) {
    if (!_searchOpen) return const [];
    if (_searchController.text == _searchMatchesQuery &&
        identical(blocks, _searchBlocksForMatches)) {
      return _searchMatches;
    }
    final matches = blocksMatching(blocks, _searchController.text);
    _searchMatches = matches;
    _searchBlocksForMatches = blocks;
    _searchMatchesQuery = _searchController.text;
    return matches;
  }

  /// The current match's index in [matches], falling back to the first when the
  /// tracked id is gone (a prepend/append that dropped it), or -1 when empty.
  int _currentMatchIndex(List<TranscriptBlock> matches) {
    if (matches.isEmpty) return -1;
    final index = matches.indexWhere((b) => b.id == _searchCurrentBlockId);
    return index < 0 ? 0 : index;
  }

  void _openSearch() {
    _searchController.clear();
    setState(() {
      _searchOpen = true;
      _searchCurrentBlockId = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    _searchController.clear();
    _searchFocus.unfocus();
    setState(() {
      _searchOpen = false;
      _searchCurrentBlockId = null;
    });
  }

  /// Steps the current match by [delta], wrapping around the matches.
  void _searchStep(int delta, List<TranscriptBlock> matches) {
    if (matches.isEmpty) return;
    final index = _currentMatchIndex(matches);
    final next = (index + delta + matches.length) % matches.length;
    setState(() => _searchCurrentBlockId = matches[next].id);
  }

  /// The find-in-transcript query field, shown in place of the title.
  Widget _searchField() => TextField(
    key: const Key('transcript-search-field'),
    controller: _searchController,
    focusNode: _searchFocus,
    // Any edit re-anchors the current match to the first hit.
    onChanged: (_) => setState(() => _searchCurrentBlockId = null),
    decoration: const InputDecoration(
      hintText: 'Search transcript',
      border: InputBorder.none,
    ),
  );

  /// The counted n/N readout. The KEY is the contract, not its slot: at a large
  /// text scale this can move into the field's `suffixText` (same key) if it
  /// overflows the bar.
  Widget _searchCount(int currentIndex, int total) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        total == 0 ? '0/0' : '${currentIndex + 1}/$total',
        key: const Key('transcript-search-count'),
        style: piMono(fontSize: 12),
      ),
    ),
  );

  void _open(SessionSummary session) => _queueOpen(session.sessionId);

  void _close() {
    final active = _state.activeSessionId;
    if (active != null) widget.client.unsubscribe(active);
  }

  /// The `prompt`/`followup` args for [text], carrying the picked image when
  /// the hub advertises attachments. The image is consumed here, so a send
  /// clears the chip whether or not the command is accepted.
  Map<String, Object?> _composeArgs(String text) {
    final image = _attachment;
    final args = <String, Object?>{'text': text};
    if (image != null && _state.capabilities.contains(capabilityAttachments)) {
      args['images'] = [image.toArg()];
    }
    if (image != null) setState(() => _attachment = null);
    return args;
  }

  /// Writes a picked command into the draft and returns focus to the field.
  ///
  /// It inserts rather than sends: the user may still want to add arguments, and
  /// phase-1's `expandPromptTemplates` runs the command on send.
  void _pickCommand(String name) {
    final text = '/$name ';
    _composer.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _composerFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'pi',
    // `themeMode` defaults to `ThemeMode.system`, so which of these applies is
    // decided by the phone's own dark-mode setting — no in-app toggle to keep
    // in sync with it. Both are built from pi's own palette; see `theme.dart`.
    theme: piTheme(Brightness.light),
    darkTheme: piTheme(Brightness.dark),
    home: Builder(builder: _home),
    navigatorKey: _navigatorKey,
  );

  /// The sessions header. The host is the useful half of the paired address, and
  /// the port is included because pairing accepts a non-default one.
  String _sessionsTitle() {
    if (_candidates.isEmpty) return 'pi sessions';
    final first = _candidates.first.encode();
    if (_candidates.length == 1) return 'pi sessions · $first';
    return 'pi sessions · $first +${_candidates.length - 1}';
  }

  /// The pairing widget, shared by the boot path (as the root) and the pushed
  /// route (over the live list). [showBack] is true only for the pushed case:
  /// the boot root has nothing behind it, so it must not offer a way back.
  Widget _pairingScreen({bool showBack = false}) => PairingScreen(
    showBack: showBack,
    onSubmit: _pair,
    onScanned: _pairScanned,
    onCandidate: _connectCandidate,
    candidates: _candidates,
    scanQr: widget.scanQr,
    lastError: _state.lastError ?? _bootstrapError,
    busy: _pairingAttempt,
    initialHost: _candidates.isEmpty ? '' : _candidates.first.host,
    initialPort: _candidates.isEmpty
        ? '8787'
        : _candidates.first.port.toString(),
  );

  Widget _home(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_authenticated) {
      return _pairingScreen();
    }

    // The list is always the `home` route. The transcript, when one is open, is
    // a pushed sibling route above it (see [_syncTranscriptRoute]).
    return Scaffold(
      appBar: AppBar(
        // Naming the hub is the only place the paired address is visible once
        // pairing is done — which is exactly when a wrong host is hardest to
        // notice, since everything else looks the same.
        title: Text(_sessionsTitle(), style: piMono(fontSize: 14)),
        actions: [
          IconButton(
            key: const Key('pairing'),
            icon: const Icon(Icons.settings_ethernet),
            tooltip: 'Pairing',
            onPressed: _openPairing,
          ),
        ],
      ),
      body: _withStatusBanner(
        context,
        SessionList(
          sessions: _state.sessions,
          pendingSessions: _state.pendingSessions,
          onOpen: _open,
          onKill: (session) => _sessionActions.kill(session, context),
          onCancel: (pending) => _sessionActions.cancelPending(pending, context),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('start-session'),
        tooltip: 'Start a session',
        onPressed: () => _sessionActions.start(
          context,
          canBrowse: _state.capabilities.contains(capabilityListDirs) &&
              _state.capabilities.contains(capabilityProjectSession),
        ),
        child: const Icon(Icons.add),
      ),
    );
  }

  /// The transcript for [activeId], built by the pushed route's builder.
  ///
  /// [activeId] is normally `_state.activeSessionId`; during the pop animation
  /// it is [_lastActiveSessionId], so the outgoing transcript stays rendered.
  Widget _transcriptScaffold(BuildContext context, String activeId) {
    final transcript =
        _state.transcripts[activeId] ?? const SessionTranscript();
    final attachmentsEnabled =
        _state.capabilities.contains(capabilityAttachments);
    final matches = _matchesFor(transcript.blocks);
    final currentIndex = _currentMatchIndex(matches);
    final search = TranscriptSearch(
      open: _searchOpen,
      matches: matches,
      current: currentIndex,
    );
    final view = Scaffold(
      appBar: AppBar(
        title: _searchOpen
            ? _searchField()
            : _transcriptTitle(activeId, transcript),
        leading: _searchOpen
            ? IconButton(
                key: const Key('transcript-search-close'),
                icon: const Icon(Icons.close),
                onPressed: _closeSearch,
                tooltip: 'Close search',
              )
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _close,
                tooltip: 'Sessions',
              ),
        actions: _searchOpen
            ? [
                _searchCount(currentIndex, matches.length),
                IconButton(
                  key: const Key('transcript-search-prev'),
                  icon: const Icon(Icons.keyboard_arrow_up),
                  onPressed: matches.isEmpty
                      ? null
                      : () => _searchStep(-1, matches),
                  tooltip: 'Previous match',
                ),
                IconButton(
                  key: const Key('transcript-search-next'),
                  icon: const Icon(Icons.keyboard_arrow_down),
                  onPressed: matches.isEmpty
                      ? null
                      : () => _searchStep(1, matches),
                  tooltip: 'Next match',
                ),
              ]
            : [
                IconButton(
                  key: const Key('transcript-search'),
                  icon: const Icon(Icons.search),
                  onPressed: _openSearch,
                  tooltip: 'Search transcript',
                ),
                SessionMenuButton(
                  muted: _notifyPolicy.isMuted(activeId),
                  onToggleNotify: () => _toggleNotify(activeId),
                  thinkingLevel: transcript.thinkingLevel,
                  model: transcript.currentModel?.name,
                  onCompact: () => _sessionActions.compact(context),
                  onRename: () => _sessionActions.rename(activeId, context),
                  onThinkingLevel: () =>
                      _modelActions.setThinkingLevel(activeId, context),
                  onModel: () => _modelActions.setModel(activeId, context),
                  // New and fork replace the session: only a hub advertising
                  // the capability can, and without it the items are omitted
                  // rather than offered and refused.
                  onNewSession:
                      _state.capabilities.contains(capabilitySessionControl)
                      ? () => _sessionActions.newSession(context)
                      : null,
                  onFork:
                      _state.capabilities.contains(capabilitySessionControl)
                      ? () => _treeActions.fork(activeId, context)
                      : null,
                  onTree:
                      _state.capabilities.contains(capabilitySessionControl)
                      ? () => _treeActions.navigate(
                          activeId,
                          context,
                          arm: (tap) => _pendingTreeTap = tap,
                          disarm: () => _pendingTreeTap = null,
                        )
                      : null,
                ),
              ],
      ),
      // The composer lives in the BODY, not the bottomNavigationBar slot:
      // resizeToAvoidBottomInset only resizes the body, so a nav bar stays
      // pinned to the screen bottom and the keyboard covers it.
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => Stack(
                children: [
                  _withStatusBanner(
                    context,
                    // Keyed on the session: a new session is a new view, so its
                    // scroll position and following state are not inherited from
                    // the last one.
                    TranscriptView(
                      key: ValueKey(activeId),
                      transcript: transcript,
                      onLoadOlder: () => widget.client.loadOlder(activeId),
                      search: search,
                    ),
                  ),
                  // The suggestions float over the transcript instead of taking
                  // a Column slot, so there is no `Flex` here to overflow. The
                  // real safety is the `min(200, ...)` cap: an oversized
                  // `Positioned` would be hard-clipped, not resized.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    // Inside the `Positioned`, so typing rebuilds only the
                    // panel — never the transcript.
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _composer,
                      builder: (context, value, _) {
                        final suggestions = suggestionsFor(
                          _state.commands[activeId] ?? const <SlashCommand>[],
                          value.text,
                        );
                        if (suggestions.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        return CommandSuggestionPanel(
                          commands: suggestions,
                          maxHeight: min(200, constraints.maxHeight),
                          onPick: _pickCommand,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          StatusIndicator(transcript: transcript),
          ComposeBar(
            controller: _composer,
            focusNode: _composerFocus,
            enabled: _state.status == HubConnectionStatus.connected,
            thinkingLevel: transcript.thinkingLevel,
            attachment: attachmentsEnabled ? _attachment : null,
            onAttach: attachmentsEnabled
                ? () => _attachmentActions.pick(
                    context,
                    pickImage: widget.pickImage,
                    onPicked: (image) => setState(() => _attachment = image),
                  )
                : null,
            onRemoveAttachment: () => setState(() => _attachment = null),
            onSend: (text) => widget.client.sendCommand(
              activeId,
              'prompt',
              args: _composeArgs(text),
            ),
            onAbort: () => widget.client.sendCommand(activeId, 'abort'),
            onFollowUp: (text) => widget.client.sendCommand(
              activeId,
              'followup',
              args: _composeArgs(text),
            ),
          ),
        ],
      ),
    );

    return view;
  }

  /// The transcript's title: the session name plus the context reading.
  ///
  /// The reading takes priority over the name: the name is a reminder of which
  /// session this is, while the reading is a number you cannot guess from
  /// anything else on screen. So the name is the flexible half, and it is the
  /// one that gets cut when the two compete for room.
  ///
  /// The reading is laid out before the name (non-flex children are measured
  /// first) and is never ellipsized. At a large text scale it can want more
  /// room than the title has at all, which would overflow the row — so it is
  /// capped to the available width and scaled down rather than truncated: a
  /// slightly smaller number beats a cut-off one.
  Widget _transcriptTitle(String activeId, SessionTranscript transcript) {
    final usage = transcript.contextUsage;
    final usageLabel = usage == null ? null : formatContextUsage(usage);
    // A running compaction takes the reading's slot: the number is exactly what
    // the compaction is about to invalidate, and an app bar that sits unchanged
    // for the length of a summarization call reads as a hang.
    final barLabel = transcript.compacting ? 'Compacting…' : usageLabel;
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          Expanded(
            child: Text(
              _sessionLabel(activeId),
              key: const Key('session-name'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // The session's name is a session's name, not prose: the app bar
              // speaks in the machine's voice, like every other label that
              // names a thing.
              style: piMono(fontSize: 13),
            ),
          ),
          if (barLabel != null)
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              // The gap lives inside the cap, so the padding cannot push the
              // row past the width the label was measured against.
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    barLabel,
                    key: Key(
                      transcript.compacting ? 'compacting' : 'context-usage',
                    ),
                    maxLines: 1,
                    softWrap: false,
                    style: piMono(fontSize: 12),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Keeps the pushed transcript route in step with [_state.activeSessionId].
  ///
  /// A route is pushed when a session becomes active and popped when it goes
  /// away. It is pushed even while the app is backgrounded: the open already
  /// happened, and the transcript is what the user should see on return.
  void _syncTranscriptRoute() {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      // The first state emit can precede the Navigator's first frame. Retry once
      // the tree is mounted rather than dropping the push until an unrelated
      // emit.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncTranscriptRoute();
      });
      return;
    }
    final activeId = _state.activeSessionId;
    if (activeId != null) {
      if (_transcriptRoute != null) return; // idempotence guard
      final route = MaterialPageRoute<void>(
        // Reads `_state` directly. The route rebuilds because the shell's
        // `setState` rebuilds the Navigator, whose `didUpdateWidget` forces
        // every installed route to rebuild its page.
        builder: (context) {
          final id = _state.activeSessionId ?? _lastActiveSessionId;
          if (id == null) return const SizedBox.shrink();
          return PopScope<void>(
            // canPop is false only while the find-in-transcript field is open, so
            // a back gesture closes the search instead of leaving the session.
            // This PopScope is LOAD-BEARING, not decorative: without its PopEntry
            // a gesture commit would pop the route with nothing left to call
            // `_close()`, and the next state emit would push the transcript
            // straight back over the list.
            canPop: !_searchOpen,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) {
                // The route declined the pop because the search is open: close
                // it and stay on the transcript.
                if (_searchOpen) _closeSearch();
                return;
              }
              // Clear the latch BEFORE `_close()`. `_close()` unsubscribes, and
              // the coalescing emit for that state change lands on a later frame;
              // if it arrives after this route has been popped and disposed, the
              // null-id branch would call `removeRoute` on it and trip
              // `assert(route._isInstalledIn(this))`. Pinned by the predictive
              // back test, which lands the emit after the pop finishes.
              _transcriptRoute = null;
              _close();
            },
            child: _transcriptScaffold(context, id),
          );
        },
      );
      _transcriptRoute = route;
      navigator.push(route);
      return;
    }
    final route = _transcriptRoute;
    if (route == null) return;
    _transcriptRoute = null;
    // `pop` animates the ordinary case; `removeRoute` is the only safe option
    // when an overlay (dialog/sheet) is on top — and it leaves that overlay
    // orphaned over the list, which is today's behaviour too.
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  /// A thin banner so a dropped connection, a dead-end resync or a send failure
  /// is never silent. Shown whenever there is an error, whatever the status —
  /// not only while disconnected.
  Widget _withStatusBanner(BuildContext context, Widget child) {
    final error = _state.lastError;
    final showError = error != null && error != _dismissedError;
    final showReconnect = _state.status != HubConnectionStatus.connected;
    if (!showError && !showReconnect) return child;
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.errorContainer,
          padding: const EdgeInsets.only(left: 8, right: 8),
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    showError ? error : 'Reconnecting to the hub…',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ),
              if (showError)
                IconButton(
                  key: const Key('dismiss-error'),
                  icon: const Icon(Icons.close),
                  tooltip: 'Dismiss',
                  onPressed: () =>
                      setState(() => _dismissedError = _state.lastError),
                ),
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }

  String _sessionLabel(String sessionId) {
    for (final session in _state.sessions) {
      if (session.sessionId == sessionId) return session.label;
    }
    return 'session';
  }
}
