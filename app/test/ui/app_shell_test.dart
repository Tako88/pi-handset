// The app root. It must bootstrap from a remembered endpoint + token, drive the
// UI from the client's `changes` stream, and open a session's transcript on tap.
// It must also stay honest about failure: a resync give-up, a refused send, a
// failed pairing and a broken store all have to reach the screen.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/endpoint_store.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/client/settle_notification.dart';
import 'package:pi_droid/client/token_store.dart';
import 'package:pi_droid/ui/app_shell.dart';
import 'package:pi_droid/ui/folder_browser.dart';
import 'package:pi_droid/ui/pairing_screen.dart';

import '../client/support/fakes.dart';

const String testToken =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

/// The root shows a busy spinner while authenticating, so `pumpAndSettle` never
/// settles. Pump a bounded number of frames instead.
Future<void> pumpBootstrap(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

Future<void> settle(WidgetTester tester, FakeScheduler scheduler) async {
  await tester.pump();
  scheduler.flushNotifications();
  await tester.pump();
}

/// Android's back button as the engine delivers it: a `popRoute` message on
/// `flutter/navigation`. A widget test has no real activity to exit, so an
/// unhandled pop is simply a no-op — which is exactly how it should look.
/// Settles afterwards, because the handler's state change arrives through the
/// client's scheduler like any other notification.
Future<void> pressSystemBack(WidgetTester tester, FakeScheduler scheduler) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
    (_) {},
  );
  await settle(tester, scheduler);
}

/// Pumps the app with the phone reporting [brightness] as its dark-mode setting.
///
/// The ambient `MediaQuery` is supplied explicitly rather than by setting
/// `platformBrightnessTestValue`: that override only reaches a tree that has not
/// been pumped yet, so a second pump in the same test would silently keep the
/// first scheme and the assertion would be vacuous.
Future<void> pumpWithBrightness(
  WidgetTester tester,
  Harness harness,
  Brightness brightness,
) async {
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(platformBrightness: brightness),
      child: harness.app(),
    ),
  );
  // A theme change is animated (`AnimatedTheme`), so the new scheme is only
  // fully painted once that 200ms animation has been advanced.
  await tester.pump(const Duration(milliseconds: 300));
  await pumpBootstrap(tester);
}

/// The colour scheme the rendered tree actually paints with — read from the
/// live element, not from the MaterialApp constructor.
ColorScheme renderedScheme(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(Scaffold).first)).colorScheme;

Map<String, Object?> usageFrame(int? tokens, int contextWindow) => {
  'protocolVersion': 1,
  'type': 'event',
  'payload': {'kind': 'usage', 'tokens': tokens, 'contextWindow': contextWindow},
};

Map<String, Object?> sessionsFrame(List<Map<String, Object?>> sessions) => {
  'protocolVersion': 1,
  'type': 'sessions',
  'sessions': sessions,
};

/// A `sessions` frame from a hub that advertises folder browsing. The plain
/// [sessionsFrame] above omits it, standing in for an old hub.
Map<String, Object?> capableSessionsFrame(
  List<Map<String, Object?>> sessions,
) => {
  'protocolVersion': 1,
  'type': 'sessions',
  'sessions': sessions,
  'capabilities': const ['list-dirs', 'project-session'],
};

Map<String, Object?> settledFrame({
  String sessionId = 's1',
  String label = 'api refactor',
  String text = 'Done.',
  bool truncated = false,
}) => {
  'protocolVersion': 1,
  'type': 'agent-settled',
  'sessionId': sessionId,
  'label': label,
  'text': text,
  'truncated': truncated,
};

const sessionS1 = {'sessionId': 's1', 'label': 'api refactor', 'agentState': 'idle'};
const sessionS2 = {'sessionId': 's2', 'label': 'second session', 'agentState': 'idle'};
const appSessionA1 = {
  'sessionId': 'a1',
  'label': 'New session',
  'agentState': 'idle',
  'origin': 'app',
};

/// A snapshot with [count] flattened message entries — enough to overflow the
/// 600px test viewport so scroll position is observable.
Map<String, Object?> snapshotFrame(String sessionId, int count) => {
  'protocolVersion': 1,
  'type': 'snapshot',
  'sessionId': sessionId,
  'lastSeq': 1,
  'agentState': 'idle',
  'entries': [
    for (var i = 0; i < count; i++) {'type': 'assistant', 'text': 'message $i'},
  ],
  'truncated': false,
};

