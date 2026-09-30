/// The persistence seam for the pairing token.
///
/// The pure client only depends on this interface. The platform-backed store
/// (`secure_token_store.dart`) imports `flutter_secure_storage`; tests use an
/// in-memory double from `test/client/support/`. Keeping the interface here, and
/// the plugin behind it, is what lets the client stay Flutter-free, and keeps a
/// test double out of the shipped tree.
library;

abstract class TokenStore {
  Future<String?> read();
  Future<void> write(String token);
}
