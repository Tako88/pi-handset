// The folder browser: it lists the hub's directories, walks into a child, walks
// back up, refuses to claim a truncated listing is complete, and starts a
// session in the folder it is showing (asking about trust when the hub says the
// folder needs a decision and none exists).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/ui/folder_browser.dart';

import '../client/support/fakes.dart';

const String testToken =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

/// A client dialled to a fake socket and authenticated with a `sessions` frame
/// that advertises the folder capabilities.
class BrowserHarness {
  BrowserHarness() {
    client = HubClient(
      socketFactory: factory.call,
      scheduler: scheduler,
      tokenStore: InMemoryTokenStore(initial: testToken),
      rng: () => 0.5,
    );
  }

  final FakeSocketFactory factory = FakeSocketFactory();
  final FakeScheduler scheduler = FakeScheduler();
  late final HubClient client;

  Future<void> connect(WidgetTester tester) async {
    await client.start('127.0.0.1');
    await tester.pump();
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'sessions',
      'sessions': const [],
      'capabilities': const ['list-dirs', 'project-session'],
    });
    await tester.pump();
    await tester.pump();
  }
}

/// Pumps the browser as the whole app. Good for the listing itself; a pop has
/// nowhere to go.
Future<void> pumpDirect(WidgetTester tester, HubClient client) async {
  await tester.pumpWidget(MaterialApp(home: FolderBrowserScreen(client: client)));
  await tester.pump();
}