class Harness {
  Harness({String? token = testToken, HubEndpoint? endpoint, TokenStore? tokenStore})
    : store = tokenStore ?? InMemoryTokenStore(initial: token, initialEndpoint: endpoint) {
    client = HubClient(
      socketFactory: factory.call,
      scheduler: scheduler,
      tokenStore: store,
      frameInterval: const Duration(milliseconds: 16),
    );
  }

  final FakeSocketFactory factory = FakeSocketFactory();
  final FakeScheduler scheduler = FakeScheduler();
  final TokenStore store;
  final FakeNotificationPresenter notifications = FakeNotificationPresenter();
  late final HubClient client;

  Widget app({String? initialSessionId}) => PiDroidApp(
    client: client,
    tokenStore: store,
    notifications: notifications,
    initialSessionId: initialSessionId,
  );
}

/// A token store whose endpoint read fails, standing in for a broken platform
/// keystore.
class ThrowingTokenStore extends InMemoryTokenStore {
  @override
  Future<HubEndpoint?> readEndpoint() async =>
      throw StateError('storage unavailable');
}

void main() {
  testWidgets('the app renders dark when the phone is dark', (tester) async {
    await pumpWithBrightness(
      tester,
      Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787)),
      Brightness.light,
    );
    final light = renderedScheme(tester);

    await pumpWithBrightness(
      tester,
      Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787)),
      Brightness.dark,
    );
    final dark = renderedScheme(tester);

    expect(light.brightness, Brightness.light);
    expect(dark.brightness, Brightness.dark);
    // The colours themselves must change: a `themeMode`-only change that never
    // reached a second scheme would still satisfy the brightness assertions.
    expect(
      dark.surface.computeLuminance(),
      lessThan(light.surface.computeLuminance()),
    );
  });

  testWidgets('the session list names the hub it is attached to', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    // The address is typed during pairing and then never shown again, so with
    // the phone on Tailscale and more than one hub reachable there is nothing
    // on screen that says which machine this list came from.
    expect(find.text('pi sessions · 10.0.0.5:8787'), findsOneWidget);
  });

  testWidgets('the transcript app bar shows the context usage', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await tester.tap(find.text('api refactor'));
    await settle(tester, h.scheduler);

    h.factory.last.receive(usageFrame(23400, 128000));
    await settle(tester, h.scheduler);

    expect(find.text('23k / 128k · 18%'), findsOneWidget);
  });

  testWidgets('an unknown token count renders as a question mark', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await tester.tap(find.text('api refactor'));
    await settle(tester, h.scheduler);

    h.factory.last.receive(usageFrame(null, 128000));
    await settle(tester, h.scheduler);

    expect(find.text('? / 128k'), findsOneWidget);
  });

  testWidgets('no usage reading renders no label at all', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await tester.tap(find.text('api refactor'));
    await settle(tester, h.scheduler);

    expect(find.byKey(const Key('context-usage')), findsNothing);
  });

  testWidgets('a long session name gives way to the context label', (
    tester,
  ) async {
    final longName = 'a session title that goes on and on ' * 10;
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(
      sessionsFrame([
        {'sessionId': 's1', 'label': longName, 'agentState': 'idle'},
      ]),
    );
    await settle(tester, h.scheduler);
    await tester.tap(find.textContaining('a session title'));
    await settle(tester, h.scheduler);

    h.factory.last.receive(usageFrame(23400, 128000));
    await settle(tester, h.scheduler);

    final name = tester.renderObject<RenderParagraph>(
      find.byKey(const Key('session-name')),
    );
    final label = tester.renderObject<RenderParagraph>(
      find.byKey(const Key('context-usage')),
    );
    // The reading is what must survive: the name is the one that gets cut.
    expect(name.didExceedMaxLines, isTrue, reason: 'the name must be the one cut');
    expect(
      label.size.width,
      closeTo(label.getMaxIntrinsicWidth(double.infinity), 1.0),
      reason: 'the context label must render at its full width',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short session name is not cut, so the test above can fail', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await tester.tap(find.text('api refactor'));
    await settle(tester, h.scheduler);

    h.factory.last.receive(usageFrame(23400, 128000));
    await settle(tester, h.scheduler);

    final name = tester.renderObject<RenderParagraph>(
      find.byKey(const Key('session-name')),
    );
    expect(name.didExceedMaxLines, isFalse);
  });

  testWidgets('a large text scale does not overflow the app bar', (
    tester,
  ) async {
    // A phone-sized viewport, not the 800px default: at 360dp the title slot is
    // genuinely too narrow for a large-text reading, which is the case this test
    // exists for.
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final longName = 'a session title that goes on and on ' * 10;
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: h.app(),
      ),
    );
    await pumpBootstrap(tester);
    h.factory.last.receive(
      sessionsFrame([
        {'sessionId': 's1', 'label': longName, 'agentState': 'idle'},
      ]),
    );
    await settle(tester, h.scheduler);
    await tester.tap(find.textContaining('a session title'));
    await settle(tester, h.scheduler);

    h.factory.last.receive(usageFrame(23400, 128000));
    await settle(tester, h.scheduler);

    // At three times the text size the reading is wider than the title slot. The
    // reading must still be whole — but the row must not overflow either, which
    // is the failure a plain `Row` would produce.
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('context-usage')), findsOneWidget);
  });

  testWidgets('a remembered endpoint and token auto-connect and list sessions', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    expect(h.factory.urls.single.toString(), 'ws://10.0.0.5:8787');
    final hello = h.factory.last.sentFrames.first;
    expect(hello['type'], 'hello');
    expect(hello['token'], testToken);
    expect(hello.containsKey('ticket'), isFalse);

    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    expect(find.text('api refactor'), findsOneWidget);
  });

  testWidgets(
    'tapping a session opens its transcript and compose sends a prompt',
    (tester) async {
      final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
      await tester.pumpWidget(h.app());
      await pumpBootstrap(tester);

      h.factory.last.receive(sessionsFrame([sessionS1]));
      await settle(tester, h.scheduler);

      await tester.tap(find.text('api refactor'));
      await settle(tester, h.scheduler);

      await tester.enterText(find.byKey(const Key('compose-field')), 'hi pi');
      await tester.tap(find.byKey(const Key('compose-send')));
      await tester.pump();

      final command = h.factory.last.sentFrames.last;
      expect(command['type'], 'command');
      expect(command['name'], 'prompt');
      expect(command['sessionId'], 's1');
      expect(command['args'], {'text': 'hi pi'});
    },
  );

  testWidgets('the system back button returns to the session list', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    await tester.tap(find.text('api refactor'));
    await settle(tester, h.scheduler);
    expect(find.byKey(const Key('compose-field')), findsOneWidget);

    await pressSystemBack(tester, h.scheduler);

    expect(find.byKey(const Key('compose-field')), findsNothing);
    expect(find.text('pi sessions · 10.0.0.5:8787'), findsOneWidget);
  });

  testWidgets('the keyboard does not cover the composer', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await tester.tap(find.text('api refactor'));
    await settle(tester, h.scheduler);

    // The keyboard, as the engine reports it: a bottom view inset. Scaffold's
    // resizeToAvoidBottomInset only promises to resize the BODY, so anything in
    // the bottomNavigationBar slot stays pinned under the keyboard. viewInsets
    // is in PHYSICAL pixels, hence the devicePixelRatio conversion.
    const keyboard = 300.0;
    final dpr = tester.view.devicePixelRatio;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard * dpr);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();

    final screen = tester.view.physicalSize.height / dpr;
    final compose = tester.getRect(find.byKey(const Key('compose-field')));
    expect(compose.bottom, lessThanOrEqualTo(screen - keyboard));
  });

  testWidgets('switching sessions does not carry over the scroll position', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    h.factory.last.receive(sessionsFrame([sessionS1, sessionS2]));
    await settle(tester, h.scheduler);

    // Pre-load s2 so the switch back to it is immediate — no empty-transcript
    // frame in between, which would unmount the view and dispose its state.
    h.client.subscribe('s2');
    await settle(tester, h.scheduler);
    h.factory.last.receive(snapshotFrame('s2', 60));
    await settle(tester, h.scheduler);
    await tester.pump();
    await tester.pump();

    // Switch to s1, populate it tall, and scroll away from the bottom.
    h.client.subscribe('s1');
    await settle(tester, h.scheduler);
    h.factory.last.receive(snapshotFrame('s1', 60));
    await settle(tester, h.scheduler);
    await tester.pump();
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(
      find.byIcon(Icons.arrow_downward),
      findsOneWidget,
      reason: 'the setup must really scroll away before asserting the switch',
    );

    // Switch back to the cached s2 while the transcript view stays mounted —
    // the state-reuse path the session key exists to break.
    h.client.subscribe('s2');
    await settle(tester, h.scheduler);
    await tester.pump();
    await tester.pump();

    expect(
      find.text('message 59'),
      findsOneWidget,
      reason: 'a freshly opened session opens at its newest row',
    );
    expect(
      find.byIcon(Icons.arrow_downward),
      findsNothing,
      reason: "s1's scroll position and following state must not leak into s2",
    );
  });

  testWidgets('a refused prompt reaches the screen', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await tester.tap(find.text('api refactor'));
    await settle(tester, h.scheduler);

    await tester.enterText(find.byKey(const Key('compose-field')), 'hi pi');
    await tester.tap(find.byKey(const Key('compose-send')));
    await tester.pump();
    final id = h.factory.last.sentFrames.last['id']! as String;

    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': id,
      'ok': false,
      'error': 'no active session',
    });
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('no active session'), findsOneWidget);
  });

  testWidgets('a pairing that never authenticates does not persist the endpoint', (
    tester,
  ) async {
    final h = Harness(token: null);
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    await tester.enterText(find.byKey(const Key('pairing-host')), '10.0.0.9');
    await tester.enterText(find.byKey(const Key('pairing-code')), 'ABCD2345');
    await tester.tap(find.byKey(const Key('pairing-submit')));
    await tester.pump();
    expect(h.factory.urls.single.host, '10.0.0.9');

    // The hub rejects the ticket by closing; nothing was ever paired.
    h.factory.last.remoteClose(1001);
    await tester.pump();
    h.scheduler.flushNotifications();
    await tester.pump();

    expect(await h.store.readEndpoint(), isNull);
    expect(await h.store.read(), isNull);
    // The dead end must be visible, and the single-use code must be gone so a
    // fresh one can be typed.
    expect(
      find.textContaining('before authenticating'),
      findsOneWidget,
    );
    expect(find.text('ABCD2345'), findsNothing);
  });

  testWidgets('a successful pairing persists the endpoint only after auth', (
    tester,
  ) async {
    final h = Harness(token: null);
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    await tester.enterText(find.byKey(const Key('pairing-host')), '10.0.0.9');
    await tester.enterText(find.byKey(const Key('pairing-code')), 'ABCD2345');
    await tester.tap(find.byKey(const Key('pairing-submit')));
    await tester.pump();

    expect(await h.store.readEndpoint(), isNull);

    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'paired',
      'token': testToken,
    });
    await tester.pump();
    h.scheduler.flushNotifications();
    await tester.pump();
    await tester.pump();

    expect(
      await h.store.readEndpoint(),
      const HubEndpoint(host: '10.0.0.9', port: 8787),
    );
    expect(await h.store.read(), testToken);
  });

  testWidgets('a resync give-up is visible while connected, and dismissible', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await tester.tap(find.text('api refactor'));
    await settle(tester, h.scheduler);

    for (var i = 0; i <= HubClient.maxConsecutiveResyncs; i++) {
      h.factory.last.receive({
        'protocolVersion': 1,
        'type': 'resync-required',
        'sessionId': 's1',
        'reason': 'backpressure',
      });
    }
    await settle(tester, h.scheduler);

    expect(h.client.state.status, HubConnectionStatus.connected);
    expect(find.textContaining('gave up resyncing'), findsOneWidget);

    await tester.tap(find.byKey(const Key('dismiss-error')));
    await tester.pump();

    expect(find.textContaining('gave up resyncing'), findsNothing);
  });

  testWidgets('a failing endpoint read is visible, not an eternal spinner', (
    tester,
  ) async {
    final store = ThrowingTokenStore();
    final client = HubClient(
      socketFactory: FakeSocketFactory().call,
      scheduler: FakeScheduler(),
      tokenStore: store,
    );
    await tester.pumpWidget(
      PiDroidApp(
        client: client,
        tokenStore: store,
        notifications: FakeNotificationPresenter(),
      ),
    );
    await pumpBootstrap(tester);

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('storage unavailable'), findsOneWidget);
  });

  testWidgets('change hub clears the saved endpoint and token', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('change-hub')));
    await tester.pumpAndSettle();

    expect(find.byType(PairingScreen), findsOneWidget);
    expect(await h.store.readEndpoint(), isNull);
    expect(await h.store.read(), isNull);
  });

  testWidgets('the sessions view starts an app session', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('start-session')));
    await tester.pump();

    final frame = h.factory.last.sentFrames.last;
    expect(frame['type'], 'start-session');
    expect(frame['id'], isNotEmpty);
  });

  testWidgets('a refused start shows the error verbatim', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('start-session')));
    await tester.pump();
    final id = h.factory.last.sentFrames.last['id'];

    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': id,
      'ok': false,
      'error': 'too many app sessions',
    });
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('too many app sessions'), findsOneWidget);
  });

  testWidgets('the kill button kills an app session', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1, appSessionA1]));
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('kill-a1')));
    await tester.pump();

    final frame = h.factory.last.sentFrames.last;
    expect(frame['type'], 'kill-session');
    expect(frame['sessionId'], 'a1');
  });

  testWidgets('with the folder capabilities the FAB offers a chooser', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(capableSessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('start-session')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('quick-session')), findsOneWidget);
    expect(find.byKey(const Key('open-project')), findsOneWidget);
    // Opening the chooser must not start anything by itself.
    expect(
      h.factory.last.sentFrames.where((f) => f['type'] == 'start-session'),
      isEmpty,
    );
  });

  testWidgets('open a project pushes the browser, and back returns to the list', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(capableSessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('start-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-project')));
    // The browser shows a spinner until its listing arrives, so settle no
    // further than the route transition.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(FolderBrowserScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(FolderBrowserScreen), findsNothing);
    expect(find.text('pi sessions · 10.0.0.5:8787'), findsOneWidget);
  });

  testWidgets('a late quick-start reply after unmount is ignored', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(capableSessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('start-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quick-session')));
    await tester.pump();

    final id = h.factory.last.sentFrames.last['id'];
    // Tear the app down while the start is still in flight.
    await tester.pumpWidget(const SizedBox.shrink());

    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': id,
      'ok': false,
      'error': 'too many app sessions',
    });
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------------
  // Settle notifications
  // -------------------------------------------------------------------------

  testWidgets('a settle for another session notifies while foreground', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1, sessionS2]));
    await settle(tester, h.scheduler);

    // Foregrounded on s1; s2 settles: the app must notify.
    await tester.tap(find.text('api refactor'));
    await settle(tester, h.scheduler);

    h.factory.last.receive(
      settledFrame(
        sessionId: 's2',
        label: 'second session',
        text: 'all  done',
      ),
    );
    await settle(tester, h.scheduler);

    expect(h.notifications.shown, hasLength(1));
    expect(h.notifications.shown.single.title, 'second session');
    // Whitespace is collapsed before it reaches the shade.
    expect(h.notifications.shown.single.body, 'all done');
    expect(h.notifications.shown.single.sessionId, 's2');
  });

  testWidgets('a settle for the displayed session does not notify', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await tester.tap(find.text('api refactor'));
    await settle(tester, h.scheduler);

    h.factory.last.receive(settledFrame(sessionId: 's1'));
    await settle(tester, h.scheduler);

    expect(h.notifications.shown, isEmpty);
  });

  testWidgets('a settle while backgrounded notifies', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await tester.tap(find.text('api refactor'));
    await settle(tester, h.scheduler);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    h.factory.last.receive(settledFrame(sessionId: 's1'));
    await settle(tester, h.scheduler);

    expect(h.notifications.shown, hasLength(1));
  });

  testWidgets('opening a session dismisses its stale notification', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    // On the list: a settle for s1 notifies even though the app is foreground.
    h.factory.last.receive(settledFrame(sessionId: 's1'));
    await settle(tester, h.scheduler);
    expect(h.notifications.shown, hasLength(1));

    // Opening s1 from the list makes that shade entry stale.
    await tester.tap(find.text('api refactor'));
    await settle(tester, h.scheduler);

    expect(
      h.notifications.cancelled,
      contains(notificationIdForSession('s1')),
    );
  });

  testWidgets('a settle for the displayed session clears its stale notification', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await tester.tap(find.text('api refactor'));
    await settle(tester, h.scheduler);

    // Backgrounded: the settle for the open session raises a notification.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    h.factory.last.receive(settledFrame(sessionId: 's1'));
    await settle(tester, h.scheduler);
    expect(h.notifications.shown, hasLength(1));

    // Back on that same session, the entry is now redundant.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    h.factory.last.receive(settledFrame(sessionId: 's1'));
    await settle(tester, h.scheduler);

    expect(
      h.notifications.cancelled,
      contains(notificationIdForSession('s1')),
    );
  });

  testWidgets('a cold tap opens the session only after authentication', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app(initialSessionId: 'sess-b'));
    await pumpBootstrap(tester);

    // The client has dialled and sent `hello`, but the hub has not yet
    // authenticated it. A `subscribe` now would be closed 4002 and loop.
    expect(
      h.factory.last.sentFrames.where((frame) => frame['type'] == 'subscribe'),
      isEmpty,
    );

    h.factory.last.receive(sessionsFrame([sessionS1, sessionS2]));
    await settle(tester, h.scheduler);

    final subscribes = h.factory.last.sentFrames
        .where((frame) => frame['type'] == 'subscribe')
        .toList();
    expect(subscribes, hasLength(1));
    expect(subscribes.single['sessionId'], 'sess-b');
  });

  testWidgets('a warm tap waits for authentication, then opens immediately', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    h.notifications.requestOpen.add('sess-b');
    await tester.pump();
    expect(
      h.factory.last.sentFrames.where((frame) => frame['type'] == 'subscribe'),
      isEmpty,
    );

    h.factory.last.receive(sessionsFrame([sessionS1, sessionS2]));
    await settle(tester, h.scheduler);
    expect(
      h.factory.last.sentFrames
          .where((frame) => frame['type'] == 'subscribe')
          .map((frame) => frame['sessionId']),
      ['sess-b'],
    );

    // Already connected: a further tap subscribes without waiting.
    h.notifications.requestOpen.add('s2');
    await tester.pump();
    expect(
      h.factory.last.sentFrames
          .where(
            (frame) => frame['type'] == 'subscribe' && frame['sessionId'] == 's2',
          )
          .length,
      1,
    );
  });

  testWidgets('an unknown tapped session returns to the list with the error', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app(initialSessionId: 'ghost'));
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    // The subscribe the queue sent schedules its own notify; flush that frame
    // so the transcript view is actually mounted.
    await settle(tester, h.scheduler);

    // The tap opened the transcript even though the session does not exist.
    expect(h.client.state.activeSessionId, 'ghost');
    expect(find.byKey(const Key('compose-field')), findsOneWidget);

    for (var i = 0; i <= HubClient.maxConsecutiveSessionGone; i++) {
      h.factory.last.receive({
        'protocolVersion': 1,
        'type': 'session-gone',
        'sessionId': 'ghost',
      });
    }
    await settle(tester, h.scheduler);

    // The UI returns to the session list rather than hanging on a transcript,
    // and says why.
    expect(h.client.state.activeSessionId, isNull);
    expect(find.byKey(const Key('compose-field')), findsNothing);
    expect(find.text('pi sessions · 10.0.0.5:8787'), findsOneWidget);
    expect(find.textContaining('the session ghost is gone'), findsOneWidget);
  });

  testWidgets('the foreground service starts once and stops on change hub', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    expect(h.notifications.permissionRequests, 1);
    expect(h.notifications.startForegroundCalls, 0);

    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    expect(h.notifications.startForegroundCalls, 1);

    // A later registry push must not start it a second time.
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    expect(h.notifications.startForegroundCalls, 1);

    await tester.tap(find.byKey(const Key('change-hub')));
    await tester.pumpAndSettle();
    expect(h.notifications.stopForegroundCalls, 1);
  });
}
