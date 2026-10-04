// The app root. It must bootstrap from a remembered endpoint + token, drive the
// UI from the client's `changes` stream, and open a session's transcript on tap.
// It must also stay honest about failure: a resync give-up, a refused send, a
// failed pairing and a broken store all have to reach the screen.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/attachment.dart';
import 'package:pi_droid/client/endpoint_store.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/client/hub_socket.dart';
import 'package:pi_droid/client/notification_policy.dart';
import 'package:pi_droid/client/settle_notification.dart';
import 'package:pi_droid/client/token_store.dart';
import 'package:pi_droid/platform/qr_scanner.dart';
import 'package:pi_droid/ui/app_shell.dart';
import 'package:pi_droid/ui/folder_browser.dart';
import 'package:pi_droid/ui/pairing_screen.dart';
import 'package:pi_droid/ui/transcript_view.dart';

import '../client/support/fakes.dart';

const String testToken =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

/// The root shows a spinner while bootstrapping, and a spinner animates
/// forever, so `pumpAndSettle` never settles. Pump a bounded number of frames
/// instead.
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

/// Opens [label] from the session list and pumps the push transition to
/// completion, so the transcript is onstage before the test interacts with it.
Future<void> openSession(WidgetTester tester, Harness h, String label) async {
  await tester.tap(find.text(label));
  await settle(tester, h.scheduler);
  await tester.pumpAndSettle();
}

/// Drives the platform's predictive-back gesture on `flutter/backgesture` and
/// returns whether the framework claimed it (a route's detector handled it).
///
/// The shape matters: `PredictiveBackEvent.isButtonEvent` is true for a zero
/// progress at a zero offset, and the detector declines button events, so a
/// "0.0 progress at [0,0]" gesture can never be claimed. Move the touch and the
/// progress to make it a real drag.
Future<bool> startBackGesture(WidgetTester tester) async {
  final reply = await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.backGesture.name,
    SystemChannels.backGesture.codec.encodeMethodCall(
      const MethodCall('startBackGesture', <String, Object?>{
        'touchOffset': <double>[20.0, 400.0],
        'progress': 0.25,
        'swipeEdge': 0,
      }),
    ),
    (_) {},
  );
  return SystemChannels.backGesture.codec.decodeEnvelope(reply!) as bool;
}

/// Sends the platform's predictive-back `commitBackGesture`.
Future<void> commitBackGesture(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.backGesture.name,
    SystemChannels.backGesture.codec.encodeMethodCall(
      const MethodCall('commitBackGesture'),
    ),
    (_) {},
  );
}

/// Sends the platform's predictive-back `cancelBackGesture`.
Future<void> cancelBackGesture(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.backGesture.name,
    SystemChannels.backGesture.codec.encodeMethodCall(
      const MethodCall('cancelBackGesture'),
    ),
    (_) {},
  );
}

/// Whether an `unsubscribe` was sent for [sessionId]. Frames carry
/// `protocolVersion` too, so match per field — never compare whole maps.
bool sentUnsubscribe(Harness h, String sessionId) => h.factory.last.sentFrames
    .where((f) => f['type'] == 'unsubscribe')
    .map((f) => f['sessionId'])
    .contains(sessionId);

/// The composer's current text.
String composeText(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const Key('compose-field')))
    .controller!
    .text;

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

/// A usage frame carrying the current model, as the bridge sends it.
Map<String, Object?> usageFrameWithModel(
  int? tokens,
  int contextWindow,
  String provider,
  String id,
  String name,
) => {
  'protocolVersion': 1,
  'type': 'event',
  'payload': {
    'kind': 'usage',
    'tokens': tokens,
    'contextWindow': contextWindow,
    'model': {'provider': provider, 'id': id, 'name': name},
  },
};

/// A `command-result` carrying a `listModels` listing.
Map<String, Object?> modelsReply(
  String id,
  List<Map<String, Object?>> models, {
  bool ok = true,
  String? error,
}) => {
  'protocolVersion': 1,
  'type': 'command-result',
  'id': id,
  'ok': ok,
  'models': models,
  'error': ?error,
};

/// A usage frame carrying the active thinking level, as the bridge sends it.
Map<String, Object?> usageFrameWithLevel(
  int? tokens,
  int contextWindow,
  String level,
) => {
  'protocolVersion': 1,
  'type': 'event',
  'payload': {
    'kind': 'usage',
    'tokens': tokens,
    'contextWindow': contextWindow,
    'thinkingLevel': level,
  },
};

