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
import '../client/context_usage.dart';
import '../client/hub_client.dart';
import '../client/notification_presenter.dart';
import '../client/settle_notification.dart';
import '../client/token_store.dart';
import '../protocol/protocol.dart';
import 'command_suggestions.dart';
import 'compose_bar.dart';
import 'folder_browser.dart';
import 'pairing_screen.dart';
import 'session_list.dart';
import 'status_indicator.dart';
import 'transcript_view.dart';

class PiDroidApp extends StatefulWidget {
  const PiDroidApp({
    super.key,
    required this.client,
    required this.tokenStore,
    required this.notifications,
    this.initialSessionId,
  });

  final HubClient client;
  final TokenStore tokenStore;

  /// The platform notification surface. `main.dart` passes the real one; tests
  /// pass a fake.
  final NotificationPresenter notifications;

  /// A session to open once authenticated, from a notification tap that cold
  /// started the app, or null for an ordinary launch.
  final String? initialSessionId;

  @override
  State<PiDroidApp> createState() => _PiDroidAppState();
}

class _PiDroidAppState extends State<PiDroidApp> with WidgetsBindingObserver {
  late HubClientState _state = widget.client.state;
  StreamSubscription<HubClientState>? _subscription;
  StreamSubscription<String>? _openRequests;
  StreamSubscription<AgentSettledEvent>? _settlesSub;
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

  /// The endpoint of an in-flight pairing. Persisted only once authentication
  /// succeeds, so a typo'd host is never saved and auto-dialled.
  HubEndpoint? _pendingEndpoint;

  /// A bootstrap failure that is not a client error.
  String? _bootstrapError;

  /// The last error the user dismissed, so the banner does not re-show it.
  String? _dismissedError;

  /// The composer draft. The shell owns it because the suggestion panel reads
  /// the text to filter and writes a picked `/name ` back into the field.
  final TextEditingController _composer = TextEditingController();

  /// The composer field's focus, held here so a command pick can return focus
  /// to the field.
  final FocusNode _composerFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _pendingOpenSessionId = widget.initialSessionId;
    _subscription = widget.client.changes.listen(_onState);
    _openRequests = widget.notifications.openSessionRequests.listen(_queueOpen);
    _settlesSub = widget.client.settles.listen(_onSettle);
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
    // The user is now looking at this session, so any shade entry for it is
    // stale. `cancel` on a missing id is a no-op.
    unawaited(
      widget.notifications.cancel(id: notificationIdForSession(sessionId)),
    );
  }

  /// A settle broadcast: notify unless the app is foregrounded on that session.
  void _onSettle(AgentSettledEvent event) {
    if (!mounted) return;
    if (!shouldNotifyOnSettle(
      _presence,
      _state.activeSessionId,
      event.sessionId,
    )) {
      // The session is on screen; clear any entry a backgrounded settle left.
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

  void _onState(HubClientState state) {
    if (!mounted) return;
    final pending =
        state.status == HubConnectionStatus.connected ? _pendingEndpoint : null;
    setState(() {
      _state = state;
      if (state.status == HubConnectionStatus.connected) {
        // Sticky: once paired, a later drop shows the main UI with a banner
        // rather than throwing the user back to pairing.
        _authenticated = true;
        if (pending != null) _pendingEndpoint = null;
      }
    });
    if (pending != null) unawaited(widget.tokenStore.writeEndpoint(pending));
    if (state.status == HubConnectionStatus.connected && !_foregroundStarted) {
      // Started here, while the app is foregrounded, never from the background:
      // Android forbids a background FGS start on API 31+.
      _foregroundStarted = true;
      unawaited(widget.notifications.startForeground());
    }
    _drainOpen();
  }

  Future<void> _bootstrap() async {
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
      _state = widget.client.state;
    });
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

  void _close() {
    final active = _state.activeSessionId;
    if (active != null) widget.client.unsubscribe(active);
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

    final activeId = _state.activeSessionId;
    if (activeId == null) {
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

    final transcript =
        _state.transcripts[activeId] ?? const SessionTranscript();
    final usage = transcript.contextUsage;
    final usageLabel = usage == null ? null : formatContextUsage(usage);
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
              if (usageLabel != null)
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
                        usageLabel,
                        key: const Key('context-usage'),
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
            onSend: (text) => widget.client.sendCommand(
              activeId,
              'prompt',
              args: {'text': text},
            ),
            onAbort: () => widget.client.sendCommand(activeId, 'abort'),
          ),
        ],
      ),
    );

    // The transcript is one level in, so the system back button must close it
    // rather than exit the app. It routes through _close(), the same path as the
    // AppBar arrow, so the two ways back cannot drift apart.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: view,
    );
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
