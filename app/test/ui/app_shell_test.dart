// The app root. It must bootstrap from a remembered endpoint + token, drive the
// UI from the client's `changes` stream, and open a session's transcript on tap.
// It must also stay honest about failure: a resync give-up, a refused send, a
// failed pairing and a broken store all have to reach the screen.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/endpoint_store.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/client/token_store.dart';
import 'package:pi_droid/ui/app_shell.dart';
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

Map<String, Object?> sessionsFrame(List<Map<String, Object?>> sessions) => {
  'protocolVersion': 1,
  'type': 'sessions',
  'sessions': sessions,
};

const sessionS1 = {'sessionId': 's1', 'label': 'api refactor', 'agentState': 'idle'};
const sessionS2 = {'sessionId': 's2', 'label': 'second session', 'agentState': 'idle'};

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
  late final HubClient client;

  Widget app() => PiDroidApp(client: client, tokenStore: store);
}

/// A token store whose endpoint read fails, standing in for a broken platform
/// keystore.
class ThrowingTokenStore extends InMemoryTokenStore {
  @override
  Future<HubEndpoint?> readEndpoint() async =>
      throw StateError('storage unavailable');
}

void main() {
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
    expect(find.text('pi sessions'), findsOneWidget);
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
    await tester.pumpWidget(PiDroidApp(client: client, tokenStore: store));
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
}
