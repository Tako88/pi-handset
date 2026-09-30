// Pairing: a ticket is exchanged once for the permanent token, and the token is
// persisted so a restart never re-pairs. The persistence seam is faked here; the
// platform-backed store is exercised as a compile-level dependency test later.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/hub_client.dart';
import 'package:pi_droid/client/token_store.dart';

import 'support/fakes.dart';

const String testToken =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Map<String, Object?> firstFrame(FakeHubSocket socket) =>
    (jsonDecode(socket.sent.first) as Map).cast<String, Object?>();

void main() {
  late FakeSocketFactory factory;
  late FakeScheduler scheduler;
  late InMemoryTokenStore store;
  late HubClient client;

  HubClient makeClient(TokenStore tokenStore) => HubClient(
    socketFactory: factory.call,
    scheduler: scheduler,
    tokenStore: tokenStore,
    rng: () => 0.5,
  );

  setUp(() {
    factory = FakeSocketFactory();
    scheduler = FakeScheduler();
    store = InMemoryTokenStore();
    client = makeClient(store);
  });

  test('a ticket pairs and the returned token is persisted', () async {
    await client.start('127.0.0.1', ticket: 'ABCD2345');

    final hello = firstFrame(factory.last);
    expect(hello['type'], 'hello');
    expect(hello['ticket'], 'ABCD2345');
    expect(hello.containsKey('token'), isFalse);
    expect(client.state.status, HubConnectionStatus.authenticating);

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'paired',
      'token': testToken,
    });
    await pumpEventQueue();

    expect(client.state.status, HubConnectionStatus.connected);
    expect(await store.read(), testToken);
  });

  test('connected is reported only after the token is persisted', () async {
    final gated = GatedTokenStore();
    client = makeClient(gated);
    await client.start('127.0.0.1', ticket: 'ABCD2345');

    factory.last.receive({
      'protocolVersion': 1,
      'type': 'paired',
      'token': testToken,
    });
    await pumpEventQueue();

    // The store's write is still blocked: reporting connected now would let a
    // kill in this window lose the token and re-pair.
    expect(client.state.status, HubConnectionStatus.authenticating);
    expect(await gated.read(), isNull);

    gated.gate.complete();
    await pumpEventQueue();

    expect(client.state.status, HubConnectionStatus.connected);
    expect(await gated.read(), testToken);
  });

  test('a reconnect after pairing authenticates with the token, not the ticket', () async {
    await client.start('127.0.0.1', ticket: 'ABCD2345');
    factory.last.receive({
      'protocolVersion': 1,
      'type': 'paired',
      'token': testToken,
    });
    await pumpEventQueue();

    factory.last.remoteClose(1001);
    await pumpEventQueue();
    scheduler.reconnectTimers.last.fire();
    await pumpEventQueue();

    final hello = firstFrame(factory.last);
    expect(hello['type'], 'hello');
    expect(hello['token'], testToken);
    expect(hello.containsKey('ticket'), isFalse);
  });

  test(
    'a later run with a stored token skips pairing and sends the token',
    () async {
      client = makeClient(InMemoryTokenStore(initial: testToken));

      await client.start('127.0.0.1');

      final hello = firstFrame(factory.last);
      expect(hello['token'], testToken);
      expect(hello.containsKey('ticket'), isFalse);
    },
  );
}
