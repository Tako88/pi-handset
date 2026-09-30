// Reconnect policy: capped jittered backoff, reset on a successful connect,
// no reconnect on a `4003` capability close, a longer fixed wait on `4008`.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';

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
}
