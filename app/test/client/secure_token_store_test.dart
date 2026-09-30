// The production token store, exercised behaviourally. `flutter_secure_storage`
// v11 talks to the native side over the MethodChannel
// `plugins.it_nomads.com/flutter_secure_storage`; intercepting that channel with
// `TestDefaultBinaryMessenger` lets these tests assert the exact key/value
// mapping and a real round trip — a mismatched key fails here, unlike the old
// compile-level test that only asserted a type and a constant.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/endpoint_store.dart';
import 'package:pi_droid/client/secure_token_store.dart';
import 'package:pi_droid/client/token_store.dart';

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
    expect(SecureTokenStore.defaultKey, 'pi_droid_token');
  });

  test('read maps the configured key onto the channel', () async {
    storage[SecureTokenStore.defaultKey] = 'stored-token';

    final value = await SecureTokenStore().read();

    expect(value, 'stored-token');
    expect(calls.single.method, 'read');
    expect((calls.single.arguments as Map)['key'], 'pi_droid_token');
  });

  test('read returns null for an unknown key', () async {
    expect(await SecureTokenStore().read(), isNull);
  });

  test('write maps the key and value, and read round-trips', () async {
    final store = SecureTokenStore();

    await store.write('round-tripped');

    expect(calls.last.method, 'write');
    expect((calls.last.arguments as Map)['key'], 'pi_droid_token');
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
    expect((calls.last.arguments as Map)['key'], 'pi_droid_token');
    expect(await store.read(), isNull);
  });

  // The endpoint is not a secret, but it lives in the same store under its own
  // key rather than in a second `flutter_secure_storage` wrapper.
  test('the endpoint round-trips under its own key', () async {
    final store = SecureTokenStore();

    await store.writeEndpoint(const HubEndpoint(host: '10.0.0.5', port: 9000));

    expect(calls.last.method, 'write');
    expect((calls.last.arguments as Map)['key'], 'pi_droid_endpoint');
    expect((calls.last.arguments as Map)['value'], '10.0.0.5:9000');
    expect(
      await store.readEndpoint(),
      const HubEndpoint(host: '10.0.0.5', port: 9000),
    );
  });

  test('readEndpoint returns null for an unknown key', () async {
    expect(await SecureTokenStore().readEndpoint(), isNull);
  });

  test('readEndpoint returns null for a stored value that does not parse', () async {
    storage[SecureTokenStore.defaultEndpointKey] = 'garbage';

    expect(await SecureTokenStore().readEndpoint(), isNull);
  });

  test('clearEndpoint deletes only the endpoint', () async {
    final store = SecureTokenStore();
    await store.write('tok');
    await store.writeEndpoint(const HubEndpoint(host: 'h', port: 1));

    await store.clearEndpoint();

    expect((calls.last.arguments as Map)['key'], 'pi_droid_endpoint');
    expect(await store.readEndpoint(), isNull);
    expect(await store.read(), 'tok');
  });
}
