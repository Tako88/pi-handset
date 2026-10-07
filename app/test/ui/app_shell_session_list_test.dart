// The session list: the hub name, a pending spawn, the candidate header, start
// and kill, and the folder browser.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/endpoint_store.dart';
import 'package:pi_handset/ui/folder_browser.dart';

import 'support/app_shell_harness.dart';

void main() {
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

  testWidgets('a pending spawn row is replaced by the failure banner', (
    tester,
  ) async {
    final h = Harness(endpoint: const HubEndpoint(host: '10.0.0.5', port: 8787));
    await tester.pumpWidget(h.app());
    await pumpBootstrap(tester);
    h.factory.last.receive(sessionsFrame([]));
    await settle(tester, h.scheduler);

    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'sessions',
      'sessions': <Object?>[],
      'pending': [
        {'id': 'p1', 'label': 'New session'},
      ],
    });
    await settle(tester, h.scheduler);
    expect(find.byKey(const Key('cancel-p1')), findsOneWidget);

    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'spawn-failed',
      'id': 'p1',
      'error': 'the session exited before it started',
    });
    await settle(tester, h.scheduler);

    expect(find.text('the session exited before it started'), findsOneWidget);
    expect(find.byKey(const Key('cancel-p1')), findsNothing);
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
}
