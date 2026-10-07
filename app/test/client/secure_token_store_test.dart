// The production token store, exercised behaviourally. `flutter_secure_storage`
// v11 talks to the native side over the MethodChannel
// `plugins.it_nomads.com/flutter_secure_storage`; intercepting that channel with
// `TestDefaultBinaryMessenger` lets these tests assert the exact key/value
// mapping and a real round trip — a mismatched key fails here, unlike the old
// compile-level test that only asserted a type and a constant.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/endpoint_store.dart';
import 'package:pi_handset/client/secure_token_store.dart';
import 'package:pi_handset/client/token_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final storage = <String, String>{};

  setUp(() {
    calls.clear();
    storage.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final args = (call.arguments as Map).cast<String, Object?>();
      switch (call.method) {
        case 'read':
          return storage[args['key'] as String];
        case 'write':
          storage[args['key'] as String] = args['value'] as String;
          return null;
        case 'delete':
          storage.remove(args['key'] as String);
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('the store is a TokenStore with a stable key', () {
    expect(SecureTokenStore(), isA<TokenStore>());
    expect(SecureTokenStore.defaultKey, 'pi_handset_token');
    expect(SecureTokenStore.defaultEndpointsKey, 'pi_handset_endpoints');
    expect(SecureTokenStore.defaultEndpointKey, 'pi_handset_endpoint');
  });

  test('read maps the configured key onto the channel', () async {
    storage[SecureTokenStore.defaultKey] = 'stored-token';

    final value = await SecureTokenStore().read();

    expect(value, 'stored-token');
    expect(calls.single.method, 'read');
    expect((calls.single.arguments as Map)['key'], 'pi_handset_token');
  });

  test('read returns null for an unknown key', () async {
    expect(await SecureTokenStore().read(), isNull);
  });

  test('write maps the key and value, and read round-trips', () async {
    final store = SecureTokenStore();

    await store.write('round-tripped');

    expect(calls.last.method, 'write');
    expect((calls.last.arguments as Map)['key'], 'pi_handset_token');
    expect((calls.last.arguments as Map)['value'], 'round-tripped');
    expect(await store.read(), 'round-tripped');
  });

  test('a custom key is used for both read and write', () async {
    final store = SecureTokenStore(key: 'custom-key');

    await store.write('tok');
    await store.read();

    expect(storage.keys, ['custom-key']);
    expect(calls.map((call) => (call.arguments as Map)['key']), everyElement('custom-key'));
  });

  test('clear deletes the token key', () async {
    final store = SecureTokenStore();
    await store.write('tok');

    await store.clear();

    expect(calls.last.method, 'delete');
    expect((calls.last.arguments as Map)['key'], 'pi_handset_token');
    expect(await store.read(), isNull);
  });

  // The endpoints are not secrets, but they live in the same store under their
  // own keys rather than in a second `flutter_secure_storage` wrapper. The list
  // lives under the new key; the legacy single value is kept in its original
  // format for a downgrade.
  test('writeEndpoints stores the list and the first under the legacy key', () async {
    final store = SecureTokenStore();

    await store.writeEndpoints(const [
      HubEndpoint(host: 'h1', port: 1),
      HubEndpoint(host: 'h2', port: 2),
    ]);

    expect(storage[SecureTokenStore.defaultEndpointsKey], 'h1:1\nh2:2');
    expect(storage[SecureTokenStore.defaultEndpointKey], 'h1:1');
    expect(await store.readEndpoints(), const [
      HubEndpoint(host: 'h1', port: 1),
      HubEndpoint(host: 'h2', port: 2),
    ]);
  });

  test('readEndpoints returns empty for an unknown key', () async {
    expect(await SecureTokenStore().readEndpoints(), isEmpty);
  });

  test('readEndpoints migrates a legacy single value', () async {
    storage[SecureTokenStore.defaultEndpointKey] = 'h:1';

    expect(await SecureTokenStore().readEndpoints(), const [
      HubEndpoint(host: 'h', port: 1),
    ]);
  });

  test('readEndpoints prefers the new key when both are present', () async {
    storage[SecureTokenStore.defaultEndpointsKey] = 'a:1\nb:2';
    storage[SecureTokenStore.defaultEndpointKey] = 'legacy:9';

    expect(await SecureTokenStore().readEndpoints(), const [
      HubEndpoint(host: 'a', port: 1),
      HubEndpoint(host: 'b', port: 2),
    ]);
  });

  test('writeEndpoints with an empty list clears the legacy key too', () async {
    final store = SecureTokenStore();
    await store.writeEndpoints(const [HubEndpoint(host: 'h', port: 1)]);
    expect(storage[SecureTokenStore.defaultEndpointKey], 'h:1');

    await store.writeEndpoints(const []);

    expect(await store.readEndpoints(), isEmpty);
    expect(storage.containsKey(SecureTokenStore.defaultEndpointKey), isFalse);
  });

  test('readEndpoints falls back to the legacy value when the new key is corrupt', () async {
    storage[SecureTokenStore.defaultEndpointsKey] = 'garbage';
    storage[SecureTokenStore.defaultEndpointKey] = 'h:1';

    expect(await SecureTokenStore().readEndpoints(), const [
      HubEndpoint(host: 'h', port: 1),
    ]);
  });

  test('clearEndpoints deletes both keys', () async {
    final store = SecureTokenStore();
    await store.write('tok');
    await store.writeEndpoints(const [HubEndpoint(host: 'h', port: 1)]);

    await store.clearEndpoints();

    expect(storage.containsKey(SecureTokenStore.defaultEndpointsKey), isFalse);
    expect(storage.containsKey(SecureTokenStore.defaultEndpointKey), isFalse);
    expect(await store.readEndpoints(), isEmpty);
    expect(await store.read(), 'tok');
  });

  // The notify policy is not a secret either, but it must survive a restart;
  // it lives under its own key in the same store.
  test('the notify state round-trips under its own key', () async {
    final store = SecureTokenStore();

    await store.writeNotifyState('blob');

    expect(calls.last.method, 'write');
    expect((calls.last.arguments as Map)['key'], 'pi_handset_notify_state');
    expect((calls.last.arguments as Map)['value'], 'blob');
    expect(await store.readNotifyState(), 'blob');
  });
}
