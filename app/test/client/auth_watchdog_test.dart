// The auth watchdog: this client sends exactly one `hello` per connection, so a
// wrong or stale token gets silence on an open socket rather than the hub's
// three-attempt close. Without a bounded wait the client would stay
// `authenticating` forever with a null error. The clock is injected, so no test
// sleeps.

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

  test('an unauthenticated socket times out, errors and closes the socket', () async {
    expect(client.state.status, HubConnectionStatus.authenticating);
    expect(scheduler.authTimers, hasLength(1));
    expect(scheduler.authTimers.single.delay, const Duration(seconds: 10));

    scheduler.fireAuthWatchdog();
    await pumpEventQueue();

    expect(client.state.lastError, isNotNull);
    expect(factory.last.closedByClient, isTrue);
  });

  test('a rejected (wrong) token surfaces an error instead of spinning', () async {
    // The hub charges one attempt per `hello` and this client sends one, so the
    // peer is silent: only the watchdog ends the attempt.
    expect(client.state.lastError, isNull);

    scheduler.fireAuthWatchdog();
    await pumpEventQueue();

    expect(client.state.lastError, contains('auth'));
  });

  test('a timed-out attempt redials with backoff', () async {
    scheduler.fireAuthWatchdog();
    await pumpEventQueue();

    expect(scheduler.reconnectTimers, isNotEmpty);
    expect(client.state.status, HubConnectionStatus.connecting);
  });

  test('a paired push cancels the watchdog', () async {
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'paired',
      'token': testToken,
    });
    await pumpEventQueue();

    expect(client.state.status, HubConnectionStatus.connected);
    expect(scheduler.authTimers.single.cancelled, isTrue);

    scheduler.fireAuthWatchdog();
    await pumpEventQueue();

    expect(client.state.lastError, isNull);
    expect(factory.last.closedByClient, isFalse);
    expect(scheduler.reconnectTimers, isEmpty);
  });

  test('a sessions push cancels the watchdog', () async {
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'sessions',
      'sessions': [],
    });
    await pumpEventQueue();

    expect(client.state.status, HubConnectionStatus.connected);
    expect(scheduler.authTimers.single.cancelled, isTrue);

    scheduler.fireAuthWatchdog();
    await pumpEventQueue();

    expect(client.state.lastError, isNull);
    expect(factory.last.closedByClient, isFalse);
    expect(scheduler.reconnectTimers, isEmpty);
  });
}
