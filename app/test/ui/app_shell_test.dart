// Shell core: the root and theme, boot, transcript routing, predictive back,
// drafts, scroll reset, a refused prompt, a late reply and store-read failures.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/endpoint_store.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/ui/app_shell.dart';

import '../client/support/fakes.dart';

import 'support/app_shell_harness.dart';

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
}
