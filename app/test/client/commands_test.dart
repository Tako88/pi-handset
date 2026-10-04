// Commands: every allowlisted name is sendable with a correlation id, and a
// `command-result` is routed back to the caller that issued it.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';

import 'support/fakes.dart';

const String testToken =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

const List<String> allowlisted = [
  'prompt',
  'steer',
  'followup',
  'abort',
  'setModel',
  'setThinkingLevel',
  'compact',
  'fetchHistory',
  'setSessionName',
];

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

  test('a command carries id, sessionId, name and args', () async {
    client.sendCommand('s1', 'prompt', args: {'text': 'hi'});

    final frame = factory.last.lastSent;
    expect(frame['type'], 'command');
    expect(frame['name'], 'prompt');
    expect(frame['sessionId'], 's1');
    expect(frame['args'], {'text': 'hi'});
    expect(frame['id'], isNotEmpty);
  });

  test('a command-result completes the future of its issuer', () async {
    final future = client.sendCommand('s1', 'prompt', args: {'text': 'hi'});
    final id = factory.last.lastSent['id']! as String;

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': id,
      'ok': true,
    });

    final result = await future;
    expect(result.ok, isTrue);
    expect(result.error, isNull);
  });

  test('a queued command-result is reported as queued', () async {
    final future = client.sendCommand('s1', 'prompt', args: {'text': 'hi'});
    final id = factory.last.lastSent['id']! as String;

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': id,
      'ok': true,
      'queued': true,
    });

    final result = await future;
    expect(result.queued, isTrue);
  });

  test('a command-result without queued reports unknown, not false', () async {
    final future = client.sendCommand('s1', 'prompt', args: {'text': 'hi'});
    final id = factory.last.lastSent['id']! as String;

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': id,
      'ok': true,
    });

    final result = await future;
    // Absent means "unknown": the app must not read silence as "not queued".
    expect(result.queued, isNull);
  });

  test(
    'results route to the caller that issued them, not by arrival order',
    () async {
      final first = client.sendCommand('s1', 'prompt', args: {'text': 'a'});
      final second = client.sendCommand('s1', 'abort');
      final frames = factory.last.sentFrames
          .where((frame) => frame['type'] == 'command')
          .toList();
      final firstId = frames[0]['id']! as String;
      final secondId = frames[1]['id']! as String;
      expect(firstId, isNot(secondId));

      // The second command's result arrives first and carries the failure.
      factory.last.receive({
        'protocolVersion': 1,
        'type': 'command-result',
        'id': secondId,
        'ok': false,
        'error': 'no active session',
      });
      factory.last.receive({
        'protocolVersion': 1,
        'type': 'command-result',
        'id': firstId,
        'ok': true,
      });

      expect((await first).ok, isTrue);
      final secondResult = await second;
      expect(secondResult.ok, isFalse);
      expect(secondResult.error, 'no active session');
    },
  );

  test('every allowlisted command name is sendable', () async {
    for (final name in allowlisted) {
      client.sendCommand('s1', name);
    }

    final sentNames = factory.last.sentFrames
        .where((frame) => frame['type'] == 'command')
        .map((frame) => frame['name'])
        .toList();
    expect(sentNames, allowlisted);
  });

  test('a command schedules a timeout and fails when it fires', () async {
    final future = client.sendCommand('s1', 'prompt');
    await pumpEventQueue();
    expect(scheduler.commandTimers, hasLength(1));
    expect(scheduler.commandTimers.single.delay, const Duration(seconds: 30));

    scheduler.fireCommandTimeouts();

    final result = await future.timeout(const Duration(seconds: 1));
    expect(result.ok, isFalse);
    expect(result.error, isNotNull);
  });

  test('stop fails every pending command', () async {
    final first = client.sendCommand('s1', 'prompt');
    final second = client.sendCommand('s1', 'abort');
    await pumpEventQueue();

    await client.stop();

    final firstResult = await first.timeout(const Duration(seconds: 1));
    final secondResult = await second.timeout(const Duration(seconds: 1));
    expect(firstResult.ok, isFalse);
    expect(secondResult.ok, isFalse);
  });

  test('a second start fails pending commands', () async {
    final future = client.sendCommand('s1', 'prompt');
    await pumpEventQueue();
    await client.start('127.0.0.1').timeout(const Duration(seconds: 5));
    await pumpEventQueue();
    final result = await future.timeout(const Duration(seconds: 1));
    expect(result.ok, isFalse);
  });

  test('losing the socket fails pending commands', () async {
    final future = client.sendCommand('s1', 'prompt');
    await pumpEventQueue();

    factory.last.remoteClose(1001);
    await pumpEventQueue();

    final result = await future.timeout(const Duration(seconds: 1));
    expect(result.ok, isFalse);
  });

  test('session-gone fails that session\'s pending commands', () async {
    final future = client.sendCommand('s1', 'prompt');
    await pumpEventQueue();

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'session-gone',
      'sessionId': 's1',
    });
    await pumpEventQueue();

    final result = await future.timeout(const Duration(seconds: 1));
    expect(result.ok, isFalse);
  });

  test('a throwing send fails the command rather than throwing', () async {
    factory.last.throwOnSend = true;

    final result = await client
        .sendCommand('s1', 'prompt')
        .timeout(const Duration(seconds: 1));

    expect(result.ok, isFalse);
    expect(result.error, isNotNull);
    // The entry and its timer must not be left to fire at the 30s timeout.
    expect(scheduler.commandTimers, hasLength(1));
    expect(scheduler.commandTimers.single.cancelled, isTrue);
  });

  test('session-gone leaves another session\'s commands pending', () async {
    final gone = client.sendCommand('s1', 'prompt');
    final kept = client.sendCommand('s2', 'prompt');
    await pumpEventQueue();

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'session-gone',
      'sessionId': 's1',
    });
    await pumpEventQueue();

    final goneResult = await gone.timeout(const Duration(seconds: 1));
    expect(goneResult.ok, isFalse);

    // The other session's command is untouched: still pending, and a result
    // for it still completes its future.
    final keptId =
        factory.last.sentFrames.firstWhere(
              (frame) =>
                  frame['type'] == 'command' && frame['sessionId'] == 's2',
            )['id']!
            as String;
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': keptId,
      'ok': true,
    });

    final keptResult = await kept.timeout(const Duration(seconds: 1));
    expect(keptResult.ok, isTrue);
  });

  test('sendCommand fails immediately with no live socket', () async {
    await client.stop();

    final result = await client
        .sendCommand('s1', 'prompt')
        .timeout(const Duration(seconds: 1));
    expect(result.ok, isFalse);
    expect(result.error, isNotNull);
  });
}
