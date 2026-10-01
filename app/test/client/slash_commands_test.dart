// Slash-command completion on the client: opening a session fetches the active
// session's real pi commands and caches them per session id, so the composer can
// suggest them. The cache write is keyed by the *requesting* session — never
// `_state.activeSessionId` — and is dropped once that session is gone, so a late
// reply can never land on a session that did not ask for it.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';

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

  Map<String, Object?>? listFrameFor(String sessionId) {
    for (final frame in factory.last.sentFrames) {
      if (frame['type'] == 'command' &&
          frame['name'] == 'listCommands' &&
          frame['sessionId'] == sessionId) {
        return frame;
      }
    }
    return null;
  }

  List<Map<String, Object?>> listFrames() => factory.last.sentFrames
      .where(
        (frame) =>
            frame['type'] == 'command' && frame['name'] == 'listCommands',
      )
      .toList();

  void reply(Object? id, {bool ok = true, List<Object?>? commands}) {
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': id,
      'ok': ok,
      'commands': ?commands,
    });
  }

  Future<void> sessionGone(String sessionId) async {
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'session-gone',
      'sessionId': sessionId,
    });
    await pumpEventQueue();
  }

  test(
    'listCommands sends a command named listCommands for the session',
    () async {
      final future = client.listCommands('s1');

      final frame = factory.last.lastSent;
      expect(frame['type'], 'command');
      expect(frame['name'], 'listCommands');
      expect(frame['sessionId'], 's1');

      reply(frame['id'], commands: [
        {'name': 'review', 'description': 'Review the working tree'},
        {'name': 'implement-vetted'},
      ]);

      final result = await future;
      expect(result.ok, isTrue);
      expect(result.commands, isNotNull);
      expect(result.commands!.map((command) => command.name).toList(), [
        'review',
        'implement-vetted',
      ]);
      expect(result.commands![0].description, 'Review the working tree');
      expect(result.commands![1].description, isNull);
    },
  );

  test(
    'opening a session fetches the commands and caches them under its id',
    () async {
      client.subscribe('s1');
      await pumpEventQueue();

      final frame = listFrameFor('s1');
      expect(frame, isNotNull);

      reply(frame!['id'], commands: [
        {'name': 'review'},
      ]);
      await pumpEventQueue();

      expect(client.state.commands['s1'], isNotNull);
      expect(client.state.commands['s1']!.single.name, 'review');
    },
  );

  test(
    'a refused list leaves the cache empty, logs no error, and is sent once',
    () async {
      client.subscribe('s1');
      await pumpEventQueue();

      final frame = listFrameFor('s1')!;
      // A well-formed payload *plus* the refusal, so only the `!ok` check can
      // explain the empty cache.
      reply(frame['id'], ok: false, commands: [
        {'name': 'review'},
      ]);
      await pumpEventQueue();

      expect(client.state.commands['s1'], isNull);
      expect(client.state.lastError, isNull);
      expect(listFrames(), hasLength(1));
      // The list's own 30s timer must be cancelled by the arriving result; it
      // is the only command timer in this test.
      expect(scheduler.commandTimers, hasLength(1));
      expect(scheduler.commandTimers.single.cancelled, isTrue);
    },
  );

  test(
    'a reply for session A while B is active is cached under A, never B',
    () async {
      client.subscribe('s1');
      await pumpEventQueue();
      final aFrame = listFrameFor('s1')!;

      client.subscribe('s2');
      await pumpEventQueue();

      reply(aFrame['id'], commands: [
        {'name': 'review'},
      ]);
      await pumpEventQueue();

      expect(client.state.commands['s1'], isNotNull);
      expect(client.state.commands['s2'], isNull);
    },
  );

  test(
    'a late reply after the session is gone does not resurrect the cache',
    () async {
      client.subscribe('s1');
      await pumpEventQueue();
      final frame = listFrameFor('s1')!;
      await pumpEventQueue();

      // Past the give-up cap the session is genuinely gone and its cache key is
      // dropped; a result that arrives afterwards must not recreate it.
      for (var i = 0; i <= HubClient.maxConsecutiveSessionGone; i++) {
        await sessionGone('s1');
      }

      reply(frame['id'], commands: [
        {'name': 'review'},
      ]);
      await pumpEventQueue();

      expect(client.state.commands.containsKey('s1'), isFalse);
    },
  );

  test('a reply that lands before teardown does not resurrect the cache', () async {
    client.subscribe('s1');
    await pumpEventQueue();
    final frame = listFrameFor('s1')!;
    // Reply and teardown delivered in one burst, so the reply's continuation
    // is queued but not yet run when the gones are processed. The cache key
    // must still be absent afterwards (the gave-up branch removes it).
    reply(frame['id'], commands: [
      {'name': 'review'},
    ]);
    for (var i = 0; i <= HubClient.maxConsecutiveSessionGone; i++) {
      factory.last.receive({
        'protocolVersion': 1,
        'type': 'session-gone',
        'sessionId': 's1',
      });
    }
    await pumpEventQueue();

    expect(client.state.commands.containsKey('s1'), isFalse);
  });

  test('session-gone past the cap drops the cached commands', () async {
    client.subscribe('s1');
    await pumpEventQueue();
    reply(listFrameFor('s1')!['id'], commands: [
      {'name': 'review'},
    ]);
    await pumpEventQueue();
    expect(client.state.commands['s1'], isNotNull);

    for (var i = 0; i <= HubClient.maxConsecutiveSessionGone; i++) {
      await sessionGone('s1');
    }

    expect(client.state.commands.containsKey('s1'), isFalse);
  });

  test('a session that comes back re-fetches its commands', () async {
    client.subscribe('s1');
    await pumpEventQueue();
    expect(listFrames(), hasLength(1));

    // Under the cap a transient `session-gone` re-arms the restore, so the next
    // registry push that includes the session re-subscribes and refetches.
    await sessionGone('s1');
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'sessions',
      'sessions': [
        {'sessionId': 's1', 'label': 'one', 'agentState': 'idle'},
      ],
    });
    await pumpEventQueue();

    expect(listFrames(), hasLength(2));
  });

  test('commands for one session never appear under another', () async {
    client.subscribe('s1');
    await pumpEventQueue();
    reply(listFrameFor('s1')!['id'], commands: [
      {'name': 'review'},
    ]);
    await pumpEventQueue();

    client.subscribe('s2');
    await pumpEventQueue();
    reply(listFrameFor('s2')!['id'], commands: [
      {'name': 'compact'},
    ]);
    await pumpEventQueue();

    expect(client.state.commands['s1']!.single.name, 'review');
    expect(client.state.commands['s2']!.single.name, 'compact');
  });
}
