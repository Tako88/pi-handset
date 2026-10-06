// The app root. It must bootstrap from a remembered endpoint + token, drive the
// UI from the client's `changes` stream, and open a session's transcript on tap.
// It must also stay honest about failure: a resync give-up, a refused send, a
// failed pairing and a broken store all have to reach the screen.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/attachment.dart';
import 'package:pi_droid/client/endpoint_store.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/client/token_store.dart';
import 'package:pi_droid/platform/qr_scanner.dart';
import 'package:pi_droid/ui/app_shell.dart';
import 'package:pi_droid/ui/theme.dart';

import '../../client/support/fakes.dart';

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

/// A baseline snapshot whose history is truncated but has no older cursor, so
/// the view renders the synthetic "older messages are not loaded" notice.
Map<String, Object?> truncatedSnapshotFrame(String sessionId) => {
  'protocolVersion': 1,
  'type': 'snapshot',
  'sessionId': sessionId,
  'lastSeq': 1,
  'agentState': 'idle',
  'entries': [
    {'type': 'assistant', 'text': 'message 0'},
  ],
  'truncated': true,
};

/// Boots a harness and opens s1 with count committed assistant messages, so
/// the transcript has searchable text. includeSecond also lists s2 for the
/// session-switch test.
Future<Harness> openSearchableSession(
  WidgetTester tester, {
  int count = 3,
  bool includeSecond = false,
}) async {
  final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
  await tester.pumpWidget(h.app());
  await pumpBootstrap(tester);
  h.factory.last.receive(
    sessionsFrame([sessionS1, if (includeSecond) sessionS2]),
  );
  await settle(tester, h.scheduler);
  await openSession(tester, h, 'api refactor');
  h.factory.last.receive(snapshotFrame('s1', count));
  await settle(tester, h.scheduler);
  await tester.pumpAndSettle();
  return h;
}

/// The text of the transcript search's counted n/N readout.
String searchCount(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const Key('transcript-search-count')))
    .data!;

/// Every visible transcript row carrying a find-in-transcript tint.
List<DocumentRow> searchHighlightedRows(WidgetTester tester) => tester
    .widgetList<DocumentRow>(find.byType(DocumentRow))
    .where((row) => row.highlight != null)
    .toList();

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
