/// The production [TokenStore], backed by Android secure storage.
///
/// This is the only client file that imports a Flutter plugin. The pure client
/// depends on the [TokenStore] interface only, so it (and its unit tests) stay
/// Flutter-free; this implementation is injected at the composition root.
///
/// Two keys: the pairing token and the remembered endpoint.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'endpoint_store.dart';
import 'token_store.dart';

class SecureTokenStore implements TokenStore {
  SecureTokenStore({
    FlutterSecureStorage? storage,
    this.key = defaultKey,
    this.endpointKey = defaultEndpointKey,
  }) : _storage = storage ?? const FlutterSecureStorage();

  /// The token key. Stable across app versions so a stored token survives an
  /// upgrade rather than silently re-pairing.
  static const String defaultKey = 'pi_droid_token';

  /// The endpoint key.
  static const String defaultEndpointKey = 'pi_droid_endpoint';

  final FlutterSecureStorage _storage;
  final String key;
  final String endpointKey;

  @override
  Future<String?> read() => _storage.read(key: key);

  @override
  Future<void> write(String token) => _storage.write(key: key, value: token);

  @override
  Future<void> clear() => _storage.delete(key: key);

  @override
  Future<HubEndpoint?> readEndpoint() async =>
      HubEndpoint.decode(await _storage.read(key: endpointKey));

  @override
  Future<void> writeEndpoint(HubEndpoint endpoint) =>
      _storage.write(key: endpointKey, value: endpoint.encode());

  @override
  Future<void> clearEndpoint() => _storage.delete(key: endpointKey);
}