/// Pumps the browser as a pushed route over a placeholder, so `Navigator.pop`
/// on a successful start is observable.
Future<void> pushBrowser(WidgetTester tester, HubClient client) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('push-browser'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => FolderBrowserScreen(client: client),
                ),
              ),
              child: const Text('push browser'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('push-browser')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void deliverListing(
  FakeHubSocket socket, {
  required String id,
  required String path,
  required String root,
  List<String> entries = const [],
  bool truncated = false,
  bool? trust,
  bool trustRequired = false,
}) {
  socket.receive({
    'protocolVersion': 1,
    'type': 'dir-listing',
    'id': id,
    'path': path,
    'root': root,
    'trust': trust,
    'trustRequired': trustRequired,
    'entries': entries,
    'truncated': truncated,
  });
}

/// The id of the most recently sent `list-dirs` frame.
String lastListingId(BrowserHarness h) {
  final frame = h.factory.last.sentFrames.lastWhere(
    (frame) => frame['type'] == 'list-dirs',
  );
  return frame['id']! as String;
}

void main() {
  testWidgets('pumping the browser sends list-dirs for the root', (
    tester,
  ) async {
    final h = BrowserHarness();
    await h.connect(tester);
    await pumpDirect(tester, h.client);

    final frame = h.factory.last.lastSent;
    expect(frame['type'], 'list-dirs');
    expect(frame.containsKey('path'), isFalse);
  });

  testWidgets('a listing renders its entries and the current path', (
    tester,
  ) async {
    final h = BrowserHarness();
    await h.connect(tester);
    await pumpDirect(tester, h.client);

    deliverListing(
      h.factory.last,
      id: lastListingId(h),
      path: '/home/u',
      root: '/home/u',
      entries: const ['Work', 'project'],
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('/home/u'), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('project'), findsOneWidget);
  });

  testWidgets('tapping an entry lists the joined path', (tester) async {
    final h = BrowserHarness();
    await h.connect(tester);
    await pumpDirect(tester, h.client);
    deliverListing(
      h.factory.last,
      id: lastListingId(h),
      path: '/home/u',
      root: '/home/u',
      entries: const ['Work'],
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Work'));
    await tester.pump();

    final frame = h.factory.last.sentFrames.lastWhere(
      (frame) => frame['type'] == 'list-dirs',
    );
    expect(frame['path'], '/home/u/Work');
  });

  testWidgets('Up is absent at the root and present in a subdirectory', (
    tester,
  ) async {
    final h = BrowserHarness();
    await h.connect(tester);
    await pumpDirect(tester, h.client);
    deliverListing(
      h.factory.last,
      id: lastListingId(h),
      path: '/home/u',
      root: '/home/u',
      entries: const ['Work'],
    );
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip('Up'), findsNothing);

    await tester.tap(find.text('Work'));
    await tester.pump();
    deliverListing(
      h.factory.last,
      id: lastListingId(h),
      path: '/home/u/Work',
      root: '/home/u',
      entries: const ['src'],
    );
    await tester.pump();
    await tester.pump();

    expect(find.byTooltip('Up'), findsOneWidget);
  });

  testWidgets('a truncated listing shows an affordance; a full one does not', (
    tester,
  ) async {
    final h = BrowserHarness();
    await h.connect(tester);
    await pumpDirect(tester, h.client);
    deliverListing(
      h.factory.last,
      id: lastListingId(h),
      path: '/home/u',
      root: '/home/u',
      entries: const ['Work'],
      truncated: false,
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('listing-truncated')), findsNothing);

    await tester.tap(find.text('Work'));
    await tester.pump();
    deliverListing(
      h.factory.last,
      id: lastListingId(h),
      path: '/home/u/Work',
      root: '/home/u',
      entries: const ['src'],
      truncated: true,
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('listing-truncated')), findsOneWidget);
  });

  testWidgets('a refused listing shows the error', (tester) async {
    final h = BrowserHarness();
    await h.connect(tester);
    await pumpDirect(tester, h.client);

    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': lastListingId(h),
      'ok': false,
      'error': 'invalid path',
    });
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('invalid path'), findsOneWidget);
  });

  testWidgets('start-here asks about trust, then starts in the shown folder', (
    tester,
  ) async {
    final h = BrowserHarness();
    await h.connect(tester);
    await pushBrowser(tester, h.client);
    deliverListing(
      h.factory.last,
      id: lastListingId(h),
      path: '/home/u/Work',
      root: '/home/u',
      trustRequired: true,
    );
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('start-here')));
    await tester.pumpAndSettle();
    expect(find.text('Trust'), findsOneWidget);

    await tester.tap(find.byKey(const Key('trust-yes')));
    await tester.pumpAndSettle();

    final start = h.factory.last.sentFrames.lastWhere(
      (frame) => frame['type'] == 'start-session',
    );
    expect(start['cwd'], '/home/u/Work');
    expect(start['trust'], true);

    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': start['id'],
      'ok': true,
    });
    await tester.pumpAndSettle();

    expect(find.byType(FolderBrowserScreen), findsNothing);
    expect(find.text('push browser'), findsOneWidget);
  });

  testWidgets('a refused start-here shows the error', (tester) async {
    final h = BrowserHarness();
    await h.connect(tester);
    await pumpDirect(tester, h.client);
    deliverListing(
      h.factory.last,
      id: lastListingId(h),
      path: '/home/u',
      root: '/home/u',
    );
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('start-here')));
    await tester.pump();

    final start = h.factory.last.sentFrames.lastWhere(
      (frame) => frame['type'] == 'start-session',
    );
    expect(start['cwd'], '/home/u');

    h.factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': start['id'],
      'ok': false,
      'error': 'too many app sessions',
    });
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('too many app sessions'), findsOneWidget);
  });

  testWidgets('tapping Up requests the parent path', (tester) async {
    final h = BrowserHarness();
    await h.connect(tester);
    await pumpDirect(tester, h.client);
    deliverListing(
      h.factory.last,
      id: lastListingId(h),
      path: '/home/u/Work',
      root: '/home/u',
      entries: const ['src'],
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Up'));
    await tester.pump();

    final frame = h.factory.last.sentFrames.lastWhere(
      (frame) => frame['type'] == 'list-dirs',
    );
    expect(frame['path'], '/home/u');
  });

  testWidgets('a trailing slash on the root still withholds Up', (
    tester,
  ) async {
    final h = BrowserHarness();
    await h.connect(tester);
    await pumpDirect(tester, h.client);
    deliverListing(
      h.factory.last,
      id: lastListingId(h),
      path: '/home/u/',
      root: '/home/u',
      entries: const ['Work'],
    );
    await tester.pump();
    await tester.pump();

    expect(find.byTooltip('Up'), findsNothing);
  });

  testWidgets('a trailing-slash parent is joined without doubling the slash', (
    tester,
  ) async {
    final h = BrowserHarness();
    await h.connect(tester);
    await pumpDirect(tester, h.client);
    deliverListing(
      h.factory.last,
      id: lastListingId(h),
      path: '/home/u/',
      root: '/home/u',
      entries: const ['Work'],
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Work'));
    await tester.pump();

    final frame = h.factory.last.sentFrames.lastWhere(
      (frame) => frame['type'] == 'list-dirs',
    );
    expect(frame['path'], '/home/u/Work');
  });

  testWidgets('a drill-down shows a progress bar until its listing arrives', (
    tester,
  ) async {
    final h = BrowserHarness();
    await h.connect(tester);
    await pumpDirect(tester, h.client);
    deliverListing(
      h.factory.last,
      id: lastListingId(h),
      path: '/home/u',
      root: '/home/u',
      entries: const ['Work'],
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await tester.tap(find.text('Work'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    deliverListing(
      h.factory.last,
      id: lastListingId(h),
      path: '/home/u/Work',
      root: '/home/u',
      entries: const ['src'],
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('a slow first listing cannot overwrite a fast second', (
    tester,
  ) async {
    final h = BrowserHarness();
    await h.connect(tester);
    await pumpDirect(tester, h.client);
    deliverListing(
      h.factory.last,
      id: lastListingId(h),
      path: '/home/u',
      root: '/home/u',
      entries: const ['A', 'B'],
    );
    await tester.pump();
    await tester.pump();

    // Tap A, then B, before either reply arrives: the user changed their mind.
    await tester.tap(find.text('A'));
    await tester.pump();
    final idA = lastListingId(h);
    await tester.tap(find.text('B'));
    await tester.pump();
    final idB = lastListingId(h);

    // B answers first, then A's slow reply lands last and must be ignored.
    deliverListing(
      h.factory.last,
      id: idB,
      path: '/home/u/B',
      root: '/home/u',
    );
    await tester.pump();
    await tester.pump();
    deliverListing(
      h.factory.last,
      id: idA,
      path: '/home/u/A',
      root: '/home/u',
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('/home/u/B'), findsOneWidget);
    expect(find.text('/home/u/A'), findsNothing);
  });
}
