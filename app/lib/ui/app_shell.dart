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
import '../client/hub_client.dart';
import '../client/notification_policy.dart';
import '../client/notification_presenter.dart';
import '../client/settle_notification.dart';
import '../client/token_store.dart';
import '../platform/gallery_picker.dart';
import '../protocol/protocol.dart';
import 'command_suggestions.dart';
import 'compose_bar.dart';
import 'folder_browser.dart';
import 'pairing_screen.dart';
import 'session_list.dart';
import 'session_menu.dart';
import 'status_indicator.dart';
import 'transcript_view.dart';

class PiDroidApp extends StatefulWidget {
  const PiDroidApp({
    super.key,
    required this.client,
    required this.tokenStore,
    required this.notifications,
    this.initialSessionId,
    this.pickImage,
  });

  final HubClient client;
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
  HubEndpoint? _endpoint;

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

  /// The endpoint of an in-flight pairing. Persisted only once authentication
  /// succeeds, so a typo'd host is never saved and auto-dialled.
  HubEndpoint? _pendingEndpoint;

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
  _PendingTreeTap? _pendingTreeTap;

  /// Whether the composer currently holds a command draft (a leading `/` with
  /// no whitespace). The shell refetches the command list on the transition
  /// into this state, so the `/` overlay is fresh at the point of use.
  bool _commandDraftOpen = false;

