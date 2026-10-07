// Session-control client behaviour: `/new` and `/fork` replace the pi session,
// and the app follows the replacement instead of re-subscribing the dead id.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/hub_client.dart';

import 'support/fakes.dart';

const String testToken =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Map<String, Object?> sessionsFrame(List<Map<String, Object?>> entries) => {
  'protocolVersion': 1,
  'type': 'sessions',
  'sessions': entries,
};

Map<String, Object?> sessionGone(String sessionId) => {
  'protocolVersion': 1,
  'type': 'session-gone',
  'sessionId': sessionId,
};

Map<String, Object?> commandResult(
  String id, {
  required bool ok,
  String? error,
}) => {
  'protocolVersion': 1,
  'type': 'command-result',
  'id': id,
  'ok': ok,
  'error': ?error,
};

Map<String, Object?> summary(
  String sessionId, {
  String? replaces,
  String label = 'one',
}) => {
  'sessionId': sessionId,
  'label': label,
  'agentState': 'idle',
  'replacesSessionId': ?replaces,
};

void main() {
  late FakeSocketFactory factory;
  late FakeScheduler scheduler;
  late HubClient client;

  FakeHubSocket socket() => factory.last;

  List<Map<String, Object?>> framesOfType(String type) =>
      socket().sentFrames.where((frame) => frame['type'] == type).toList();

  List<String> subscribedIds() => framesOfType(
    'subscribe',
  ).map((frame) => frame['sessionId']! as String).toList();

  /// The `command` frame the client most recently sent for [name].
  Map<String, Object?> lastCommand(String name) => framesOfType(
    'command',
  ).lastWhere((frame) => frame['name'] == name);

  /// Brings the client up and puts it on `s1`, as if the user had opened it.
  Future<void> openS1() async {
    socket().receive(sessionsFrame([]));
    await pumpEventQueue();
    client.subscribe('s1');
    await pumpEventQueue();
  }

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

  test(
    'a sessions push naming a replacement re-subscribes to it and never '
    're-subscribes the dead id',
    () async {
      await openS1();
      final subscribeBefore = framesOfType('subscribe').length;

      final future = client.sessionNew('s1');
      socket().receive(sessionGone('s1'));
      await pumpEventQueue();

      // No successor yet. The retired push must NOT restore the dead id.
      socket().receive(sessionsFrame([]));
      await pumpEventQueue();
      expect(
        framesOfType('subscribe').length,
        subscribeBefore,
        reason: 'the dead session id must never be re-subscribed',
      );

      // The successor names the old id: adopt it.
      socket().receive(sessionsFrame([summary('s2', replaces: 's1')]));
      await pumpEventQueue();

      expect(client.state.activeSessionId, 's2');
      expect(subscribedIds().last, 's2');
      expect(framesOfType('history-request').last['sessionId'], 's2');
      expect((await future.timeout(const Duration(seconds: 1))).ok, isTrue);
    },
  );

  test(
    'a session-gone for the awaited session settles the pending, cancels its '
    'command timer, and leaves the replacement timer armed',
    () async {
      await openS1();

      final future = client.sessionNew('s1');
      expect(scheduler.replacementTimers, hasLength(1));
      final commandTimer = scheduler.commandTimers.last;

      socket().receive(sessionGone('s1'));
      await pumpEventQueue();

      final result = await future.timeout(const Duration(seconds: 1));
      expect(result.ok, isTrue, reason: 'the replacement is the witness');
      expect(commandTimer.cancelled, isTrue);
      // The successor has not registered yet, so the follow must still be
      // armed: its timer is what bounds the wait. Cancelling the whole follow
      // here is the bug this test guards, and the old command-timer assertion
      // could not see it.
      expect(scheduler.replacementTimers.single.cancelled, isFalse);
    },
  );

  test('an ok ack does not settle sessionNew; the successor does', () async {
    await openS1();

    final future = client.sessionNew('s1');
    var completed = false;
    unawaited(
      future.then((_) {
        completed = true;
      }),
    );
    final id = lastCommand('sessionNew')['id']! as String;

    socket().receive(commandResult(id, ok: true));
    await pumpEventQueue();
    expect(completed, isFalse, reason: 'the ack is not the witness');
    expect(scheduler.replacementTimers.single.cancelled, isFalse);

    socket().receive(sessionsFrame([summary('s2', replaces: 's1')]));
    await pumpEventQueue();

    expect((await future.timeout(const Duration(seconds: 1))).ok, isTrue);
    expect(client.state.activeSessionId, 's2');
    expect(subscribedIds().last, 's2');
  });

  test('a refused ack fails sessionNew and disarms the follow', () async {
    await openS1();

    final future = client.sessionNew('s1');
    final id = lastCommand('sessionNew')['id']! as String;

    socket().receive(commandResult(id, ok: false, error: 'unknown entry'));
    await pumpEventQueue();

    final result = await future.timeout(const Duration(seconds: 1));
    expect(result.ok, isFalse);
    expect(result.error, 'unknown entry');
    expect(scheduler.replacementTimers.single.cancelled, isTrue);

    // With the follow disarmed, a genuine session-gone clears the restore
    // guard and the next push restores normally — no 15 s suppression.
    socket().receive(sessionGone('s1'));
    await pumpEventQueue();
    final before = framesOfType('subscribe').length;
    socket().receive(sessionsFrame([]));
    await pumpEventQueue();
    expect(framesOfType('subscribe').length, before + 1);
    expect(subscribedIds().last, 's1');
  });

  test(
    'subscribing elsewhere mid-follow is not overridden by adoption',
    () async {
      await openS1();

      final future = client.sessionNew('s1');
      client.subscribe('s3');
      await pumpEventQueue();
      expect(client.state.activeSessionId, 's3');

      // The successor for the abandoned follow must not yank the user to s2.
      final before = framesOfType('subscribe').length;
      socket().receive(sessionsFrame([summary('s2', replaces: 's1')]));
      await pumpEventQueue();
      expect(client.state.activeSessionId, 's3');
      expect(subscribedIds().last, 's3');
      expect(framesOfType('subscribe').length, before);

      final result = await future.timeout(const Duration(seconds: 1));
      expect(result.ok, isFalse);
      expect(result.error, 'superseded');
    },
  );

  test(
    'a second replacement for a different id supersedes the first',
    () async {
      await openS1();

      final first = client.sessionNew('s1');
      final second = client.sessionNew('s2');
      await pumpEventQueue();

      final firstResult = await first.timeout(const Duration(seconds: 1));
      expect(firstResult.ok, isFalse);
      expect(firstResult.error, 'superseded');

      // The second follows its own successor normally.
      socket().receive(sessionsFrame([summary('s3', replaces: 's2')]));
      await pumpEventQueue();
      expect((await second.timeout(const Duration(seconds: 1))).ok, isTrue);
      expect(client.state.activeSessionId, 's3');
    },
  );

  test('a lost socket does not settle a replacement follow', () async {
    await openS1();

    final future = client.sessionNew('s1');
    var completed = false;
    unawaited(
      future.then((_) {
        completed = true;
      }),
    );

    socket().remoteClose(1006);
    await pumpEventQueue();

    expect(
      completed,
      isFalse,
      reason:
          'the replacement proceeds server-side; only its own timer says '
          'otherwise',
    );
    expect(scheduler.replacementTimers.single.cancelled, isFalse);

    // The follow is still bounded by the replacement timer.
    scheduler.fireReplacementTimeouts();
    await pumpEventQueue();
    final result = await future.timeout(const Duration(seconds: 1));
    expect(result.ok, isFalse);
    expect(result.error, 'the session did not come back');
  });

  test('a replacement that never arrives falls back to the list', () async {
    await openS1();

    final future = client.sessionNew('s1');
    scheduler.fireReplacementTimeouts();
    await pumpEventQueue();

    final result = await future.timeout(const Duration(seconds: 1));
    expect(result.ok, isFalse);
    expect(result.error, 'the session did not come back');

    // The follow is cleared, `_resubscribed` is false and `_desiredSessionId`
    // is still `s1`: the next push restores the old id through the normal path.
    final before = framesOfType('subscribe').length;
    socket().receive(sessionsFrame([]));
    await pumpEventQueue();
    expect(framesOfType('subscribe').length, before + 1);
    expect(subscribedIds().last, 's1');

    // From there the existing give-up machinery resumes.
    for (var i = 0; i < HubClient.maxConsecutiveSessionGone; i++) {
      socket().receive(sessionGone('s1'));
      await pumpEventQueue();
      socket().receive(sessionsFrame([]));
      await pumpEventQueue();
    }
    socket().receive(sessionGone('s1'));
    await pumpEventQueue();

    expect(client.state.lastError, isNotNull);
    expect(client.state.lastError, contains('s1'));
  });

  test(
    'a genuine session-gone without a successor still returns to the list',
    () async {
      await openS1();

      // No `sessionNew`: no follow is armed, so this is the pre-existing path.
      socket().receive(sessionGone('s1'));
      await pumpEventQueue();
      expect(client.state.activeSessionId, isNull);

      final before = framesOfType('subscribe').length;
      socket().receive(sessionsFrame([]));
      await pumpEventQueue();
      expect(framesOfType('subscribe').length, before + 1);
    },
  );

  test(
    'a successor push arriving before the old session-gone still settles the '
    'follow once',
    () async {
      await openS1();

      final future = client.sessionNew('s1');
      socket().receive(sessionsFrame([summary('s2', replaces: 's1')]));
      await pumpEventQueue();

      expect(client.state.activeSessionId, 's2');
      expect((await future.timeout(const Duration(seconds: 1))).ok, isTrue);

      // The late `session-gone` must not fail the settled future nor move the
      // active session off the successor.
      socket().receive(sessionGone('s1'));
      await pumpEventQueue();
      expect(client.state.activeSessionId, 's2');
    },
  );

  test('listTree parses the tree and a refusal is surfaced', () async {
    final future = client.listTree('s1');
    final id = lastCommand('listTree')['id']! as String;

    socket().receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': id,
      'ok': true,
      'tree': [
        {'id': 'e1', 'parentId': null, 'role': 'user', 'text': 'hi'},
        {
          'id': 'e2',
          'parentId': 'e1',
          'role': 'assistant',
          'text': 'yo',
          'label': 'L',
        },
      ],
      'treeTruncated': true,
    });

    final result = await future.timeout(const Duration(seconds: 1));
    expect(result.ok, isTrue);
    expect(result.tree, hasLength(2));
    expect(result.tree!.first.id, 'e1');
    expect(result.tree!.first.parentId, isNull);
    expect(result.tree![1].label, 'L');
    expect(result.treeTruncated, isTrue);

    final refusal = client.listTree('s1');
    final refusalId = lastCommand('listTree')['id']! as String;
    socket().receive({
      'protocolVersion': 1,
      'type': 'command-result',
      'id': refusalId,
      'ok': false,
      'error': 'cannot read the tree',
    });

    final refused = await refusal.timeout(const Duration(seconds: 1));
    expect(refused.ok, isFalse);
    expect(refused.error, 'cannot read the tree');
  });

  test('stop cancels an in-flight replacement follow', () async {
    await openS1();
    client.sessionNew('s1');
    expect(scheduler.replacementTimers, hasLength(1));

    await client.stop();

    expect(scheduler.replacementTimers.single.cancelled, isTrue);
  });

  test('disconnect cancels an in-flight replacement follow', () async {
    await openS1();
    client.sessionNew('s1');
    expect(scheduler.replacementTimers, hasLength(1));

    await client.disconnect();

    expect(scheduler.replacementTimers.single.cancelled, isTrue);
  });

  test('starting on a new hub clears a follow armed on the old one', () async {
    await openS1();
    client.sessionNew('s1');
    expect(scheduler.replacementTimers, hasLength(1));

    await client.start('10.0.0.9');
    await pumpEventQueue();

    expect(scheduler.replacementTimers.single.cancelled, isTrue);
  });

  test('sessionNew and sessionFork send the right frames and args', () async {
    client.sessionNew('s1');
    final newFrame = lastCommand('sessionNew');
    expect(newFrame['sessionId'], 's1');
    expect(newFrame.containsKey('args'), isFalse);

    client.sessionFork('s1', 'e9');
    final forkFrame = lastCommand('sessionFork');
    expect(forkFrame['sessionId'], 's1');
    expect(forkFrame['args'], {'entryId': 'e9'});
  });

  test('listTree parses the leaf id and a null leaf', () async {
    Map<String, Object?> reply(String id, Map<String, Object?> extra) => {
      'protocolVersion': 1,
      'type': 'command-result',
      'id': id,
      'ok': true,
      'tree': <Object?>[],
      ...extra,
    };

    final withLeaf = client.listTree('s1');
    socket().receive(
      reply(lastCommand('listTree')['id']! as String, {'leafId': 'e2'}),
    );
    expect(
      (await withLeaf.timeout(const Duration(seconds: 1))).leafId,
      'e2',
    );

    final withNull = client.listTree('s1');
    socket().receive(
      reply(lastCommand('listTree')['id']! as String, {'leafId': null}),
    );
    expect(
      (await withNull.timeout(const Duration(seconds: 1))).leafId,
      isNull,
    );

    // An older bridge omits the field: an unknown position, not an error.
    final absent = client.listTree('s1');
    socket().receive(reply(lastCommand('listTree')['id']! as String, {}));
    expect(
      (await absent.timeout(const Duration(seconds: 1))).leafId,
      isNull,
    );
  });

  test('a leaf event re-requests history for the active session', () async {
    await openS1();
    final requestsBefore = framesOfType('history-request').length;
    final entriesBefore = client.transcript('s1')!.entries.length;

    socket().receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {'kind': 'leaf', 'leafId': 'e9'},
    });
    await pumpEventQueue();

    final requests = framesOfType('history-request');
    expect(requests.length, requestsBefore + 1);
    expect(requests.last['sessionId'], 's1');
    expect(
      client.transcript('s1')!.entries.length,
      entriesBefore,
      reason: 'a leaf is a signal, not a transcript row',
    );
  });

  test('sessionTree sends the command frame with the entry id', () async {
    final future = client.sessionTree('s1', 'e9');
    final frame = lastCommand('sessionTree');
    expect(frame['sessionId'], 's1');
    expect(frame['args'], {'entryId': 'e9'});

    // A navigation does not replace the session, so the ack settles it — no
    // successor-follow machinery is armed.
    socket().receive(commandResult(frame['id']! as String, ok: true));
    expect((await future.timeout(const Duration(seconds: 1))).ok, isTrue);
    expect(scheduler.replacementTimers, isEmpty);
  });

  test('a leaf event reaches the leaf stream with the session and leaf', () async {
    await openS1();
    final events = <LeafEvent>[];
    final subscription = client.leafEvents.listen(events.add);
    addTearDown(subscription.cancel);

    socket().receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {'kind': 'leaf', 'leafId': 'e9'},
    });
    await pumpEventQueue();

    expect(events, hasLength(1));
    expect(events.single.sessionId, 's1');
    expect(events.single.leafId, 'e9');
  });

  test('the leaf stream closes when the client stops', () async {
    await openS1();
    var done = false;
    client.leafEvents.listen((_) {}, onDone: () => done = true);

    await client.stop();
    await pumpEventQueue();

    expect(done, isTrue);
  });
}
