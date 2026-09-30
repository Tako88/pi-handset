/// The production [TokenStore], backed by Android secure storage.
///
/// This is the only client file that imports a Flutter plugin. The pure client
/// depends on the [TokenStore] interface only, so it (and its unit tests) stay
/// Flutter-free; this implementation is injected at the composition root.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'token_store.dart';

class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage, this.key = defaultKey})
    : _storage = storage ?? const FlutterSecureStorage();

  /// The storage key. Stable across app versions so a stored token survives an
  /// upgrade rather than silently re-pairing.
  static const String defaultKey = 'pi_droid_token';

  final FlutterSecureStorage _storage;
  final String key;

  @override
  Future<String?> read() => _storage.read(key: key);

  @override
  Future<void> write(String token) => _storage.write(key: key, value: token);
}
