// Folder browsing on the client: `listDirs` correlates a `dir-listing` back to
// its caller, `startSession` carries `cwd`/`trust`, and both refuse locally when
// the hub advertises no matching capability (so an old hub is never sent a frame
// it would answer with a terminal 4003 close, and never silently temp-spawns).

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/hub_client.dart';

import 'support/fakes.dart';

const String testToken =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  late FakeSocketFactory factory;
  late FakeScheduler scheduler;
  late HubClient client;

  setUp(() async {
    factory = FakeSocketFactory();
    scheduler = FakeScheduler();
    client = HubClient(
      socketFactory: factory.call,
      scheduler: scheduler,
      tokenStore: InMemoryTokenStore(initial: testToken),
      rng: () => 0.5,
    );
    await client.start('127.0.0.1');
    await pumpEventQueue();
  });

  /// Pushes the post-auth `sessions` frame, optionally advertising the folder
  /// capabilities. A missing [capabilities] mimics an old hub.
  Future<void> pushSessions({List<String>? capabilities}) async {
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'sessions',
      'sessions': const <Object?>[],
      'capabilities': ?capabilities,
    });
    await pumpEventQueue();
  }

  Map<String, Object?> dirListingFrame(String id) => {
    'protocolVersion': 1,
    'type': 'dir-listing',
    'id': id,
    'path': '/home/u',
    'root': '/home/u',
    'trust': null,
    'trustRequired': false,
    'entries': const ['Work', 'project'],
    'truncated': false,
  };

  test('listDirs sends list-dirs with no path and a dirs- id', () async {
    await pushSessions(capabilities: const ['list-dirs', 'project-session']);
    final future = client.listDirs();

    final frame = factory.last.lastSent;
    expect(frame['type'], 'list-dirs');
    expect(frame['id'], startsWith('dirs-'));
    expect(frame.containsKey('path'), isFalse);

    factory.last.receive(dirListingFrame(frame['id']! as String));

    final result = await future;
    expect(result.ok, isTrue);
    final listing = result.listing!;
    expect(listing.path, '/home/u');
    expect(listing.root, '/home/u');
    expect(listing.trust, isNull);
    expect(listing.trustRequired, isFalse);
    expect(listing.entries, ['Work', 'project']);
    expect(listing.truncated, isFalse);
  });

  test('listDirs includes a non-empty path', () async {
    await pushSessions(capabilities: const ['list-dirs', 'project-session']);
    client.listDirs(path: 'a/b');

    expect(factory.last.lastSent['path'], 'a/b');
  });

  test('listDirs sends no path for an empty path', () async {
    await pushSessions(capabilities: const ['list-dirs', 'project-session']);
    client.listDirs(path: '');

    expect(factory.last.lastSent.containsKey('path'), isFalse);
  });

  test('listings and commands use separate id namespaces', () async {
    await pushSessions(capabilities: const ['list-dirs', 'project-session']);
    final listing = client.listDirs();
    final command = client.sendCommand('s1', 'prompt');
    final listingFrame = factory.last.sentFrames.firstWhere(
      (frame) => frame['type'] == 'list-dirs',
    );
    final commandFrame = factory.last.sentFrames.firstWhere(
      (frame) => frame['type'] == 'command',
    );
    expect(listingFrame['id'], startsWith('dirs-'));
    expect(commandFrame['id'], startsWith('cmd-'));

    // A command-result carrying a listing's id completes the listing as a
    // failure, rather than being swallowed by the command map.
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': listingFrame['id'],
      'ok': false,
      'error': 'invalid path',
    });
    final listingResult = await listing;
    expect(listingResult.ok, isFalse);
    expect(listingResult.error, 'invalid path');

    // The command is untouched by that frame and still completes on its own.
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': commandFrame['id'],
      'ok': true,
    });
    expect((await command).ok, isTrue);
  });

  test('a command-result for a cmd- id leaves the listing pending', () async {
    await pushSessions(capabilities: const ['list-dirs', 'project-session']);
    final listing = client.listDirs();
    final command = client.sendCommand('s1', 'prompt');
    final commandFrame = factory.last.sentFrames.firstWhere(
      (frame) => frame['type'] == 'command',
    );

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': commandFrame['id'],
      'ok': true,
    });
    expect((await command).ok, isTrue);

    var listingCompleted = false;
    listing.then((_) => listingCompleted = true);
    await pumpEventQueue();
    expect(listingCompleted, isFalse);

    final listingFrame = factory.last.sentFrames.firstWhere(
      (frame) => frame['type'] == 'list-dirs',
    );
    factory.last.receive(dirListingFrame(listingFrame['id']! as String));
    expect((await listing).ok, isTrue);
  });

  test('a listing that never receives a frame times out', () async {
    await pushSessions(capabilities: const ['list-dirs', 'project-session']);
    final future = client.listDirs();
    await pumpEventQueue();
    expect(scheduler.commandTimers, hasLength(1));
    expect(scheduler.commandTimers.single.delay, const Duration(seconds: 30));

    scheduler.fireCommandTimeouts();

    final result = await future.timeout(const Duration(seconds: 1));
    expect(result.ok, isFalse);
    expect(result.error, 'timed out');
  });

  test('a disconnect fails an in-flight listing', () async {
    await pushSessions(capabilities: const ['list-dirs', 'project-session']);
    final future = client.listDirs();
    await pumpEventQueue();

    factory.last.remoteClose(1001);
    await pumpEventQueue();

    final result = await future.timeout(const Duration(seconds: 1));
    expect(result.ok, isFalse);
    expect(result.error, 'connection lost');
  });

  test('a second start fails an in-flight listing', () async {
    await pushSessions(capabilities: const ['list-dirs', 'project-session']);
    final future = client.listDirs();
    await pumpEventQueue();
    await client.start('127.0.0.1').timeout(const Duration(seconds: 5));
    await pumpEventQueue();
    final result = await future.timeout(const Duration(seconds: 1));
    expect(result.ok, isFalse);
    expect(result.error, 'connection replaced');
  });

  test('startSession sends cwd and trust', () async {
    await pushSessions(capabilities: const ['list-dirs', 'project-session']);
    client.startSession(cwd: '/home/u/project', trust: true);
    await pumpEventQueue();

    final frame = factory.last.sentFrames.firstWhere(
      (frame) => frame['type'] == 'start-session',
    );
    expect(frame['cwd'], '/home/u/project');
    expect(frame['trust'], true);
  });

  test('startSession sends neither cwd nor trust', () async {
    await pushSessions(capabilities: const ['list-dirs', 'project-session']);
    client.startSession();
    await pumpEventQueue();

    final frame = factory.last.sentFrames.firstWhere(
      (frame) => frame['type'] == 'start-session',
    );
    expect(frame.containsKey('cwd'), isFalse);
    expect(frame.containsKey('trust'), isFalse);
  });

  test('without the capability listDirs refuses without sending', () async {
    await pushSessions();
    final before = factory.last.sent.length;

    final result = await client.listDirs();

    expect(result.ok, isFalse);
    expect(result.error, 'this hub cannot browse folders');
    expect(factory.last.sent.length, before);
  });

  test(
    'without the capability startSession with cwd refuses without sending',
    () async {
      await pushSessions();
      final before = factory.last.sent.length;

      final result = await client.startSession(cwd: '/home/u/project');

      expect(result.ok, isFalse);
      expect(result.error, 'this hub cannot start a session in a chosen folder');
      expect(factory.last.sent.length, before);
    },
  );

  test(
    'without the capability startSession with trust refuses without sending',
    () async {
      await pushSessions();
      final before = factory.last.sent.length;

      final result = await client.startSession(trust: true);

      expect(result.ok, isFalse);
      expect(result.error, 'this hub cannot start a session in a chosen folder');
      expect(factory.last.sent.length, before);
    },
  );

  test('startSession drops trust when there is no cwd', () async {
    await pushSessions(capabilities: const ['list-dirs', 'project-session']);
    client.startSession(trust: true);
    await pumpEventQueue();

    final frame = factory.last.sentFrames.firstWhere(
      (frame) => frame['type'] == 'start-session',
    );
    expect(frame.containsKey('cwd'), isFalse);
    expect(frame.containsKey('trust'), isFalse);
  });
}
