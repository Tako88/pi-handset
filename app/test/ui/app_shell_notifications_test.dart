// -------------------------------------------------------------------------
// Settle notifications
// -------------------------------------------------------------------------
// Notifications, engagement and mute, cold and warm taps, and the foreground
// service.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/endpoint_store.dart';
import 'package:pi_handset/client/hub_client.dart';
import 'package:pi_handset/client/notification_policy.dart';
import 'package:pi_handset/client/settle_notification.dart';
import 'package:pi_handset/ui/pairing_screen.dart';

import '../client/support/fakes.dart';

import 'support/app_shell_harness.dart';

void main() {
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
}