  @override
  void initState() {
    super.initState();
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
    final pending =
        state.status == HubConnectionStatus.connected ? _pendingEndpoint : null;
    setState(() {
      _state = state;
      // Open/close/switch/replacement: a picked image belongs to the session it
      // was picked in, and the pre-existing draft text is deliberately global.
      if (state.activeSessionId != previous) {
        _attachment = null;
        // A pending tree tap belongs to the session it was made in; a switch
        // abandons it rather than letting a later leaf prefill it.
        _pendingTreeTap = null;
      }
      // A hub that loses the capability must not resurrect a stale pick if the
      // capability later returns.
      if (!state.capabilities.contains(capabilityAttachments)) _attachment = null;
      if (state.status == HubConnectionStatus.connected) {
        // Sticky: once paired, a later drop shows the main UI with a banner
        // rather than throwing the user back to pairing.
        _authenticated = true;
        if (pending != null) _pendingEndpoint = null;
      }
    });
    if (pending != null) unawaited(widget.tokenStore.writeEndpoint(pending));
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
    HubEndpoint? endpoint;
    try {
      endpoint = await widget.tokenStore.readEndpoint();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _bootstrapError = 'could not read the saved hub address: $error';
        _loading = false;
      });
      return;
    }
    if (!mounted) return;
    if (endpoint != null) {
      _endpoint = endpoint;
      try {
        await widget.client.start(endpoint.host, port: endpoint.port);
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
    _pendingEndpoint = endpoint;
    setState(() => _endpoint = endpoint);
    await widget.client.start(host, port: port, ticket: code);
  }

  /// Forgets the hub, its token and the open transcript, and returns to pairing.
  /// A wrong saved host is otherwise unrecoverable without reinstalling.
  Future<void> _changeHub() async {
    await widget.client.disconnect();
    await widget.tokenStore.clearEndpoint();
    await widget.tokenStore.clear();
    _pendingOpenSessionId = null;
    _foregroundStarted = false;
    await widget.notifications.stopForeground();
    if (!mounted) return;
    setState(() {
      _authenticated = false;
      _endpoint = null;
      _pendingEndpoint = null;
      _bootstrapError = null;
      _dismissedError = null;
      _attachment = null;
      _state = widget.client.state;
    });
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

  void _open(SessionSummary session) => _queueOpen(session.sessionId);

  /// Starts an app-started session. With the folder capabilities the FAB first
  /// offers a choice between a quick temp-dir session and browsing to a project;
  /// otherwise it starts directly, exactly as it always has. [context] is the
  /// sessions-view context, below `MaterialApp`, so its `ScaffoldMessenger` and
  /// `Navigator` are ancestors.
  void _start(BuildContext context) {
    if (_state.capabilities.contains(capabilityListDirs) &&
        _state.capabilities.contains(capabilityProjectSession)) {
      unawaited(_chooseStart(context));
      return;
    }
    _quickStart(context);
  }

  /// The old-hub path: start immediately, no chooser.
  void _quickStart(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    unawaited(
      widget.client.startSession().then((result) {
        if (!result.ok) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(result.error ?? 'could not start a session'),
            ),
          );
        }
      }),
    );
  }

  /// The capability path: a bottom-sheet chooser. The messenger and navigator
  /// are captured before the sheet's async gap, because the sheet's own context
  /// is gone once it closes; the sheet is popped and only then is the browser
  /// route pushed.
  Future<void> _chooseStart(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('quick-session'),
              leading: const Icon(Icons.add),
              title: const Text('Quick session'),
              onTap: () => Navigator.pop(sheetContext, 'quick'),
            ),
            ListTile(
              key: const Key('open-project'),
              leading: const Icon(Icons.folder_open),
              title: const Text('Open a project'),
              onTap: () => Navigator.pop(sheetContext, 'project'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'quick') {
      final result = await widget.client.startSession();
      if (!mounted) return;
      if (!result.ok) {
        messenger.showSnackBar(
          SnackBar(content: Text(result.error ?? 'could not start a session')),
        );
      }
    } else if (choice == 'project') {
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => FolderBrowserScreen(client: widget.client),
        ),
      );
    }
  }

  /// Kills an app-started session. A refusal is shown in a SnackBar.
  void _kill(SessionSummary session, BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    unawaited(
      widget.client.killSession(session.sessionId).then((result) {
        if (!result.ok) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(result.error ?? 'could not kill the session'),
            ),
          );
        }
      }),
    );
  }

  /// Compacts the session after a confirmation. The messenger and session id
  /// are captured before the dialog's await, because the dialog's own context
  /// is gone once it closes.
  Future<void> _compact(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final activeId = _state.activeSessionId;
    if (activeId == null) return;
    final confirmed = await confirmCompact(context);
    if (!mounted || !confirmed) return;
    final result = await widget.client.sendCommand(activeId, 'compact');
    if (!mounted || result.ok) return;
    messenger.showSnackBar(
      SnackBar(content: Text(result.error ?? 'could not compact')),
    );
  }

  /// Replaces the session with a fresh one after a confirmation. The messenger
  /// and session id are captured before the dialog's await, because the dialog's
  /// own context is gone once it closes.
  ///
  /// The returned future settles on the replacement, not the ack, so a refusal
  /// is the only failure that reaches the SnackBar here.
  Future<void> _newSession(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final activeId = _state.activeSessionId;
    if (activeId == null) return;
    final confirmed = await confirmNewSession(context);
    if (!mounted || !confirmed) return;
    final result = await widget.client.sessionNew(activeId);
    if (!mounted || result.ok) return;
    messenger.showSnackBar(
      SnackBar(content: Text(result.error ?? 'could not start a new session')),
    );
  }

  /// Lists the session tree, shows only user nodes, and forks at the picked one.
  /// `context.mounted` after the list await, because the picker needs the
  /// descendant context alive — the same check `_setModel` makes.
  Future<void> _fork(String activeId, BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final listed = await widget.client.listTree(activeId);
    if (!context.mounted) return;
    if (!listed.ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(listed.error ?? 'could not read the session tree'),
        ),
      );
      return;
    }
    final picked = await pickTreeNode(
      context,
      listed.tree ?? const <TreeNodeSummary>[],
      userOnly: true,
      truncated: listed.treeTruncated ?? false,
    );
    if (!mounted || picked == null) return;
    final result = await widget.client.sessionFork(activeId, picked.id);
    if (!mounted || result.ok) return;
    messenger.showSnackBar(
      SnackBar(content: Text(result.error ?? 'could not fork the session')),
    );
  }

  /// Lists the whole session tree, marks pi's current leaf, and moves the leaf
  /// to the picked node. `context.mounted` after the list await, because the
  /// picker needs the descendant context alive — the same check `_fork` makes.
  ///
  /// The `sessionTree` ack means accepted, not navigated, so this never
  /// prefills and never re-requests history here: [_onLeaf] does both when pi's
  /// `leaf` event arrives. A request issued now would race the move and could
  /// return the old branch.
  Future<void> _navigateTree(String activeId, BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final listed = await widget.client.listTree(activeId);
    if (!context.mounted) return;
    if (!listed.ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(listed.error ?? 'could not read the session tree'),
        ),
      );
      return;
    }
    final picked = await pickTreeNode(
      context,
      listed.tree ?? const <TreeNodeSummary>[],
      userOnly: false,
      truncated: listed.treeTruncated ?? false,
      leafId: listed.leafId,
    );
    if (!mounted || picked == null) return;
    // pi returns early for a same-leaf target before it emits, so a tap sent
    // for the current point would produce no `leaf` event and look like a
    // failure. Answer it locally instead.
    if (picked.id == listed.leafId) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Already at this point')),
      );
      return;
    }
    _pendingTreeTap = _PendingTreeTap(sessionId: activeId, node: picked);
    final result = await widget.client.sessionTree(activeId, picked.id);
    if (!mounted) return;
    if (!result.ok) {
      // A dispatch-time refusal never navigates, so drop the armed tap rather
      // than let a later, unrelated leaf prefill it.
      _pendingTreeTap = null;
      messenger.showSnackBar(
        SnackBar(content: Text(result.error ?? 'could not navigate the tree')),
      );
    }
  }

  /// Renames the session. The display updates when pi reports the new label.
  Future<void> _rename(String activeId, BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final name = await promptRename(context, _sessionLabel(activeId));
    if (!mounted || name == null) return;
    final result = await widget.client.sendCommand(
      activeId,
      'setSessionName',
      args: {'name': name.trim()},
    );
    if (!mounted || result.ok) return;
    messenger.showSnackBar(
      SnackBar(content: Text(result.error ?? 'could not rename the session')),
    );
  }

  /// Sends the picked thinking level. No optimistic update: the shown value
  /// comes from the next `usage` event, so an unsupported level snaps back to
  /// the clamped one pi actually applied.
  Future<void> _setThinkingLevel(String activeId, BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final transcript = _state.transcripts[activeId] ?? const SessionTranscript();
    final level = await pickThinkingLevel(context, transcript.thinkingLevel);
    if (!mounted || level == null) return;
    final result = await widget.client.sendCommand(
      activeId,
      'setThinkingLevel',
      args: {'level': level},
    );
    if (!mounted || result.ok) return;
    messenger.showSnackBar(
      SnackBar(content: Text(result.error ?? 'could not set the thinking level')),
    );
  }

  /// Lists pi's models and sends the picked one. No optimistic update: the
  /// shown name comes from the next `usage` event, so it cannot disagree with
  /// what pi actually applied.
  Future<void> _setModel(String activeId, BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final listed = await widget.client.listModels(activeId);
    // `context.mounted`, not the State's `mounted`: the picker below needs this
    // descendant context alive, and that is the check the analyzer requires.
    if (!context.mounted) return;
    if (!listed.ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(listed.error ?? 'could not list models')),
      );
      return;
    }
    final models = listed.models ?? const <ModelSummary>[];
    if (models.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No models available')),
      );
      return;
    }
    final transcript = _state.transcripts[activeId] ?? const SessionTranscript();
    final picked = await pickModel(context, models, transcript.currentModel);
    if (!mounted || picked == null) return;
    final result = await widget.client.sendCommand(
      activeId,
      'setModel',
      args: {'provider': picked.provider, 'id': picked.id},
    );
    if (!mounted || result.ok) return;
    messenger.showSnackBar(
      SnackBar(content: Text(result.error ?? 'could not switch the model')),
    );
  }

  void _close() {
    final active = _state.activeSessionId;
    if (active != null) widget.client.unsubscribe(active);
  }

  /// Picks one gallery image and arms it for the next send. A cancel is silent;
  /// a platform error and an over-cap image each get a visible reason. The
  /// messenger is captured before the picker's await, because this context is
  /// gone once it returns.
  Future<void> _pickAttachment(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final PickedImage? picked;
    try {
      picked = await (widget.pickImage ?? pickGalleryImage)();
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open the gallery')),
      );
      return;
    }
    if (!mounted) return;
    if (picked == null) return;
    if (!withinAttachmentCap(picked.bytes.length)) {
      messenger.showSnackBar(
        const SnackBar(content: Text('That image is too large to send')),
      );
      return;
    }
    setState(() => _attachment = picked);
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
    // in sync with it.
    theme: ThemeData(brightness: Brightness.light),
    darkTheme: ThemeData(brightness: Brightness.dark),
    home: Builder(builder: _home),
    navigatorKey: _navigatorKey,
  );

  /// The sessions header. The host is the useful half of the paired address, and
  /// the port is included because pairing accepts a non-default one.
  String _sessionsTitle() {
    final endpoint = _endpoint;
    if (endpoint == null) return 'pi sessions';
    return 'pi sessions · ${endpoint.encode()}';
  }

  Widget _home(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_authenticated) {
      return PairingScreen(
        onSubmit: _pair,
        lastError: _state.lastError ?? _bootstrapError,
        busy:
            _state.status == HubConnectionStatus.connecting ||
            _state.status == HubConnectionStatus.authenticating,
        initialHost: _endpoint?.host ?? '',
        initialPort: _endpoint?.port.toString() ?? '8787',
      );
    }

    // The list is always the `home` route. The transcript, when one is open, is
    // a pushed sibling route above it (see [_syncTranscriptRoute]).
    return Scaffold(
      appBar: AppBar(
        // Naming the hub is the only place the paired address is visible once
        // pairing is done — which is exactly when a wrong host is hardest to
        // notice, since everything else looks the same.
        title: Text(_sessionsTitle()),
        actions: [
          IconButton(
            key: const Key('change-hub'),
            icon: const Icon(Icons.settings_ethernet),
            tooltip: 'Change hub',
            onPressed: _changeHub,
          ),
        ],
      ),
      body: _withStatusBanner(
        SessionList(
          sessions: _state.sessions,
          onOpen: _open,
          onKill: (session) => _kill(session, context),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('start-session'),
        tooltip: 'Start a session',
        onPressed: () => _start(context),
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
    final usage = transcript.contextUsage;
    final usageLabel = usage == null ? null : formatContextUsage(usage);
    // A running compaction takes the reading's slot: the number is exactly what
    // the compaction is about to invalidate, and an app bar that sits unchanged
    // for the length of a summarization call reads as a hang.
    final barLabel = transcript.compacting ? 'Compacting…' : usageLabel;
    final attachmentsEnabled =
        _state.capabilities.contains(capabilityAttachments);
    final view = Scaffold(
      appBar: AppBar(
        // The reading takes priority over the name: the name is a reminder of
        // which session this is, while the reading is a number you cannot guess
        // from anything else on screen. So the name is the flexible half, and it
        // is the one that gets cut when the two compete for room.
        //
        // The reading is laid out before the name (non-flex children are measured
        // first) and is never ellipsized. At a large text scale it can want more
        // room than the title has at all, which would overflow the row — so it is
        // capped to the available width and scaled down rather than truncated:
        // a slightly smaller number beats a cut-off one.
        title: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              Expanded(
                child: Text(
                  _sessionLabel(activeId),
                  key: const Key('session-name'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _close,
          tooltip: 'Sessions',
        ),
        actions: [
          SessionMenuButton(
            muted: _notifyPolicy.isMuted(activeId),
            onToggleNotify: () => _toggleNotify(activeId),
            thinkingLevel: transcript.thinkingLevel,
            model: transcript.currentModel?.name,
            onCompact: () => _compact(context),
            onRename: () => _rename(activeId, context),
            onThinkingLevel: () => _setThinkingLevel(activeId, context),
            onModel: () => _setModel(activeId, context),
            // New and fork replace the session: only a hub advertising the
            // capability can, and without it the items are omitted rather than
            // offered and refused.
            onNewSession: _state.capabilities.contains(capabilitySessionControl)
                ? () => _newSession(context)
                : null,
            onFork: _state.capabilities.contains(capabilitySessionControl)
                ? () => _fork(activeId, context)
                : null,
            onTree: _state.capabilities.contains(capabilitySessionControl)
                ? () => _navigateTree(activeId, context)
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
                    // Keyed on the session: a new session is a new view, so its
                    // scroll position and following state are not inherited from
                    // the last one.
                    TranscriptView(
                      key: ValueKey(activeId),
                      transcript: transcript,
                      onLoadOlder: () => widget.client.loadOlder(activeId),
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
            attachment: attachmentsEnabled ? _attachment : null,
            onAttach: attachmentsEnabled
                ? () => _pickAttachment(context)
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
            // canPop TRUE: a real route pops itself, so the predictive preview is
            // not suppressed. This PopScope is LOAD-BEARING, not decorative:
            // without its PopEntry a gesture commit would pop the route with
            // nothing left to call `_close()`, and the next state emit would push
            // the transcript straight back over the list.
            canPop: true,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) return;
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
  Widget _withStatusBanner(Widget child) {
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
                  child: Text(showError ? error : 'Reconnecting to the hub…'),
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

/// A tree node the user tapped, waiting for the `leaf` event that proves pi
/// navigated to it. Carries its session so a leaf for another session cannot
/// consume it.
class _PendingTreeTap {
  final String sessionId;
  final TreeNodeSummary node;

  const _PendingTreeTap({required this.sessionId, required this.node});
}
