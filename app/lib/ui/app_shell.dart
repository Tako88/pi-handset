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

import 'package:flutter/material.dart';

import '../client/endpoint_store.dart';
import '../client/context_usage.dart';
import '../client/hub_client.dart';
import '../client/token_store.dart';
import 'compose_bar.dart';
import 'pairing_screen.dart';
import 'session_list.dart';
import 'status_indicator.dart';
import 'transcript_view.dart';

class PiDroidApp extends StatefulWidget {
  const PiDroidApp({
    super.key,
    required this.client,
    required this.tokenStore,
  });

  final HubClient client;
  final TokenStore tokenStore;

  @override
  State<PiDroidApp> createState() => _PiDroidAppState();
}

class _PiDroidAppState extends State<PiDroidApp> {
  late HubClientState _state = widget.client.state;
  StreamSubscription<HubClientState>? _subscription;
  bool _loading = true;
  bool _authenticated = false;
  HubEndpoint? _endpoint;

  /// The endpoint of an in-flight pairing. Persisted only once authentication
  /// succeeds, so a typo'd host is never saved and auto-dialled.
  HubEndpoint? _pendingEndpoint;

  /// A bootstrap failure that is not a client error.
  String? _bootstrapError;

  /// The last error the user dismissed, so the banner does not re-show it.
  String? _dismissedError;

  @override
  void initState() {
    super.initState();
    _subscription = widget.client.changes.listen(_onState);
    _bootstrap();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
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

  void _open(SessionSummary session) =>
      widget.client.subscribe(session.sessionId);

  /// Starts an app-started session. The hub answers with a result; a refusal
  /// (e.g. the cap is reached) is shown, never swallowed. [context] is the
  /// sessions-view context, below `MaterialApp`, so its `ScaffoldMessenger` is
  /// an ancestor.
  void _start(BuildContext context) {
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
            child: _withStatusBanner(
              // Keyed on the session: a new session is a new view, so its scroll
              // position and following state are not inherited from the last one.
              TranscriptView(key: ValueKey(activeId), transcript: transcript),
            ),
          ),
          StatusIndicator(transcript: transcript),
          ComposeBar(
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
