/// The production [TokenStore], backed by Android secure storage.
///
/// This is the only client file that imports a Flutter plugin. The pure client
/// depends on the [TokenStore] interface only, so it (and its unit tests) stay
/// Flutter-free; this implementation is injected at the composition root.
///
/// Four keys: the pairing token, the candidate endpoint list, the legacy single
/// endpoint and the notification policy blob.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'endpoint_store.dart';
import 'token_store.dart';

class SecureTokenStore implements TokenStore {
  SecureTokenStore({
    FlutterSecureStorage? storage,
    this.key = defaultKey,
    this.endpointsKey = defaultEndpointsKey,
    this.endpointKey = defaultEndpointKey,
    this.notifyKey = defaultNotifyKey,
  }) : _storage = storage ?? const FlutterSecureStorage();

  /// The token key. The app rename changed this literal on purpose (issue #64):
  /// the stored token is orphaned and the one installed device re-pairs, rather
  /// than carrying a migration shim forever for a single user.
  static const String defaultKey = 'pi_handset_token';

  /// The legacy single-endpoint key, in its original single-value format. It is
  /// a fallback for a torn [writeEndpoints] (the list landed, the single value
  /// did not) — not a migration path for the pre-rename key name.
  static const String defaultEndpointKey = 'pi_handset_endpoint';

  /// The candidate-list key. Newline-joined `host:port` values.
  static const String defaultEndpointsKey = 'pi_handset_endpoints';

  /// The notification policy key.
  static const String defaultNotifyKey = 'pi_handset_notify_state';

  final FlutterSecureStorage _storage;
  final String key;
  final String endpointsKey;
  final String endpointKey;
  final String notifyKey;

  @override
  Future<String?> read() => _storage.read(key: key);

  @override
  Future<void> write(String token) => _storage.write(key: key, value: token);

  @override
  Future<void> clear() => _storage.delete(key: key);

  @override
  Future<List<HubEndpoint>> readEndpoints() async {
    final stored = await _storage.read(key: endpointsKey);
    final decoded = decodeEndpoints(stored);
    if (decoded.isNotEmpty) return decoded;
    final legacy = HubEndpoint.decode(await _storage.read(key: endpointKey));
    return legacy == null ? const [] : [legacy];
  }

  @override
  Future<void> writeEndpoints(List<HubEndpoint> endpoints) async {
    await _storage.write(key: endpointsKey, value: encodeEndpoints(endpoints));
    if (endpoints.isEmpty) {
      await _storage.delete(key: endpointKey);
    } else {
      await _storage.write(key: endpointKey, value: endpoints.first.encode());
    }
  }

  @override
  Future<void> clearEndpoints() async {
    await _storage.delete(key: endpointsKey);
    await _storage.delete(key: endpointKey);
  }

  @override
  Future<String?> readNotifyState() => _storage.read(key: notifyKey);

  @override
  Future<void> writeNotifyState(String state) =>
      _storage.write(key: notifyKey, value: state);
}