/// A compaction announcement, as the bridge sends it: a `status` payload with no
/// message, which the app reads as transient state rather than as a notice row.
Map<String, Object?> compactingFrame(bool active) => {
  'protocolVersion': 1,
  'type': 'event',
  'payload': {'kind': 'status', 'event': 'compacting', 'active': active},
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

/// A `sessions` frame from a hub that can drive session-control commands.
Map<String, Object?> controlSessionsFrame(
  List<Map<String, Object?>> sessions,
) => {
  'protocolVersion': 1,
  'type': 'sessions',
  'sessions': sessions,
  'capabilities': const ['session-control'],
};

/// A `sessions` frame from a hub that can send image attachments.
Map<String, Object?> attachmentsSessionsFrame(
  List<Map<String, Object?>> sessions,
) => {
  'protocolVersion': 1,
  'type': 'sessions',
  'sessions': sessions,
  'capabilities': const ['attachments'],
};

/// A 1x1 PNG, enough for `Image.memory` to have real bytes to decode.
final Uint8List onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// A `command-result` carrying a `listTree` projection. [leafId] is the current
/// leaf (or `null`), which the picker marks.
Map<String, Object?> treeReply(
  String id,
  List<Map<String, Object?>> nodes, {
  bool ok = true,
  bool truncated = false,
  String? error,
  String? leafId,
}) => {
  'protocolVersion': 1,
  'type': 'command-result',
  'id': id,
  'ok': ok,
  'tree': nodes,
  'treeTruncated': truncated,
  'error': ?error,
  'leafId': leafId,
};

/// A relayed `leaf` event: the bridge (or pi on the PC) moved the leaf.
Map<String, Object?> leafFrame(String leafId) => {
  'protocolVersion': 1,
  'type': 'event',
  'payload': {'kind': 'leaf', 'leafId': leafId},
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
  Harness({
    String? token = testToken,
    HubEndpoint? endpoint,
    List<HubEndpoint>? endpoints,
    TokenStore? tokenStore,
    String? notifyState,
  }) : store = tokenStore ?? InMemoryTokenStore(
         initial: token,
         initialEndpoint: endpoint,
         initialEndpoints: endpoints,
         notifyState: notifyState,
       ) {
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

  Widget app({
    String? initialSessionId,
    Future<PickedImage?> Function()? pickImage,
    QrScanner? scanQr,
  }) => PiDroidApp(
    client: client,
    tokenStore: store,
    notifications: notifications,
    initialSessionId: initialSessionId,
    pickImage: pickImage,
    scanQr: scanQr ?? scanPairingQr,
  );
}

/// A scanner that returns whatever [uri] currently holds and counts invocations.
class FakeQrScanner {
  FakeQrScanner(this.uri);

  String? uri;
  int calls = 0;

  Future<String?> call(BuildContext context) async {
    calls++;
    return uri;
  }
}

/// The socket the client adopted: the one it did not close itself.
FakeHubSocket adoptedSocket(Harness h) =>
    h.factory.sockets.firstWhere((socket) => !socket.closedByClient);

/// A token store whose endpoint read fails, standing in for a broken platform
/// keystore.
class ThrowingTokenStore extends InMemoryTokenStore {
  @override
  Future<List<HubEndpoint>> readEndpoints() async =>
      throw StateError('storage unavailable');
}

/// A token store whose token read fails, standing in for a broken platform
/// keystore reached after the endpoint was already saved.
class ThrowingReadTokenStore extends InMemoryTokenStore {
  ThrowingReadTokenStore({super.initialEndpoint});

  @override
  Future<String?> read() async => throw PlatformException(
        code: 'storage_error',
        message: 'keystore unavailable',
      );
}

/// Boots a harness and opens the first session, the state every menu test needs.
Future<Harness> openFirstSession(WidgetTester tester) async {
  final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
  await tester.pumpWidget(h.app());
  await pumpBootstrap(tester);
  h.factory.last.receive(sessionsFrame([sessionS1]));
  await settle(tester, h.scheduler);
  await openSession(tester, h, 'api refactor');
  return h;
}

/// Boots a harness whose hub advertises `session-control` and opens `s1`, the
/// state the New/Fork tests need.
Future<Harness> openSessionControlSession(WidgetTester tester) async {
  final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
  await tester.pumpWidget(h.app());
  await pumpBootstrap(tester);
  h.factory.last.receive(controlSessionsFrame([sessionS1]));
  await settle(tester, h.scheduler);
  await openSession(tester, h, 'api refactor');
  return h;
}

/// Opens the session menu and taps its Model item, returning the `listModels`
/// command frame `_setModel` issues before showing its sheet.
Future<Map<String, Object?>> tapModelItem(WidgetTester tester, Harness h) async {
  await tester.tap(find.byKey(const Key('session-menu')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('session-menu-model')));
  await tester.pumpAndSettle();
  return h.factory.last.sentFrames.lastWhere((f) => f['name'] == 'listModels');
}

/// Opens the session menu and taps its Tree item, returning the `listTree`
/// command frame `_navigateTree` issues before showing its sheet.
Future<Map<String, Object?>> tapTreeItem(WidgetTester tester, Harness h) async {
  await tester.tap(find.byKey(const Key('session-menu')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('session-menu-tree')));
  await tester.pumpAndSettle();
  return h.factory.last.sentFrames.lastWhere((f) => f['name'] == 'listTree');
}

/// Feeds [h] an `ok:true` ack for the last `sessionTree` frame and settles.
Future<void> ackSessionTree(WidgetTester tester, Harness h) async {
  final frame = h.factory.last.sentFrames.lastWhere(
    (f) => f['name'] == 'sessionTree',
  );
  h.factory.last.receive({
    'protocolVersion': 1,
    'type': 'command-result',
    'id': frame['id'],
    'ok': true,
  });
  await settle(tester, h.scheduler);
}

/// Boots a harness whose hub advertises `attachments`, optionally with a fake
/// gallery picker, and opens `s1`.
Future<Harness> openAttachmentsSession(
  WidgetTester tester, {
  Future<PickedImage?> Function()? pickImage,
}) async {
  final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
  await tester.pumpWidget(h.app(pickImage: pickImage));
  await pumpBootstrap(tester);
  h.factory.last.receive(attachmentsSessionsFrame([sessionS1]));
  await settle(tester, h.scheduler);
  await openSession(tester, h, 'api refactor');
  return h;
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

  testWidgets('the header names the first candidate and counts the rest', (
    tester,
  ) async {
    final h = Harness(
      endpoints: const [
        HubEndpoint(host: '192.168.1.10', port: 8787),
        HubEndpoint(host: '100.64.1.2', port: 8787),
      ],
    );
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    adoptedSocket(h).receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    expect(find.text('pi sessions · 192.168.1.10:8787 +1'), findsOneWidget);
  });

  testWidgets('the transcript app bar shows the context usage', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

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
    await openSession(tester, h, 'api refactor');

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
    await openSession(tester, h, 'api refactor');

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
    await openSession(tester, h, 'api refactor');

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
    // The action sits in the same bar and must not push it into overflow either.
    expect(find.byKey(const Key('session-menu')), findsOneWidget);
  });

  testWidgets('choosing compact confirms before sending the command', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-compact')));
    await tester.pumpAndSettle();

    // The negative control: nothing is sent while the confirmation is up.
    expect(find.text('Compact session?'), findsOneWidget);
    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'compact'),
      isEmpty,
    );

    await tester.tap(find.byKey(const Key('compact-confirm-yes')));
    await settle(tester, h.scheduler);
    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'compact'),
      hasLength(1),
    );
  });

  testWidgets('cancelling compact sends nothing', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-compact')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('compact-confirm-no')));
    await settle(tester, h.scheduler);

    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'compact'),
      isEmpty,
    );
  });

  testWidgets('renaming sends the typed name', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('rename-field')), 'new name');
    await tester.pump();
    await tester.tap(find.byKey(const Key('rename-submit')));
    await settle(tester, h.scheduler);

    final frame = h.factory.last.sentFrames.last;
    expect(frame['name'], 'setSessionName');
    expect((frame['args']! as Map)['name'], 'new name');
  });

  testWidgets('choosing a thinking level sends it', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-thinking')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('thinking-low')));
    await settle(tester, h.scheduler);

    final frame = h.factory.last.sentFrames.last;
    expect(frame['name'], 'setThinkingLevel');
    expect((frame['args']! as Map)['level'], 'low');
  });

  testWidgets('the menu shows the level from a usage frame', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    h.factory.last.receive(usageFrameWithLevel(23400, 128000, 'high'));
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('session-menu-thinking-level')))
          .data,
      'high',
    );
  });

  testWidgets('a later usage frame updates the level shown', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    h.factory.last.receive(usageFrameWithLevel(23400, 128000, 'high'));
    await settle(tester, h.scheduler);
    h.factory.last.receive(usageFrameWithLevel(23400, 128000, 'low'));
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('session-menu-thinking-level')))
          .data,
      'low',
    );
  });

  testWidgets('choosing a model lists the models and sends the reference', (
    tester,
  ) async {
    final h = await openFirstSession(tester);

    final listFrame = await tapModelItem(tester, h);
    expect(listFrame['sessionId'], 's1');

    h.factory.last.receive(
      modelsReply(listFrame['id']! as String, [
        {
          'provider': 'anthropic',
          'id': 'claude-sonnet-4',
          'name': 'Claude Sonnet 4',
        },
        {'provider': 'openai', 'id': 'gpt-5', 'name': 'GPT-5'},
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('model-picker')), findsOneWidget);
    await tester.tap(find.byKey(const Key('model-openai-gpt-5')));
    await settle(tester, h.scheduler);

    final frame = h.factory.last.sentFrames.last;
    expect(frame['name'], 'setModel');
    // The reference, not the display name: the bridge resolves it through the
    // registry.
    expect(frame['args'], {'provider': 'openai', 'id': 'gpt-5'});
  });

  testWidgets('a refused model switch shows the error, not silence', (
    tester,
  ) async {
    final h = await openFirstSession(tester);

    final listFrame = await tapModelItem(tester, h);
    h.factory.last.receive(
      modelsReply(listFrame['id']! as String, [
        {'provider': 'openai', 'id': 'gpt-5', 'name': 'GPT-5'},
      ]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('model-openai-gpt-5')));
    await tester.pumpAndSettle();

    final setFrame = h.factory.last.sentFrames.lastWhere(
      (f) => f['name'] == 'setModel',
    );
    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': setFrame['id'],
      'ok': false,
      'error': 'model not accepted',
    });
    await settle(tester, h.scheduler);
    await tester.pump();

    expect(find.text('model not accepted'), findsOneWidget);
  });

  testWidgets('no models shows a message, not an empty sheet', (tester) async {
    final h = await openFirstSession(tester);

    final listFrame = await tapModelItem(tester, h);
    h.factory.last.receive(modelsReply(listFrame['id']! as String, []));
    await settle(tester, h.scheduler);
    await tester.pump();

    expect(find.byKey(const Key('model-picker')), findsNothing);
    expect(find.text('No models available'), findsOneWidget);
  });

  testWidgets('a failed model list shows the error, not an empty sheet', (
    tester,
  ) async {
    final h = await openFirstSession(tester);

    final listFrame = await tapModelItem(tester, h);
    h.factory.last.receive(
      modelsReply(
        listFrame['id']! as String,
        [],
        ok: false,
        error: 'hub down',
      ),
    );
    await settle(tester, h.scheduler);
    await tester.pump();

    // The list failed: the cause must reach the screen, and no picker may open
    // on the stale/empty listing.
    expect(find.byKey(const Key('model-picker')), findsNothing);
    expect(find.text('hub down'), findsOneWidget);
  });

  testWidgets('dismissing the model picker sends nothing and stays silent', (
    tester,
  ) async {
    final h = await openFirstSession(tester);

    final listFrame = await tapModelItem(tester, h);
    h.factory.last.receive(
      modelsReply(listFrame['id']! as String, [
        {'provider': 'openai', 'id': 'gpt-5', 'name': 'GPT-5'},
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('model-picker')), findsOneWidget);

    // The barrier outside the sheet: dismissing returns null, which must be a
    // silent no-op rather than a refusal or a phantom setModel. `pumpAndSettle`
    // (not `settle`) so the pop animation finishes and the sheet leaves the tree.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('model-picker')), findsNothing);
    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'setModel'),
      isEmpty,
    );
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('the menu hides new and fork on a hub without session-control', (
    tester,
  ) async {
    await openFirstSession(tester);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();

    // Prove the menu is genuinely open before asserting the new items are
    // absent: two `findsNothing`s also pass if the menu never opened at all.
    expect(find.byKey(const Key('session-menu-compact')), findsOneWidget);
    expect(find.byKey(const Key('session-menu-new')), findsNothing);
    expect(find.byKey(const Key('session-menu-fork')), findsNothing);
  });

  testWidgets('new session confirms before sending sessionNew', (tester) async {
    final h = await openSessionControlSession(tester);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-new')));
    await tester.pumpAndSettle();

    // The negative control: nothing is sent while the confirmation is up.
    expect(find.text('Start a new session?'), findsOneWidget);
    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'sessionNew'),
      isEmpty,
    );

    await tester.tap(find.byKey(const Key('new-session-confirm-yes')));
    await settle(tester, h.scheduler);
    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'sessionNew'),
      hasLength(1),
    );
  });

  testWidgets('cancelling new session sends nothing', (tester) async {
    final h = await openSessionControlSession(tester);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-session-confirm-no')));
    await settle(tester, h.scheduler);

    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'sessionNew'),
      isEmpty,
    );
  });

  testWidgets('a refused new session shows the error, not a success', (
    tester,
  ) async {
    final h = await openSessionControlSession(tester);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-session-confirm-yes')));
    await tester.pump();

    final newFrame = h.factory.last.sentFrames.lastWhere(
      (f) => f['name'] == 'sessionNew',
    );
    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': newFrame['id'],
      'ok': false,
      'error': 'the session cannot be replaced',
    });
    await settle(tester, h.scheduler);
    await tester.pump();

    // A refusal must surface verbatim. A replacement's only success signal is
    // the replacement itself, so the error must be the sole SnackBar — no
    // success confirmation may accompany it.
    expect(find.text('the session cannot be replaced'), findsOneWidget);
    expect(find.text('could not start a new session'), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('fork lists the tree, shows only user nodes and sends sessionFork', (
    tester,
  ) async {
    final h = await openSessionControlSession(tester);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-fork')));
    await tester.pumpAndSettle();

    final listFrame = h.factory.last.sentFrames.lastWhere(
      (f) => f['name'] == 'listTree',
    );
    expect(listFrame['sessionId'], 's1');

    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
        {'id': 'e2', 'parentId': 'e1', 'role': 'assistant', 'text': 'hi'},
        {'id': 'e3', 'parentId': 'e1', 'role': 'user', 'text': 'again'},
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tree-node-e1')), findsOneWidget);
    expect(find.byKey(const Key('tree-node-e3')), findsOneWidget);
    expect(find.byKey(const Key('tree-node-e2')), findsNothing);

    await tester.tap(find.byKey(const Key('tree-node-e3')));
    await settle(tester, h.scheduler);

    final forkFrame = h.factory.last.sentFrames.lastWhere(
      (f) => f['name'] == 'sessionFork',
    );
    expect((forkFrame['args']! as Map)['entryId'], 'e3');
  });

  testWidgets('a refused fork shows the error', (tester) async {
    final h = await openSessionControlSession(tester);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-fork')));
    await tester.pumpAndSettle();

    final listFrame = h.factory.last.sentFrames.lastWhere(
      (f) => f['name'] == 'listTree',
    );
    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
      ]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tree-node-e1')));
    await settle(tester, h.scheduler);

    final forkFrame = h.factory.last.sentFrames.lastWhere(
      (f) => f['name'] == 'sessionFork',
    );
    // The entry was invalidated between listing the tree and sending the fork
    // (the plan's FM5): the bridge refuses it and the refusal must reach the
    // screen, not vanish into the awaited replacement.
    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': forkFrame['id'],
      'ok': false,
      'error': 'unknown entry',
    });
    await settle(tester, h.scheduler);
    await tester.pump();

    expect(find.text('unknown entry'), findsOneWidget);
    expect(find.text('could not fork the session'), findsNothing);
  });

  testWidgets('a refused tree list shows the error, not an empty sheet', (
    tester,
  ) async {
    final h = await openSessionControlSession(tester);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-fork')));
    await tester.pumpAndSettle();

    final listFrame = h.factory.last.sentFrames.lastWhere(
      (f) => f['name'] == 'listTree',
    );
    h.factory.last.receive(
      treeReply(
        listFrame['id']! as String,
        const [],
        ok: false,
        error: 'cannot read the tree',
      ),
    );
    await settle(tester, h.scheduler);
    await tester.pump();

    expect(find.byKey(const Key('tree-picker')), findsNothing);
    expect(find.text('cannot read the tree'), findsOneWidget);
  });

  testWidgets('the menu hides Tree on a hub without session-control', (
    tester,
  ) async {
    await openFirstSession(tester);
    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    // Prove the menu is open before asserting absence.
    expect(find.byKey(const Key('session-menu-compact')), findsOneWidget);
    expect(find.byKey(const Key('session-menu-tree')), findsNothing);
  });

  testWidgets('the menu shows and routes Tree with session-control', (
    tester,
  ) async {
    final h = await openSessionControlSession(tester);
    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-menu-tree')), findsOneWidget);

    await tester.tap(find.byKey(const Key('session-menu-tree')));
    await tester.pumpAndSettle();
    // Routing proof: the item issues a listTree.
    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'listTree'),
      hasLength(1),
    );
  });

  testWidgets('Tree lists all nodes and marks the current leaf', (tester) async {
    final h = await openSessionControlSession(tester);
    final listFrame = await tapTreeItem(tester, h);
    expect(listFrame['sessionId'], 's1');

    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
        {'id': 'e2', 'parentId': 'e1', 'role': 'assistant', 'text': 'hi'},
        {'id': 'e3', 'parentId': 'e2', 'role': 'user', 'text': 'again'},
      ], leafId: 'e2'),
    );
    await tester.pumpAndSettle();

    // The Tree picker offers assistant nodes too (Fork keeps them out).
    expect(find.byKey(const Key('tree-node-e1')), findsOneWidget);
    expect(find.byKey(const Key('tree-node-e2')), findsOneWidget);
    expect(find.byKey(const Key('tree-node-e3')), findsOneWidget);
    expect(find.byKey(const Key('tree-node-current-e2')), findsOneWidget);
    expect(find.byKey(const Key('tree-node-current-e1')), findsNothing);
  });

  testWidgets(
    'tapping the current leaf sends no command and says already there',
    (tester) async {
      final h = await openSessionControlSession(tester);
      final listFrame = await tapTreeItem(tester, h);
      h.factory.last.receive(
        treeReply(listFrame['id']! as String, [
          {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
          {'id': 'e3', 'parentId': 'e1', 'role': 'user', 'text': 'again'},
        ], leafId: 'e1'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('tree-node-e1')));
      await settle(tester, h.scheduler);

      // pi emits nothing for a same-leaf target, so a frame here would look
      // like a failure: the guard is local and sends nothing.
      expect(
        h.factory.last.sentFrames.where((f) => f['name'] == 'sessionTree'),
        isEmpty,
      );
      expect(find.text('Already at this point'), findsOneWidget);
    },
  );

  testWidgets(
    'tapping another node sends sessionTree, requests no history and shows no error',
    (tester) async {
      final h = await openSessionControlSession(tester);
      final listFrame = await tapTreeItem(tester, h);
      h.factory.last.receive(
        treeReply(listFrame['id']! as String, [
          {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
          {'id': 'e3', 'parentId': 'e1', 'role': 'user', 'text': 'again'},
        ], leafId: 'e1'),
      );
      await tester.pumpAndSettle();

      final requestsBefore = h.factory.last.sentFrames
          .where((f) => f['type'] == 'history-request')
          .length;

      await tester.tap(find.byKey(const Key('tree-node-e3')));
      await settle(tester, h.scheduler);

      final treeFrame = h.factory.last.sentFrames.lastWhere(
        (f) => f['name'] == 'sessionTree',
      );
      expect((treeFrame['args']! as Map)['entryId'], 'e3');

      h.factory.last.receive({
        'protocolVersion': 1,
        'type': 'command-result',
        'id': treeFrame['id'],
        'ok': true,
      });
      await settle(tester, h.scheduler);
      await tester.pump();

      // Checked after the ack: a request issued either right after the send or
      // on the ack both have to fail. The leaf event is the sole trigger.
      expect(
        h.factory.last.sentFrames
            .where((f) => f['type'] == 'history-request')
            .length,
        requestsBefore,
        reason: 'the leaf event is the sole re-baseline trigger',
      );

      // A successful navigation is silent: an unconditional SnackBar would
      // otherwise pass this and the refusal test together.
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets('a leaf event after a navigation re-requests history', (
    tester,
  ) async {
    final h = await openSessionControlSession(tester);
    final listFrame = await tapTreeItem(tester, h);
    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
        {'id': 'e3', 'parentId': 'e1', 'role': 'user', 'text': 'again'},
      ], leafId: 'e1'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tree-node-e3')));
    await settle(tester, h.scheduler);
    await ackSessionTree(tester, h);

    final requestsBefore = h.factory.last.sentFrames
        .where((f) => f['type'] == 'history-request')
        .length;

    h.factory.last.receive(leafFrame('e1'));
    await settle(tester, h.scheduler);

    final requests = h.factory.last.sentFrames
        .where((f) => f['type'] == 'history-request')
        .toList();
    expect(requests.length, requestsBefore + 1);
    expect(requests.last['sessionId'], 's1');
  });

  testWidgets('a user node prefills the composer when empty', (tester) async {
    final h = await openSessionControlSession(tester);
    final listFrame = await tapTreeItem(tester, h);
    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
      ], leafId: 'e3'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tree-node-e1')));
    await settle(tester, h.scheduler);
    await ackSessionTree(tester, h);

    // The ack is "accepted", not "navigated": prefill waits for the leaf.
    h.factory.last.receive(leafFrame('e3'));
    await settle(tester, h.scheduler);

    expect(composeText(tester), 'hello');
  });

  testWidgets('a non-empty composer is not overwritten', (tester) async {
    final h = await openSessionControlSession(tester);
    await tester.enterText(find.byKey(const Key('compose-field')), 'draft');

    final listFrame = await tapTreeItem(tester, h);
    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
      ], leafId: 'e3'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tree-node-e1')));
    await settle(tester, h.scheduler);
    await ackSessionTree(tester, h);
    h.factory.last.receive(leafFrame('e3'));
    await settle(tester, h.scheduler);

    // pi restores the text only into an empty editor; a draft wins.
    expect(composeText(tester), 'draft');
  });

  testWidgets('an assistant node does not prefill the composer', (tester) async {
    final h = await openSessionControlSession(tester);
    final listFrame = await tapTreeItem(tester, h);
    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
        {'id': 'e2', 'parentId': 'e1', 'role': 'assistant', 'text': 'hi'},
      ], leafId: 'e1'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tree-node-e2')));
    await settle(tester, h.scheduler);
    await ackSessionTree(tester, h);
    h.factory.last.receive(leafFrame('e1'));
    await settle(tester, h.scheduler);

    expect(composeText(tester), isEmpty);
  });

  testWidgets('a refused sessionTree shows the error and prefills nothing', (
    tester,
  ) async {
    final h = await openSessionControlSession(tester);
    final listFrame = await tapTreeItem(tester, h);
    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
      ], leafId: 'e3'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tree-node-e1')));
    await settle(tester, h.scheduler);

    final treeFrame = h.factory.last.sentFrames.lastWhere(
      (f) => f['name'] == 'sessionTree',
    );
    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': treeFrame['id'],
      'ok': false,
      'error': 'cannot navigate the tree while pi is working',
    });
    await settle(tester, h.scheduler);
    await tester.pump();

    expect(
      find.text('cannot navigate the tree while pi is working'),
      findsOneWidget,
    );
    // A refusal clears the pending tap: a later leaf must not prefill it.
    h.factory.last.receive(leafFrame('e3'));
    await settle(tester, h.scheduler);
    expect(composeText(tester), isEmpty);
  });

  testWidgets('an ack alone does not prefill', (tester) async {
    final h = await openSessionControlSession(tester);
    final listFrame = await tapTreeItem(tester, h);
    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
      ], leafId: 'e3'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tree-node-e1')));
    await settle(tester, h.scheduler);
    await ackSessionTree(tester, h);

    // No leaf event: the navigation is not known to have happened.
    expect(composeText(tester), isEmpty);
  });

  testWidgets('a post-ack failure reports the error and does not prefill', (
    tester,
  ) async {
    final h = await openSessionControlSession(tester);
    final listFrame = await tapTreeItem(tester, h);
    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
      ], leafId: 'e3'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tree-node-e1')));
    await settle(tester, h.scheduler);
    await ackSessionTree(tester, h);

    // The navigation fails after the ack, as a status error, with no leaf.
    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {
        'kind': 'status',
        'event': 'error',
        'message': 'cannot navigate the tree',
      },
    });
    await settle(tester, h.scheduler);
    await tester.pump();

    expect(find.text('cannot navigate the tree'), findsOneWidget);
    expect(composeText(tester), isEmpty);
  });

  testWidgets('a stale same-leaf tap is silent and prefills nothing', (
    tester,
  ) async {
    final h = await openSessionControlSession(tester);
    final listFrame = await tapTreeItem(tester, h);
    // listTree says the leaf is e1, but pi's leaf has since moved to e2.
    h.factory.last.receive(
      treeReply(listFrame['id']! as String, [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hello'},
        {'id': 'e2', 'parentId': 'e1', 'role': 'user', 'text': 'again'},
      ], leafId: 'e1'),
    );
    await tester.pumpAndSettle();

    // The tap is not the listed leaf (e1), so the local guard cannot catch it;
    // at pi it really is the current leaf, which early-returns with no event.
    await tester.tap(find.byKey(const Key('tree-node-e2')));
    await settle(tester, h.scheduler);
    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'sessionTree'),
      hasLength(1),
    );
    await ackSessionTree(tester, h);

    await tester.pump();
    expect(composeText(tester), isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('the menu shows the model from a usage frame', (tester) async {
    final h = await openFirstSession(tester);

    h.factory.last.receive(
      usageFrameWithModel(23400, 128000, 'anthropic', 'claude-sonnet-4', 'Claude Sonnet 4'),
    );
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('session-menu-model-name')))
          .data,
      'Claude Sonnet 4',
    );
  });

  testWidgets('the menu level follows the usage frame after a model switch', (
    tester,
  ) async {
    final h = await openFirstSession(tester);

    h.factory.last.receive(usageFrameWithLevel(23400, 128000, 'high'));
    await settle(tester, h.scheduler);

    final listFrame = await tapModelItem(tester, h);
    h.factory.last.receive(
      modelsReply(listFrame['id']! as String, [
        {
          'provider': 'anthropic',
          'id': 'claude-sonnet-4',
          'name': 'Claude Sonnet 4',
        },
        {'provider': 'openai', 'id': 'gpt-5', 'name': 'GPT-5'},
      ]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('model-openai-gpt-5')));
    await tester.pumpAndSettle();
    final setFrame = h.factory.last.sentFrames.lastWhere(
      (f) => f['name'] == 'setModel',
    );
    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': setFrame['id'],
      'ok': true,
    });
    await settle(tester, h.scheduler);

    // The switch cascades a clamping thinking-level change on pi's side, which
    // arrives as a fresh `usage` frame. The menu absorbs it rather than sticking
    // on the pre-switch level.
    h.factory.last.receive(usageFrameWithLevel(23400, 128000, 'low'));
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('session-menu-thinking-level')))
          .data,
      'low',
    );
  });

  testWidgets('a compaction shows in the app bar in place of the reading', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    h.factory.last.receive(usageFrame(23400, 128000));
    await settle(tester, h.scheduler);
    expect(find.byKey(const Key('context-usage')), findsOneWidget);

    h.factory.last.receive(compactingFrame(true));
    await settle(tester, h.scheduler);

    // What the user sees: the app bar says what is happening, in the slot the
    // reading occupied — the number is what the compaction is about to change.
    expect(tester.widget<Text>(find.byKey(const Key('compacting'))).data, 'Compacting…');
    expect(find.byKey(const Key('context-usage')), findsNothing);
  });

  testWidgets('the reading returns when the compaction ends', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    h.factory.last.receive(usageFrame(23400, 128000));
    await settle(tester, h.scheduler);
    h.factory.last.receive(compactingFrame(true));
    await settle(tester, h.scheduler);
    h.factory.last.receive(compactingFrame(false));
    await settle(tester, h.scheduler);

    // The indicator is transient state: it must clear itself, or the app bar
    // would claim a compaction is running forever.
    expect(find.byKey(const Key('compacting')), findsNothing);
    expect(find.byKey(const Key('context-usage')), findsOneWidget);
  });

  testWidgets('a compaction shows even with no reading yet', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    // No usage frame has arrived, so the slot is empty. The announcement must
    // still be visible — an auto-compaction can be the first thing that happens.
    expect(find.byKey(const Key('context-usage')), findsNothing);
    h.factory.last.receive(compactingFrame(true));
    await settle(tester, h.scheduler);

    expect(tester.widget<Text>(find.byKey(const Key('compacting'))).data, 'Compacting…');
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

      await openSession(tester, h, 'api refactor');

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

    await openSession(tester, h, 'api refactor');
    expect(find.byKey(const Key('compose-field')), findsOneWidget);

    await pressSystemBack(tester, h.scheduler);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('compose-field')), findsNothing);
    expect(find.text('pi sessions · 10.0.0.5:8787'), findsOneWidget);
    expect(sentUnsubscribe(h, 's1'), isTrue);
  });

  testWidgets('opening a session pushes the transcript as a route over the list', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    await openSession(tester, h, 'api refactor');

    // The transcript is a real route, so the platform has something to preview.
    expect(
      tester.state<NavigatorState>(find.byType(Navigator)).canPop(),
      isTrue,
    );
    expect(find.byKey(const Key('compose-field')), findsOneWidget);
    // The list is underneath and covered, so it is offstage.
    expect(find.text('pi sessions · 10.0.0.5:8787'), findsNothing);
  });

  testWidgets('a cold-start session id boots onto the transcript route', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app(initialSessionId: 's1'));
    await pumpBootstrap(tester);

    h.factory.last.receive(sessionsFrame([sessionS1]));
    // The queued open subscribes once authenticated; that subscribe schedules
    // the frame that pushes the route, so flush twice before pumping it in.
    await settle(tester, h.scheduler);
    await settle(tester, h.scheduler);
    await tester.pumpAndSettle();

    // A cold start carrying a session id boots straight into the transcript,
    // as a real route over the list — not onto the session list.
    expect(find.byKey(const Key('compose-field')), findsOneWidget);
    expect(
      tester.state<NavigatorState>(find.byType(Navigator)).canPop(),
      isTrue,
    );
  });

  testWidgets(
    'a notification tap while backgrounded opens the transcript on resume',
    (tester) async {
      final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
      await tester.pumpWidget(h.app());
      await pumpBootstrap(tester);
      h.factory.last.receive(sessionsFrame([sessionS1]));
      await settle(tester, h.scheduler);

      // The app is backgrounded, then a notification for s1 is tapped.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      h.notifications.requestOpen.add('s1');
      await tester.pump();
      await settle(tester, h.scheduler);

      // The open completed (the client subscribed) and the route is pushed even
      // while invisible: the transcript is what the user should see on return.
      // The 450 ms push animation is frozen while paused — resume is what
      // actually completes it.
      expect(h.client.state.activeSessionId, 's1');
      expect(
        h.factory.last.sentFrames
            .where((f) => f['type'] == 'subscribe')
            .map((f) => f['sessionId'])
            .where((id) => id == 's1'),
        hasLength(1),
      );
      expect(
        tester.state<NavigatorState>(find.byType(Navigator)).canPop(),
        isTrue,
      );

      // Resume in platform order.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('compose-field')), findsOneWidget);
    },
  );

  testWidgets('a predictive back gesture pops the transcript and unsubscribes', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    expect(await startBackGesture(tester), isTrue);
    await commitBackGesture(tester);
    // Deliberately flush the coalesced emit AFTER the pop transition finishes.
    // `_close()` unsubscribes, which schedules a deferred state emit; landing it
    // on a disposed route reaches `removeRoute` and trips
    // `assert(route._isInstalledIn(this))` unless the PopScope cleared the latch
    // first. Do NOT collapse this back into `settle` — that would hide the
    // ordering this test pins.
    await tester.pumpAndSettle();
    h.scheduler.flushNotifications();
    await tester.pump();

    expect(find.byKey(const Key('compose-field')), findsNothing);
    expect(find.text('pi sessions · 10.0.0.5:8787'), findsOneWidget);
    expect(sentUnsubscribe(h, 's1'), isTrue);
  });

  testWidgets('a cancelled predictive back gesture leaves the transcript up', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    expect(await startBackGesture(tester), isTrue);
    await cancelBackGesture(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('compose-field')), findsOneWidget);
    expect(sentUnsubscribe(h, 's1'), isFalse);
  });

  testWidgets(
    'back with the compact dialog open dismisses the dialog, not the transcript',
    (tester) async {
      final h = await openFirstSession(tester);

      await tester.tap(find.byKey(const Key('session-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('session-menu-compact')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('compact-confirm')), findsOneWidget);

      // A dialog has no predictive transition, so the transcript route — not
      // current under the dialog — declines the gesture.
      expect(await startBackGesture(tester), isFalse);
      await commitBackGesture(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('compact-confirm')), findsNothing);
      expect(find.byKey(const Key('compose-field')), findsOneWidget);
      expect(sentUnsubscribe(h, 's1'), isFalse);
    },
  );

  testWidgets(
    'back with the model picker open dismisses the sheet, not the transcript',
    (tester) async {
      final h = await openFirstSession(tester);

      final listFrame = await tapModelItem(tester, h);
      h.factory.last.receive(
        modelsReply(listFrame['id']! as String, [
          {'provider': 'openai', 'id': 'gpt-5', 'name': 'GPT-5'},
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('model-picker')), findsOneWidget);

      // A bottom sheet carries no predictive transition either.
      expect(await startBackGesture(tester), isFalse);
      await commitBackGesture(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('model-picker')), findsNothing);
      expect(find.byKey(const Key('compose-field')), findsOneWidget);
      expect(sentUnsubscribe(h, 's1'), isFalse);
    },
  );

  testWidgets('repeated sessions pushes do not push a second transcript', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    // The same session registers again: the route must be reused, not stacked.
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await tester.pumpAndSettle();

    // skipOffstage: false — a covered route is offstage, so the default finder
    // would miss a duplicate and the control would be vacuous.
    expect(
      find.byKey(const Key('compose-field'), skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('the transcript updates while it is the current route', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    h.factory.last.receive(snapshotFrame('s1', 1));
    await settle(tester, h.scheduler);
    await tester.pumpAndSettle();

    // A state change that arrives while the transcript is the current route must
    // be reflected on screen.
    expect(find.text('message 0'), findsOneWidget);
  });

  testWidgets(
    'switching sessions rebuilds the transcript in place without a second push',
    (tester) async {
      final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
      await tester.pumpWidget(h.app());
      await pumpBootstrap(tester);
      h.factory.last.receive(sessionsFrame([sessionS1, sessionS2]));
      await settle(tester, h.scheduler);
      await openSession(tester, h, 'api refactor');

      // A switch keeps the id non-null, so the route is reused and only its
      // content changes — no second push.
      h.notifications.requestOpen.add('s2');
      await tester.pump();
      await settle(tester, h.scheduler);
      await tester.pumpAndSettle();

      expect(find.text('second session'), findsOneWidget);
      expect(
        find.byKey(const Key('compose-field'), skipOffstage: false),
        findsOneWidget,
      );
    },
  );

  testWidgets('the draft survives leaving and re-entering the transcript', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    await tester.enterText(find.byKey(const Key('compose-field')), 'half typed');
    await tester.pump();

    await pressSystemBack(tester, h.scheduler);
    await tester.pumpAndSettle();
    await openSession(tester, h, 'api refactor');

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('compose-field')))
          .controller!
          .text,
      'half typed',
    );
  });

  testWidgets('the keyboard does not cover the composer', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

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

  testWidgets('typing / lists the session\'s commands and tapping one sends it',
      (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    // Reply to the per-open listCommands fetch with one command.
    final listId = h.factory.last.sentFrames.firstWhere(
      (frame) => frame['type'] == 'command' && frame['name'] == 'listCommands',
    )['id'];
    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': listId,
      'ok': true,
      'commands': [
        {'name': 'review', 'description': 'Review the working tree'},
      ],
    });
    await settle(tester, h.scheduler);

    // Nothing to suggest until the draft starts with a slash.
    expect(find.byKey(const Key('compose-suggestions')), findsNothing);

    await tester.enterText(find.byKey(const Key('compose-field')), '/');
    await tester.pump();

    expect(
      find.byKey(const Key('compose-suggestion-0-review')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('compose-suggestion-0-review')));
    await tester.pump();

    // Picking inserts; it must not also send. The field shows the inserted name
    // with a trailing space, and nothing has gone out yet.
    expect(
      tester.widget<TextField>(find.byKey(const Key('compose-field'))).controller!.text,
      '/review ',
    );
    expect(
      h.factory.last.sentFrames.where((f) => f['name'] == 'prompt'),
      isEmpty,
    );

    await tester.tap(find.byKey(const Key('compose-send')));
    await tester.pump();

    final command = h.factory.last.sentFrames.last;
    expect(command['type'], 'command');
    expect(command['name'], 'prompt');
    expect(command['args'], {'text': '/review'});
  });

  testWidgets('opening the / overlay refetches the session\'s commands',
      (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    // Reply to the per-open listCommands fetch with one command.
    final listId = h.factory.last.sentFrames.firstWhere(
      (frame) => frame['type'] == 'command' && frame['name'] == 'listCommands',
    )['id'];
    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': listId,
      'ok': true,
      'commands': [
        {'name': 'review', 'description': 'Review the working tree'},
      ],
    });
    await settle(tester, h.scheduler);

    await tester.enterText(find.byKey(const Key('compose-field')), '/');
    await tester.pump();
    final listFrames = h.factory.last.sentFrames
        .where((f) => f['type'] == 'command' && f['name'] == 'listCommands')
        .toList();
    // The subscribe-time fetch plus the overlay-open refetch.
    expect(listFrames, hasLength(2));
    expect(
      find.byKey(const Key('compose-suggestion-0-review')),
      findsOneWidget,
    );

    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': listFrames.last['id'],
      'ok': true,
      'commands': [
        {'name': 'deploy', 'description': 'Ship it'},
      ],
    });
    await settle(tester, h.scheduler);
    expect(
      find.byKey(const Key('compose-suggestion-0-deploy')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('compose-suggestion-0-review')), findsNothing);
  });

  testWidgets('the floating panel never overflows with the keyboard up at 2x',
      (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    // Copy the ambient MediaQuery rather than supplying a fresh one: a fresh
    // `MediaQueryData` zeroes `viewInsets`, and the keyboard assertion below
    // would then be vacuous.
    await tester.pumpWidget(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
          ),
          child: h.app(),
        ),
      ),
    );
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    final listId = h.factory.last.sentFrames.firstWhere(
      (frame) => frame['type'] == 'command' && frame['name'] == 'listCommands',
    )['id'];
    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': listId,
      'ok': true,
      'commands': [
        for (var i = 0; i < 10; i++)
          {
            'name': 'command-$i',
            'description':
                'A long description that wraps at twice the text scale ' * 2,
          },
      ],
    });
    await settle(tester, h.scheduler);

    await tester.enterText(find.byKey(const Key('compose-field')), '/');
    await tester.pump();

    const keyboard = 300.0;
    final dpr = tester.view.devicePixelRatio;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard * dpr);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('compose-suggestions')), findsOneWidget);

    final panel = tester.getSize(find.byKey(const Key('compose-suggestions')));
    final transcript = tester.getSize(find.byType(TranscriptView));
    // The panel shrinks to the transcript area rather than a fixed 200dp, which
    // is what makes the floating construction overflow-proof.
    expect(panel.height, lessThanOrEqualTo(transcript.height));

    final send = tester.getRect(find.byKey(const Key('compose-send')));
    final screen = tester.view.physicalSize.height / dpr;
    expect(send.bottom, lessThanOrEqualTo(screen - keyboard));
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
    // The transcript is now a pushed route: pump its transition before touching
    // it, or the drag below lands on an off-screen frame.
    await tester.pumpAndSettle();
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
    await openSession(tester, h, 'api refactor');

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

    expect(await h.store.readEndpoints(), isEmpty);
    expect(await h.store.read(), isNull);
    // The dead end must be visible, and the single-use code must be gone so a
    // fresh one can be typed.
    expect(
      find.textContaining('before authenticating'),
      findsOneWidget,
    );
    expect(find.text('ABCD2345'), findsNothing);
  });

  testWidgets(
    'two identical pairing failures still leave the form usable',
    (tester) async {
      final h = Harness(token: null);
      await tester.pumpWidget(h.app());
      await pumpBootstrap(tester);

      await tester.enterText(find.byKey(const Key('pairing-host')), '10.0.0.9');

      // The first attempt is rejected by the hub's deliberate silence; only the
      // client's watchdog ends it, with a constant message.
      await tester.enterText(find.byKey(const Key('pairing-code')), 'ABCD2345');
      await tester.tap(find.byKey(const Key('pairing-submit')));
      await tester.pump();
      h.scheduler.fireAuthWatchdog();
      await tester.pump();
      h.scheduler.flushNotifications();
      await tester.pump();
      final firstError = h.client.state.lastError;
      expect(firstError, isNotNull);

      // A second attempt fails with the *identical* message. The form must still
      // be usable — a repeat failure is precisely what a stateful gate would
      // re-wedge.
      await tester.enterText(find.byKey(const Key('pairing-code')), 'ABCD2345');
      await tester.tap(find.byKey(const Key('pairing-submit')));
      await tester.pump();
      h.scheduler.fireAuthWatchdog();
      await tester.pump();
      h.scheduler.flushNotifications();
      await tester.pump();
      expect(h.client.state.lastError, firstError);

      // A third submit must still reach the hub.
      await tester.enterText(find.byKey(const Key('pairing-code')), 'ABCD2345');
      await tester.tap(find.byKey(const Key('pairing-submit')));
      await tester.pump();
      expect(h.factory.urls.length, 3);
    },
  );

  testWidgets('a failed pairing attempt shows Pair again', (tester) async {
    final h = Harness(token: null);
    h.factory.onDial = () => Exception('connection refused');
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    await tester.enterText(find.byKey(const Key('pairing-host')), '10.0.0.9');
    await tester.enterText(find.byKey(const Key('pairing-code')), 'ABCD2345');
    await tester.tap(find.byKey(const Key('pairing-submit')));
    await tester.pump();
    h.scheduler.flushNotifications();
    await tester.pump();

    // The dial failed. The client stays `connecting` while it retries in the
    // background, so busy must follow the deliberate attempt, not the status:
    // the button has to read "Pair" again so a retry is possible.
    expect(find.text('Pair'), findsOneWidget);
    expect(find.byKey(const Key('pairing-busy')), findsNothing);
  });

  testWidgets(
    'a cold start whose dial never completes shows a usable pairing form',
    (tester) async {
      final held = Completer<HubSocket>();
      final h = Harness(
        endpoint: const HubEndpoint(host: '10.0.0.9', port: 8787),
      );
      h.factory.onDialFuture = (_) => held.future;
      await tester.pumpWidget(h.app());
      await pumpBootstrap(tester);

      // The dial is still pending, so the root spinner is what is on screen.
      expect(find.byKey(const Key('pairing-submit')), findsNothing);

      h.scheduler.fireConnectDeadline();
      await tester.pump();
      h.scheduler.flushNotifications();
      await tester.pump();

      // The dial failed boundedly: the form is shown, names the endpoint, and is
      // not gated.
      expect(
        find.textContaining('could not reach 10.0.0.9:8787 within 10 seconds'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('pairing-submit')))
            .onPressed,
        isNotNull,
      );

      // And it stays usable: a submit reaches the hub.
      await tester.enterText(find.byKey(const Key('pairing-host')), '10.0.0.9');
      await tester.enterText(find.byKey(const Key('pairing-code')), 'ABCD2345');
      await tester.tap(find.byKey(const Key('pairing-submit')));
      await tester.pump();
      expect(h.factory.urls.length, 2);
    },
  );

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

    expect(await h.store.readEndpoints(), isEmpty);

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
      await h.store.readEndpoints(),
      const [HubEndpoint(host: '10.0.0.9', port: 8787)],
    );
    expect(await h.store.read(), testToken);
  });

  testWidgets('scanning a two-address QR dials both, LAN first', (tester) async {
    final h = Harness(token: null);
    final scanner = FakeQrScanner(
      'pidroid://pair?v=1&code=abcd-2345&port=8787'
      '&ts=100.64.1.2&lan=192.168.1.10',
    );
    await tester.pumpWidget(h.app(scanQr: scanner.call));
    await pumpBootstrap(tester);

    await tester.tap(find.byKey(const Key('pairing-scan')));
    await tester.pump();

    // A mixed QR races every candidate in parallel, LAN first.
    expect(scanner.calls, 1);
    expect(h.factory.urls.length, 2);
    expect(h.factory.urls[0].host, '192.168.1.10');
    expect(h.factory.urls[1].host, '100.64.1.2');
  });

  testWidgets('a successful scanned pairing persists the whole list', (
    tester,
  ) async {
    final h = Harness(token: null);
    final scanner = FakeQrScanner(
      'pidroid://pair?v=1&code=abcd-2345&port=8787'
      '&ts=100.64.1.2&lan=192.168.1.10',
    );
    await tester.pumpWidget(h.app(scanQr: scanner.call));
    await pumpBootstrap(tester);

    await tester.tap(find.byKey(const Key('pairing-scan')));
    await tester.pump();

    adoptedSocket(h).receive({
      'protocolVersion': 1,
      'type': 'paired',
      'token': testToken,
    });
    await tester.pump();
    h.scheduler.flushNotifications();
    await tester.pump();
    await tester.pump();

    expect(await h.store.readEndpoints(), const [
      HubEndpoint(host: '192.168.1.10', port: 8787),
      HubEndpoint(host: '100.64.1.2', port: 8787),
    ]);
  });

  testWidgets('a failed scanned race still persists the list at scan time', (
    tester,
  ) async {
    final h = Harness(token: null);
    h.factory.onDial = () => StateError('refused');
    final scanner = FakeQrScanner(
      'pidroid://pair?v=1&code=abcd-2345&port=8787'
      '&ts=100.64.1.2&lan=192.168.1.10',
    );
    await tester.pumpWidget(h.app(scanQr: scanner.call));
    await pumpBootstrap(tester);

    await tester.tap(find.byKey(const Key('pairing-scan')));
    await tester.pump();
    await tester.pump();

    // The whole point of persisting at scan: a hub-minted list survives a race
    // in which no candidate answers, so the tailnet address is not lost.
    expect(await h.store.readEndpoints(), const [
      HubEndpoint(host: '192.168.1.10', port: 8787),
      HubEndpoint(host: '100.64.1.2', port: 8787),
    ]);
    // The in-memory picker keeps both rows so the user can force one.
    expect(find.text('Home network'), findsOneWidget);
    expect(find.text('Tailscale'), findsOneWidget);
  });

  testWidgets('bootstrap from a stored two-address list dials both', (
    tester,
  ) async {
    final h = Harness(
      endpoints: const [
        HubEndpoint(host: '192.168.1.10', port: 8787),
        HubEndpoint(host: '100.64.1.2', port: 8787),
      ],
    );
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    expect(h.factory.urls.length, 2);
    expect(h.factory.urls[0].host, '192.168.1.10');
    expect(h.factory.urls[1].host, '100.64.1.2');
  });

  testWidgets('a second scan supersedes the race in flight', (tester) async {
    final h = Harness(token: null);
    final held = <Completer<HubSocket>>[];
    h.factory.onDialFuture = (url) {
      final completer = Completer<HubSocket>();
      held.add(completer);
      return completer.future;
    };
    final scanner = FakeQrScanner(
      'pidroid://pair?v=1&code=abcd-2345&port=8787'
      '&ts=100.64.1.2&lan=192.168.1.10',
    );
    await tester.pumpWidget(h.app(scanQr: scanner.call));
    await pumpBootstrap(tester);

    await tester.tap(find.byKey(const Key('pairing-scan')));
    await tester.pump();
    expect(held.length, 2);

    // A second scan replaces the list and supersedes the first race.
    scanner.uri =
        'pidroid://pair?v=1&code=efgh-6789&port=8787'
        '&ts=100.64.9.9&lan=10.0.0.5';
    await tester.tap(find.byKey(const Key('pairing-scan')));
    await tester.pump();
    expect(held.length, 4);

    // The first race's dials resolve late: their sockets are closed and never
    // sent a hello.
    final firstLan = FakeHubSocket();
    final firstTs = FakeHubSocket();
    held[0].complete(firstLan);
    held[1].complete(firstTs);
    await tester.pump();
    expect(firstLan.closedByClient, isTrue);
    expect(firstTs.closedByClient, isTrue);
    expect(firstLan.sent, isEmpty);
    expect(firstTs.sent, isEmpty);

    // The second race is unaffected and adopts its own first answer.
    final secondLan = FakeHubSocket();
    held[2].complete(secondLan);
    await tester.pump();
    expect(secondLan.sent, isNotEmpty);
  });

  testWidgets('forcing the Tailscale row prefers it and keeps the list', (
    tester,
  ) async {
    final h = Harness(token: null);
    h.factory.onDial = () => StateError('refused');
    final scanner = FakeQrScanner(
      'pidroid://pair?v=1&code=abcd-2345&port=8787'
      '&ts=100.64.1.2&lan=192.168.1.10',
    );
    await tester.pumpWidget(h.app(scanQr: scanner.call));
    await pumpBootstrap(tester);
    await tester.tap(find.byKey(const Key('pairing-scan')));
    await tester.pump();
    await tester.pump();

    // The candidates are reachable now; hold every dial so the fastest answer
    // cannot decide the winner — only `prefer` does.
    h.factory.onDial = null;
    final dials = <String, Completer<HubSocket>>{};
    h.factory.onDialFuture = (url) =>
        (dials[url.host] ??= Completer<HubSocket>()).future;
    final before = h.factory.urls.length;
    await tester.tap(find.text('Tailscale'));
    await tester.pump();

    expect(h.factory.urls.length, before + 2);
    expect(dials.keys, containsAll(['192.168.1.10', '100.64.1.2']));

    // The LAN candidate answers first: without the preference it would be
    // adopted, so it is held un-authenticated (no hello) while Tailscale
    // settles.
    final lanSocket = FakeHubSocket();
    dials['192.168.1.10']!.complete(lanSocket);
    await tester.pump();
    expect(lanSocket.sent, isEmpty);

    // Tailscale answers second and is the one adopted; the held LAN socket is
    // closed, never authenticated. `onDialFuture` dials do not land in
    // `factory.sockets`, so identity is asserted on the sockets directly.
    final tsSocket = FakeHubSocket();
    dials['100.64.1.2']!.complete(tsSocket);
    await tester.pump();

    expect(tsSocket.sent, isNotEmpty);
    expect(tsSocket.closedByClient, isFalse);
    expect(lanSocket.closedByClient, isTrue);
    expect(lanSocket.sent, isEmpty);
    expect(await h.store.readEndpoints(), const [
      HubEndpoint(host: '192.168.1.10', port: 8787),
      HubEndpoint(host: '100.64.1.2', port: 8787),
    ]);
  });

  testWidgets(
    'forcing a candidate with no ticket surfaces an error instead of throwing',
    (tester) async {
      final h = Harness(
        token: null,
        endpoints: const [
          HubEndpoint(host: '192.168.1.10', port: 8787),
          HubEndpoint(host: '100.64.1.2', port: 8787),
        ],
      );
      await tester.pumpWidget(h.app());
      await pumpBootstrap(tester);

      // The R2 state: the scan persisted the list but the race never paired, so
      // bootstrap could not connect. The picker is the only way forward.
      expect(find.text('Home network'), findsOneWidget);
      expect(find.byKey(const Key('pairing-last-error')), findsNothing);

      await tester.tap(find.text('Tailscale'));
      await tester.pump();
      await tester.pump();

      // There is no ticket and no stored token, so forcing cannot connect. The
      // refusal must be surfaced through the visible error slot, never left as
      // an unhandled async throw from the fire-and-forget callback.
      expect(find.byKey(const Key('pairing-last-error')), findsOneWidget);
      expect(find.textContaining('no pairing code'), findsOneWidget);
    },
  );

  testWidgets(
    'a failed candidate attempt leaves no flag for a later connect to pop on',
    (tester) async {
      final h = Harness(
        endpoints: const [
          HubEndpoint(host: '192.168.1.10', port: 8787),
          HubEndpoint(host: '100.64.1.2', port: 8787),
        ],
      );
      await tester.pumpWidget(h.app());
      await pumpBootstrap(tester);
      adoptedSocket(h).receive(sessionsFrame([sessionS1]));
      await settle(tester, h.scheduler);

      // The pairing screen as a pushed route over the live list.
      await tester.tap(find.byKey(const Key('pairing')));
      await tester.pumpAndSettle();
      expect(find.byType(PairingScreen), findsOneWidget);

      // The hub drops first: `_dropConnection`'s subscription-cancel await only
      // completes under a widget-test clock once the socket is already gone.
      adoptedSocket(h).remoteClose(1006);
      await tester.pump();
      await tester.pump();
      expect(find.byType(PairingScreen), findsOneWidget);

      // The store then loses the token, so forcing a candidate cannot connect:
      // the attempt throws and surfaces the error through the screen.
      await h.store.clear();
      await tester.tap(find.byKey(const Key('pairing-candidate-100.64.1.2:8787')));
      await tester.pumpAndSettle();
      expect(find.textContaining('no pairing code'), findsOneWidget);

      // A later genuine connect — a background reconnect, not a deliberate
      // pairing — must not be mistaken for the failed attempt and pop the
      // route. The flag that failed attempt set has to be gone.
      await h.store.write(testToken);
      await h.client.startCandidates(const [
        HubEndpoint(host: '192.168.1.10', port: 8787),
      ]);
      h.factory.last.receive(sessionsFrame([sessionS1]));
      await settle(tester, h.scheduler);
      await tester.pumpAndSettle();

      expect(find.byType(PairingScreen), findsOneWidget);
    },
  );

  testWidgets(
    'a deliberate pairing over a stale session error still shows the spinner',
    (tester) async {
      final h = Harness(
        endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787),
      );
      await tester.pumpWidget(h.app());
      await pumpBootstrap(tester);
      adoptedSocket(h).receive(sessionsFrame([sessionS1]));
      await settle(tester, h.scheduler);

      // A session-scoped error while the hub stays connected: a failure the
      // app cannot reach the pairing screen through with a bare reconnect.
      for (var i = 0; i <= HubClient.maxConsecutiveResyncs; i++) {
        h.factory.last.receive({
          'protocolVersion': 1,
          'type': 'resync-required',
          'sessionId': 's1',
          'reason': 'backpressure',
        });
      }
      await settle(tester, h.scheduler);
      expect(h.client.state.lastError, contains('gave up resyncing'));
      expect(h.client.state.status, HubConnectionStatus.connected);

      // The pairing screen as a pushed route over the live list.
      await tester.tap(find.byKey(const Key('pairing')));
      await tester.pumpAndSettle();

      // Hold the redial so the spinner window can be observed.
      final held = Completer<HubSocket>();
      h.factory.onDialFuture = (_) => held.future;

      // Force the candidate: `_dropConnection` cancels the live subscription,
      // then redials. The cancel future only completes on the real event loop,
      // not the widget-test clock, so let it run there before pumping on.
      await tester.tap(
        find.byKey(const Key('pairing-candidate-10.0.0.5:8787')),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await settle(tester, h.scheduler);

      // The stale session error is not connection-scoped, so it must not be
      // read as this attempt failing: the deliberate pairing is still in
      // flight and has to show its spinner rather than silently clearing.
      expect(h.client.state.status, HubConnectionStatus.connecting);
      expect(h.client.state.lastError, contains('gave up resyncing'));
      expect(find.byKey(const Key('pairing-busy')), findsOneWidget);

      // It paired: the deliberate attempt pops the pairing route.
      final next = FakeHubSocket();
      held.complete(next);
      await tester.pump();
      next.receive(sessionsFrame([sessionS1]));
      await settle(tester, h.scheduler);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.byType(PairingScreen), findsNothing);
    },
  );

  testWidgets(
    'a keystore failure during a forced candidate clears the spinner',
    (tester) async {
      final store = ThrowingReadTokenStore(
        initialEndpoint: const HubEndpoint(host: '10.0.0.5', port: 8787),
      );
      final h = Harness(tokenStore: store);
      await tester.pumpWidget(h.app());
      await pumpBootstrap(tester);

      // Bootstrap's endpoint read succeeded but its token read threw, so the
      // pairing form is up with the remembered candidate row.
      expect(
        find.textContaining('could not read the saved token'),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('pairing-candidate-10.0.0.5:8787')),
      );
      await tester.pump();
      h.scheduler.flushNotifications();
      await tester.pump();

      // The read throws again inside the forced attempt. That failure must end
      // the attempt instead of leaving a spinner the dropped socket can never
      // clear.
      expect(find.byKey(const Key('pairing-busy')), findsNothing);
      expect(
        find.textContaining('could not read the saved token'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a resync give-up is visible while connected, and dismissible', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

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

  testWidgets('the status banner is readable in dark mode', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await pumpWithBrightness(tester, h, Brightness.dark);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    for (var i = 0; i <= HubClient.maxConsecutiveResyncs; i++) {
      h.factory.last.receive({
        'protocolVersion': 1,
        'type': 'resync-required',
        'sessionId': 's1',
        'reason': 'backpressure',
      });
    }
    await settle(tester, h.scheduler);

    // The banner is painted with the app's (dark) scheme, not the fallback
    // light scheme above the MaterialApp, and its text is the on-container
    // colour so it stays legible against that background.
    final scheme = renderedScheme(tester);
    expect(scheme.brightness, Brightness.dark);
    final banner = tester.widget<Container>(
      find
          .ancestor(
            of: find.textContaining('gave up resyncing'),
            matching: find.byType(Container),
          )
          .first,
    );
    final text = tester.widget<Text>(find.textContaining('gave up resyncing'));
    expect(banner.color, scheme.errorContainer);
    expect(text.style?.color, scheme.onErrorContainer);
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

  testWidgets('an unreadable stored token is visible, not an eternal spinner',
      (tester) async {
    final store = ThrowingReadTokenStore(
      initialEndpoint: const HubEndpoint(host: '10.0.0.5', port: 8787),
    );
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
    expect(find.textContaining('could not read the saved token'), findsOneWidget);
  });

  testWidgets('a remembered address with no stored token still reaches pairing',
      (tester) async {
    final h = Harness(
      token: null,
      endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787),
    );
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(PairingScreen), findsOneWidget);
    expect(find.byKey(const Key('pairing-last-error')), findsNothing);
  });

  testWidgets('a fresh boot with nothing saved shows the root pairing screen', (
    tester,
  ) async {
    final h = Harness(token: null);
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    expect(find.byType(PairingScreen), findsOneWidget);
    expect(find.byKey(const Key('pairing-submit')), findsOneWidget);
    // It is the root, not a pushed route: there is no list underneath.
    expect(find.byKey(const Key('start-session')), findsNothing);
  });

  testWidgets('opening pairing keeps the saved endpoint and token', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('pairing')));
    await tester.pumpAndSettle();

    // Pairing is a pushed route over the live list, not a destructive state
    // swap: the credential and the connection are untouched.
    expect(find.byType(PairingScreen), findsOneWidget);
    expect(h.client.state.status, HubConnectionStatus.connected);
    expect(
      await h.store.readEndpoints(),
      const [HubEndpoint(host: '10.0.0.5', port: 8787)],
    );
    expect(await h.store.read(), testToken);
  });

  testWidgets('the pairing route pops back to the connected list', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('pairing')));
    await tester.pumpAndSettle();
    expect(find.byType(PairingScreen), findsOneWidget);

    await pressSystemBack(tester, h.scheduler);
    await tester.pumpAndSettle();

    expect(find.byType(PairingScreen), findsNothing);
    expect(find.byKey(const Key('start-session')), findsOneWidget);
    expect(h.client.state.status, HubConnectionStatus.connected);
  });

  testWidgets('the pairing route can be reopened after it pops', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('pairing')));
    await tester.pumpAndSettle();
    await pressSystemBack(tester, h.scheduler);
    await tester.pumpAndSettle();
    expect(find.byType(PairingScreen), findsNothing);

    // The pop cleared the latch, so the button pushes a fresh route.
    await tester.tap(find.byKey(const Key('pairing')));
    await tester.pumpAndSettle();
    expect(find.byType(PairingScreen), findsOneWidget);
  });

  testWidgets('the pairing button opens the route only once', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('pairing')));
    await tester.pumpAndSettle();

    // Invoke the covered button again without hit-testing. The latch must make
    // it a no-op, or a single back would land on a second pairing screen.
    final button = tester.widget<IconButton>(
      find.byKey(const Key('pairing'), skipOffstage: false),
    );
    button.onPressed!();
    await tester.pumpAndSettle();

    await pressSystemBack(tester, h.scheduler);
    await tester.pumpAndSettle();

    expect(find.byType(PairingScreen), findsNothing);
  });

  testWidgets('a successful deliberate pairing pops the pushed route', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    // The hub drops (the list stays up with a banner); the user re-pairs from
    // the pushed form.
    h.factory.last.remoteClose(1006);
    await tester.pump();
    await tester.pump();
    expect(h.client.state.status, isNot(HubConnectionStatus.connected));

    await tester.tap(find.byKey(const Key('pairing')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('pairing-code')), 'ABCD2345');
    await tester.ensureVisible(find.byKey(const Key('pairing-submit')));
    await tester.tap(find.byKey(const Key('pairing-submit')));
    await tester.pump();
    await tester.pump();

    // The deliberate attempt dialled a fresh socket; a `paired` frame completes
    // it and the route closes on the reach of `connected`.
    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'paired',
      'token': testToken,
    });
    await tester.pump();
    h.scheduler.flushNotifications();
    await tester.pumpAndSettle();

    expect(find.byType(PairingScreen), findsNothing);
    expect(find.byKey(const Key('start-session')), findsOneWidget);
  });

  testWidgets('a background reconnect does not pop the pushed pairing route', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    await tester.tap(find.byKey(const Key('pairing')));
    await tester.pumpAndSettle();
    expect(find.byType(PairingScreen), findsOneWidget);

    // A drop and redial completing with the stored token: no deliberate attempt
    // is in flight, so the flag must not be set and the route must stay put.
    h.factory.last.remoteClose(1006);
    await tester.pump();
    await tester.pump();
    h.scheduler.reconnectTimers.last.fire();
    await tester.pump();
    await tester.pump();
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await tester.pump();
    h.scheduler.flushNotifications();
    await tester.pumpAndSettle();

    expect(find.byType(PairingScreen), findsOneWidget);
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

  testWidgets('the folder browser still pops on a predictive back gesture', (
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
    // further than the route transition — but the transition must complete
    // before the route's predictive detector will claim a gesture.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(FolderBrowserScreen), findsOneWidget);

    // Unlike a dialog, the browser is a MaterialPageRoute with a predictive
    // detector, so it claims the gesture (S4).
    expect(await startBackGesture(tester), isTrue);
    await commitBackGesture(tester);
    await tester.pumpAndSettle();

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
    // s2 is engaged via persistence: this test pins the presence rule, not the
    // engagement gate.
    final h = Harness(
      notifyState: (NotificationPolicy()..engage('s2')).encode(),
      endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787),
    );
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1, sessionS2]));
    await settle(tester, h.scheduler);

    // Foregrounded on s1; s2 settles: the app must notify.
    await openSession(tester, h, 'api refactor');

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
    await openSession(tester, h, 'api refactor');

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
    await openSession(tester, h, 'api refactor');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    h.factory.last.receive(settledFrame(sessionId: 's1'));
    await settle(tester, h.scheduler);

    expect(h.notifications.shown, hasLength(1));
  });

  testWidgets('opening a session dismisses its stale notification', (
    tester,
  ) async {
    // s1 is engaged via persistence: the stale entry is raised for an engaged
    // session, then opening it must cancel it.
    final h = Harness(
      notifyState: (NotificationPolicy()..engage('s1')).encode(),
      endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787),
    );
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    // On the list: a settle for s1 notifies even though the app is foreground.
    h.factory.last.receive(settledFrame(sessionId: 's1'));
    await settle(tester, h.scheduler);
    expect(h.notifications.shown, hasLength(1));

    // Opening s1 from the list makes that shade entry stale.
    await openSession(tester, h, 'api refactor');

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
    await openSession(tester, h, 'api refactor');

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

  testWidgets('opening a session engages and persists it', (tester) async {
    final h = await openFirstSession(tester);

    expect(
      NotificationPolicy.decode((h.store as InMemoryTokenStore).notifyState)
          .isEngaged('s1'),
      isTrue,
    );
  });

  testWidgets('a never-opened session stays silent', (tester) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1, sessionS2]));
    await settle(tester, h.scheduler);

    // Opening s1 engages only s1.
    await openSession(tester, h, 'api refactor');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    // s2 was never opened: silent.
    h.factory.last.receive(settledFrame(sessionId: 's2', label: 'second session'));
    await settle(tester, h.scheduler);
    expect(h.notifications.shown, isEmpty);

    // s1 was opened: it notifies (non-vacuous control).
    h.factory.last.receive(settledFrame(sessionId: 's1'));
    await settle(tester, h.scheduler);
    expect(h.notifications.shown, hasLength(1));
  });

  testWidgets('an app-origin session notifies without being opened', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([appSessionA1, sessionS2]));
    await settle(tester, h.scheduler);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    h.factory.last.receive(settledFrame(sessionId: 'a1', label: 'New session'));
    await settle(tester, h.scheduler);
    expect(h.notifications.shown, hasLength(1));

    // A pc session that was never opened stays silent.
    h.factory.last.receive(settledFrame(sessionId: 's2', label: 'second session'));
    await settle(tester, h.scheduler);
    expect(h.notifications.shown, hasLength(1));
  });

  testWidgets('a persisted engagement survives a restart', (tester) async {
    final h = Harness(
      notifyState: (NotificationPolicy()..engage('s1')).encode(),
      endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787),
    );
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    h.factory.last.receive(settledFrame(sessionId: 's1'));
    await settle(tester, h.scheduler);

    expect(h.notifications.shown, hasLength(1));
  });

  testWidgets('an ordinary sessions push does not rewrite the policy', (
    tester,
  ) async {
    final h = await openFirstSession(tester);
    final store = h.store as InMemoryTokenStore;

    // Opening s1 engages it, so that write is expected. Zero the counter now so
    // the ordinary push below is the only thing it can observe: a rewrite that
    // re-encodes the same bytes would otherwise be invisible to a value check.
    store.notifyWrites = 0;

    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);

    expect(store.notifyWrites, 0, reason: 'an unchanged push must not write');

    // A real replacement changes the policy, so it must write exactly once —
    // proving the counter is live and the zero above is not vacuous.
    h.factory.last.receive(
      sessionsFrame([
        {
          'sessionId': 's2',
          'label': 'successor',
          'agentState': 'idle',
          'replacesSessionId': 's1',
        },
      ]),
    );
    await settle(tester, h.scheduler);

    expect(store.notifyWrites, 1);
  });

  testWidgets('muting stops notifications and unmuting restores them', (
    tester,
  ) async {
    final h = await openFirstSession(tester);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-notify')));
    await tester.pumpAndSettle();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    h.factory.last.receive(settledFrame(sessionId: 's1'));
    await settle(tester, h.scheduler);
    expect(h.notifications.shown, isEmpty);

    // Frames are disabled while paused, so a popup cannot be built; resume long
    // enough to reopen the menu, then go back to background for the settle.
    // Lifecycle transitions must follow the platform's ordering.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-notify')));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    h.factory.last.receive(settledFrame(sessionId: 's1'));
    await settle(tester, h.scheduler);
    expect(h.notifications.shown, hasLength(1));
  });

  testWidgets('a replacement migrates the engaged flag', (tester) async {
    final h = await openFirstSession(tester);

    h.factory.last.receive(
      sessionsFrame([
        {
          'sessionId': 's2',
          'label': 'successor',
          'agentState': 'idle',
          'replacesSessionId': 's1',
        },
      ]),
    );
    await settle(tester, h.scheduler);

    final policy = NotificationPolicy.decode(
      (h.store as InMemoryTokenStore).notifyState,
    );
    expect(policy.isEngaged('s2'), isTrue);
    expect(policy.contains('s1'), isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    h.factory.last.receive(settledFrame(sessionId: 's2', label: 'successor'));
    await settle(tester, h.scheduler);
    expect(h.notifications.shown, hasLength(1));
  });

  testWidgets('a muted predecessor keeps its successor muted', (tester) async {
    final h = await openFirstSession(tester);

    await tester.tap(find.byKey(const Key('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-menu-notify')));
    await tester.pumpAndSettle();

    h.factory.last.receive(
      sessionsFrame([
        {
          'sessionId': 's2',
          'label': 'successor',
          'agentState': 'idle',
          'replacesSessionId': 's1',
        },
      ]),
    );
    await settle(tester, h.scheduler);

    expect(
      NotificationPolicy.decode((h.store as InMemoryTokenStore).notifyState)
          .isMuted('s2'),
      isTrue,
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    h.factory.last.receive(settledFrame(sessionId: 's2', label: 'successor'));
    await settle(tester, h.scheduler);
    expect(h.notifications.shown, isEmpty);
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
    // so the transcript route is actually pushed, then pump its transition so
    // the view is onstage (a pushed route is offstage mid-transition).
    await settle(tester, h.scheduler);
    await tester.pumpAndSettle();

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
    await tester.pumpAndSettle();

    // The UI returns to the session list rather than hanging on a transcript,
    // and says why.
    expect(h.client.state.activeSessionId, isNull);
    expect(find.byKey(const Key('compose-field')), findsNothing);
    expect(find.text('pi sessions · 10.0.0.5:8787'), findsOneWidget);
    expect(find.textContaining('the session ghost is gone'), findsOneWidget);
  });

  testWidgets('the foreground service starts once and survives opening pairing', (
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

    // Opening pairing is non-destructive: the service stays up behind the route.
    await tester.tap(find.byKey(const Key('pairing')));
    await tester.pumpAndSettle();
    expect(find.byType(PairingScreen), findsOneWidget);
    expect(h.notifications.stopForegroundCalls, 0);
  });

  testWidgets('a hub without attachments shows no attach button', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    await openSession(tester, h, 'api refactor');

    // An old hub cannot carry the image, so the affordance is omitted rather
    // than offered and silently dropped.
    expect(find.byKey(const Key('compose-attach')), findsNothing);
  });

  testWidgets('the attach button appears with the attachments capability', (
    tester,
  ) async {
    await openAttachmentsSession(tester);
    expect(find.byKey(const Key('compose-attach')), findsOneWidget);
  });

  testWidgets('picking an image shows a removable thumbnail', (tester) async {
    await openAttachmentsSession(
      tester,
      pickImage: () async => PickedImage(onePixelPng, 'image/png'),
    );

    await tester.tap(find.byKey(const Key('compose-attach')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('compose-attachment')), findsOneWidget);
  });

  testWidgets('a captioned attachment rides the prompt args and clears', (
    tester,
  ) async {
    final h = await openAttachmentsSession(
      tester,
      pickImage: () async => PickedImage(onePixelPng, 'image/png'),
    );

    await tester.tap(find.byKey(const Key('compose-attach')));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(const Key('compose-field')), 'hi pi');
    await tester.tap(find.byKey(const Key('compose-send')));
    await tester.pump();
    await tester.pump();

    final command = h.factory.last.sentFrames.lastWhere(
      (frame) => frame['name'] == 'prompt',
    );
    expect(command['type'], 'command');
    expect(command['sessionId'], 's1');
    expect(command['args'], {
      'text': 'hi pi',
      'images': [
        {'data': base64Encode(onePixelPng), 'mimeType': 'image/png'},
      ],
    });
    // The image belongs to that one send; a leftover chip would silently ride
    // the next message too.
    expect(find.byKey(const Key('compose-attachment')), findsNothing);
  });

  testWidgets('an over-cap image is refused locally and nothing is sent', (
    tester,
  ) async {
    final h = await openAttachmentsSession(
      tester,
      pickImage: () async =>
          PickedImage(Uint8List(maxAttachmentBytes + 1), 'image/png'),
    );

    await tester.tap(find.byKey(const Key('compose-attach')));
    await tester.pump();
    await tester.pump();

    expect(find.text('That image is too large to send'), findsOneWidget);
    expect(find.byKey(const Key('compose-attachment')), findsNothing);
    // The guard fires before any frame: an over-cap frame would be dropped by
    // the hub's maxPayload with no reply, which is the silent timeout.
    expect(
      h.factory.last.sentFrames.where(
        (frame) => frame['type'] == 'command' && frame['name'] == 'prompt',
      ),
      isEmpty,
    );
  });

  testWidgets('cancelling the picker leaves the composer untouched', (
    tester,
  ) async {
    final h = await openAttachmentsSession(tester, pickImage: () async => null);

    await tester.tap(find.byKey(const Key('compose-attach')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('compose-attachment')), findsNothing);
    expect(tester.takeException(), isNull);
    expect(
      h.factory.last.sentFrames.where((frame) => frame['name'] == 'prompt'),
      isEmpty,
    );
  });

  testWidgets('a picker error is shown, not mistaken for a cancel', (
    tester,
  ) async {
    await openAttachmentsSession(
      tester,
      pickImage: () async => throw StateError('gallery denied'),
    );

    await tester.tap(find.byKey(const Key('compose-attach')));
    await tester.pump();
    await tester.pump();

    expect(find.text('Could not open the gallery'), findsOneWidget);
    expect(find.byKey(const Key('compose-attachment')), findsNothing);
  });

  testWidgets('a picked attachment does not leak into another session', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(
      h.app(pickImage: () async => PickedImage(onePixelPng, 'image/png')),
    );
    await pumpBootstrap(tester);
    h.factory.last.receive(attachmentsSessionsFrame([sessionS1, sessionS2]));
    await settle(tester, h.scheduler);

    await openSession(tester, h, 'api refactor');
    await tester.tap(find.byKey(const Key('compose-attach')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('compose-attachment')), findsOneWidget);

    // Switch to the other session: the image belonged to s1 and must not follow.
    await pressSystemBack(tester, h.scheduler);
    await tester.pumpAndSettle();
    await openSession(tester, h, 'second session');
    expect(find.byKey(const Key('compose-attachment')), findsNothing);

    await tester.enterText(find.byKey(const Key('compose-field')), 'hi pi');
    await tester.tap(find.byKey(const Key('compose-send')));
    await tester.pump();

    final command = h.factory.last.sentFrames.lastWhere(
      (frame) => frame['name'] == 'prompt',
    );
    expect(command['sessionId'], 's2');
    expect(command['args'], {'text': 'hi pi'});
  });

  testWidgets('a capability downgrade drops a stale pick', (tester) async {
    final h = await openAttachmentsSession(
      tester,
      pickImage: () async => PickedImage(onePixelPng, 'image/png'),
    );

    await tester.tap(find.byKey(const Key('compose-attach')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('compose-attachment')), findsOneWidget);

    // The hub downgrades in place (same session, no attachments capability).
    h.factory.last.receive(sessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    expect(find.byKey(const Key('compose-attachment')), findsNothing);

    // Capability returns later: the old pick must not resurrect.
    h.factory.last.receive(attachmentsSessionsFrame([sessionS1]));
    await settle(tester, h.scheduler);
    expect(find.byKey(const Key('compose-attachment')), findsNothing);
  });
}
