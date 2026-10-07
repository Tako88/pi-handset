// Reconnect policy: capped jittered backoff, reset on a successful connect,
// no reconnect on a `4003` capability close, a longer fixed wait on `4008`.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/hub_client.dart';

import 'support/fakes.dart';

const String testToken =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  late FakeSocketFactory factory;
  late FakeScheduler scheduler;
  late HubClient client;

  HubClient makeClient(double Function() rng) => HubClient(
    socketFactory: factory.call,
    scheduler: scheduler,
    tokenStore: InMemoryTokenStore(initial: testToken),
    rng: rng,
  );

  /// Fires the pending reconnect wait and lets its dial settle.
  Future<void> reconnect() async {
    scheduler.reconnectTimers.last.fire();
    await pumpEventQueue();
  }

  /// The hub's token-auth confirmation: the first `sessions` push.
 Map<String, Object?> sessionsFrame() => const {
    'protocolVersion': 1,
    'type': 'sessions',
    'sessions': <Object?>[],
  };

  List<Map<String, Object?>> framesOfType(FakeHubSocket socket, String type) =>
      socket.sentFrames.where((frame) => frame['type'] == type).toList();

  setUp(() {
    factory = FakeSocketFactory();
    scheduler = FakeScheduler();
    client = makeClient(() => 1.0);
  });

  test('backoff grows exponentially and is capped', () async {
    factory.onDial = () => Exception('connection refused');

    await client.start('127.0.0.1');
    await pumpEventQueue();

    for (var i = 0; i < 8; i++) {
      await reconnect();
    }

    expect(scheduler.reconnectDelays, [
      const Duration(milliseconds: 500),
      const Duration(milliseconds: 1000),
      const Duration(milliseconds: 2000),
      const Duration(milliseconds: 4000),
      const Duration(milliseconds: 8000),
      const Duration(milliseconds: 16000),
      const Duration(milliseconds: 30000),
      const Duration(milliseconds: 30000),
      const Duration(milliseconds: 30000),
    ]);
  });

  test('a successful connect resets the attempt count', () async {
    factory.onDial = () => Exception('connection refused');
    await client.start('127.0.0.1');
    await pumpEventQueue();
    await reconnect();
    await reconnect();
    // Delays so far: 500, 1000, 2000. Without a reset the next would be 4000.
    expect(scheduler.reconnectDelays.last, const Duration(milliseconds: 2000));

    // The next dial succeeds: attempt count resets on the open.
    factory.onDial = null;
    await reconnect();
    final socket = factory.last;
    expect(socket.sent, isNotEmpty);

    socket.remoteClose(1001);
    await pumpEventQueue();

    expect(scheduler.reconnectDelays.last, const Duration(milliseconds: 500));
    expect(client.state.status, HubConnectionStatus.connecting);
  });

  test('a 4003 capability close does not reconnect', () async {
    await client.start('127.0.0.1');
    await pumpEventQueue();
    scheduler.flushNotifications();
    scheduler.clear();

    factory.last.remoteClose(4003, 'capability violation');
    await pumpEventQueue();

    expect(scheduler.reconnectTimers, isEmpty);
    expect(client.state.status, HubConnectionStatus.disconnected);
  });

  test('a redial re-subscribes the active session and re-requests history', () async {
    await client.start('127.0.0.1');
    await pumpEventQueue();
    factory.last.receive(sessionsFrame());
    await pumpEventQueue();
    client.subscribe('s1');

    // The socket drops; the hub forgets the subscription with it.
    factory.last.remoteClose(1001);
    await pumpEventQueue();
    await reconnect();

    final newSocket = factory.last;
    expect(newSocket, isNot(same(factory.sockets.first)));
    // Anything sent before authentication would race the hub's hello check.
    expect(framesOfType(newSocket, 'subscribe'), isEmpty);

    newSocket.receive(sessionsFrame());
    await pumpEventQueue();

    expect(framesOfType(newSocket, 'subscribe'), hasLength(1));
    expect(framesOfType(newSocket, 'subscribe').single['sessionId'], 's1');
    expect(framesOfType(newSocket, 'history-request'), hasLength(1));
    expect(
      framesOfType(newSocket, 'history-request').single['sessionId'],
      's1',
    );
  });

  test('a reconnect requests history exactly once', () async {
    // The automatic restore after a redial must re-request history, but only
    // once: the re-subscribe itself must not add a second request.
    await client.start('127.0.0.1');
    await pumpEventQueue();
    factory.last.receive(sessionsFrame());
    await pumpEventQueue();
    client.subscribe('s1');
    expect(framesOfType(factory.last, 'history-request'), hasLength(1));

    factory.last.remoteClose(1001);
    await pumpEventQueue();
    await reconnect();

    final newSocket = factory.last;
    newSocket.receive(sessionsFrame());
    await pumpEventQueue();

    expect(framesOfType(newSocket, 'subscribe'), hasLength(1));
    expect(framesOfType(newSocket, 'history-request'), hasLength(1));
    expect(
      framesOfType(newSocket, 'history-request').single['sessionId'],
      's1',
    );
  });

  test('a reconnect must not discard the visible transcript', () async {
    // The user was looking at a reply before the hub restarted. The client
    // redials and re-subscribes automatically; if the agent has not
    // re-registered yet the hub answers `session-gone`. That is a transient
    // gap during a reconnect, not a deletion, so the visible transcript must
    // survive it — whatever the hub does or does not send back afterwards.
    await client.start('127.0.0.1');
    await pumpEventQueue();
    factory.last.receive(sessionsFrame());
    await pumpEventQueue();
    client.subscribe('s1');

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {'kind': 'stream', 'seq': 1, 'text': 'earlier reply'},
    });
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'event',
      'payload': {
        'kind': 'message',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'earlier reply'},
          ],
        },
      },
    });
    await pumpEventQueue();
    expect(client.transcript('s1')!.entries, hasLength(1));

    factory.last.remoteClose(1001);
    await pumpEventQueue();
    await reconnect();

    final newSocket = factory.last;
    newSocket.receive(sessionsFrame());
    await pumpEventQueue();
    newSocket.receive({
      'protocolVersion': 1,
      'type': 'session-gone',
      'sessionId': 's1',
    });
    await pumpEventQueue();

    expect(
      client.transcript('s1')?.entries,
      hasLength(1),
      reason: 'a reconnect must not discard the visible transcript',
    );
  });

  test('a rejected re-subscribe is retried when the session reappears', () async {
    // A hub restart: the client redials with the token, but the agent has not
    // re-registered yet, so the hub answers the re-subscribe with
    // `session-gone`. When the agent re-registers, the client must retry rather
    // than stay silently unsubscribed.
    await client.start('127.0.0.1');
    await pumpEventQueue();
    factory.last.receive(sessionsFrame());
    await pumpEventQueue();
    client.subscribe('s1');

    factory.last.remoteClose(1001);
    await pumpEventQueue();
    await reconnect();

    final newSocket = factory.last;
    newSocket.receive(sessionsFrame());
    await pumpEventQueue();
    expect(framesOfType(newSocket, 'subscribe'), hasLength(1));

    newSocket.receive({
      'protocolVersion': 1,
      'type': 'session-gone',
      'sessionId': 's1',
    });
    await pumpEventQueue();
    expect(client.state.activeSessionId, isNull);

    newSocket.receive({
      'protocolVersion': 1,
      'type': 'sessions',
      'sessions': [
        {'sessionId': 's1', 'label': 'one', 'agentState': 'idle'},
      ],
    });
    await pumpEventQueue();

    expect(framesOfType(newSocket, 'subscribe'), hasLength(2));
    expect(framesOfType(newSocket, 'subscribe').last['sessionId'], 's1');
    expect(framesOfType(newSocket, 'history-request'), hasLength(2));
    expect(client.state.activeSessionId, 's1');
  });

  test('a session that stays gone is retried to a cap, then abandoned', () async {
    // The race the M10b fix targeted (a re-subscribe racing the agent's
    // re-registration) must keep retrying. But a session that is genuinely gone
    // — deleted, or the agent switched/forked away — answers `session-gone`
    // forever. Without a cap, every registry push resends subscribe+history
    // and nothing ever surfaces an error.
    await client.start('127.0.0.1');
    await pumpEventQueue();
    factory.last.receive(sessionsFrame());
    await pumpEventQueue();
    client.subscribe('s1');
    final socket = factory.last;

    const gone = {
      'protocolVersion': 1,
      'type': 'session-gone',
      'sessionId': 's1',
    };
    const sessionsWithoutS1 = {
      'protocolVersion': 1,
      'type': 'sessions',
      'sessions': <Object?>[],
    };

    // Under the cap each rejection re-arms and the next push retries.
    for (var i = 0; i < HubClient.maxConsecutiveSessionGone; i++) {
      socket.receive(gone);
      await pumpEventQueue();
      socket.receive(sessionsWithoutS1);
      await pumpEventQueue();
    }
    expect(framesOfType(socket, 'subscribe'), hasLength(4)); // the first + 3.

    // Past the cap the client must stop: clear the desired session, keep
    // `activeSessionId` from flapping back, and surface the reason.
    socket.receive(gone);
    await pumpEventQueue();
    final subscribeAtGiveUp = framesOfType(socket, 'subscribe').length;
    final historyAtGiveUp = framesOfType(socket, 'history-request').length;
    for (var i = 0; i < 3; i++) {
      socket.receive(sessionsWithoutS1);
      await pumpEventQueue();
    }

    expect(framesOfType(socket, 'subscribe'), hasLength(subscribeAtGiveUp));
    expect(framesOfType(socket, 'history-request'), hasLength(historyAtGiveUp));
    expect(client.state.activeSessionId, isNull);
    expect(client.state.lastError, isNotNull);
    expect(client.state.lastError, contains('s1'));
  });

  test('a redial without an active session subscribes to nothing', () async {
    await client.start('127.0.0.1');
    await pumpEventQueue();
    factory.last.receive(sessionsFrame());
    await pumpEventQueue();

    factory.last.remoteClose(1001);
    await pumpEventQueue();
    await reconnect();
    factory.last.receive(sessionsFrame());
    await pumpEventQueue();

    expect(framesOfType(factory.last, 'subscribe'), isEmpty);
    expect(framesOfType(factory.last, 'history-request'), isEmpty);
  });

  test('a 4008 rate-limited close waits the fixed longer span', () async {
    await client.start('127.0.0.1');
    await pumpEventQueue();
    scheduler.flushNotifications();
    scheduler.clear();

    factory.last.remoteClose(4008);
    await pumpEventQueue();

    expect(scheduler.reconnectDelays.single, rateLimitedReconnectDelay);
    expect(rateLimitedReconnectDelay, const Duration(milliseconds: 30000));
    expect(client.state.status, HubConnectionStatus.connecting);
    // A deliberate 30s backoff must not look like a generic reconnect loop.
    expect(client.state.lastError, contains('rate'));
  });

  test('a socket that closes before authenticating surfaces an error', () async {
    await client.start('127.0.0.1', ticket: 'ABCD2345');
    await pumpEventQueue();

    // The hub rejects a bad ticket by closing without a `paired`; the watchdog
    // is cancelled by the close, so without this the client would spin forever.
    factory.last.remoteClose(1001);
    await pumpEventQueue();

    expect(client.state.lastError, isNotNull);
  });

  test('a successful connect clears the previous dial failure', () async {
    // The hub was down; the dial failed and recorded a connection error. The
    // next dial succeeds and authenticates. That stale error must clear, or the
    // banner lies about a demonstrably healthy session.
    factory.onDial = () => Exception('connection refused');
    await client.start('127.0.0.1');
    await pumpEventQueue();
    expect(client.state.lastError, contains('refused'));

    factory.onDial = null;
    await reconnect();
    factory.last.receive(sessionsFrame());
    await pumpEventQueue();

    expect(client.state.status, HubConnectionStatus.connected);
    expect(client.state.lastError, isNull);
  });

  test('a session-scoped notice survives a reconnect', () async {
    // "the session is gone" describes something a reconnect does not fix, so
    // the fix for the stale dial error must not clear it as collateral.
    await client.start('127.0.0.1');
    await pumpEventQueue();
    factory.last.receive(sessionsFrame());
    await pumpEventQueue();
    client.subscribe('s1');

    const gone = {
      'protocolVersion': 1,
      'type': 'session-gone',
      'sessionId': 's1',
    };
    const sessionsWithoutS1 = {
      'protocolVersion': 1,
      'type': 'sessions',
      'sessions': <Object?>[],
    };
    final socket = factory.last;
    for (var i = 0; i < HubClient.maxConsecutiveSessionGone; i++) {
      socket.receive(gone);
      await pumpEventQueue();
      socket.receive(sessionsWithoutS1);
      await pumpEventQueue();
    }
    socket.receive(gone);
    await pumpEventQueue();
    expect(client.state.lastError, contains('s1'));

    socket.remoteClose(1001);
    await pumpEventQueue();
    await reconnect();
    factory.last.receive(sessionsFrame());
    await pumpEventQueue();

    expect(client.state.status, HubConnectionStatus.connected);
    expect(
      client.state.lastError,
      contains('s1'),
      reason: 'a reconnect does not make a genuinely gone session exist',
    );
  });
}
