// Pairing: the form, races, routes, back and the error banner.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/endpoint_store.dart';
import 'package:pi_handset/client/hub_client.dart';
import 'package:pi_handset/client/hub_socket.dart';
import 'package:pi_handset/ui/pairing_screen.dart';

import '../client/support/fakes.dart';

import 'support/app_shell_harness.dart';

void main() {
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

  testWidgets('the pushed pairing screen shows a visible way back', (
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

    // Tapping the hub icon opens a screen with no title bar and no button that
    // leaves it: a dead end under gesture navigation. Back must be on screen,
    // and it must be non-destructive like the system back button already is.
    await tester.tap(find.byKey(const Key('pairing-back')));
    await tester.pumpAndSettle();

    expect(find.byType(PairingScreen), findsNothing);
    expect(find.byKey(const Key('start-session')), findsOneWidget);
    expect(h.client.state.status, HubConnectionStatus.connected);
  });

  testWidgets('the boot pairing screen offers no back control', (tester) async {
    // Before a pairing has ever succeeded the very same widget is the whole
    // app: there is nothing behind it, so a back control would be a lie.
    final h = Harness(token: null);
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);

    expect(find.byType(PairingScreen), findsOneWidget);
    expect(find.byKey(const Key('pairing-back')), findsNothing);
    // Not just no back button: no title bar at all.
    expect(find.byType(AppBar), findsNothing);
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
}
