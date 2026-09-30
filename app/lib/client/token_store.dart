/// The persistence seam for the pairing token and the remembered endpoint.
///
/// The pure client only depends on this interface. The platform-backed store
/// (`secure_token_store.dart`) imports `flutter_secure_storage`; tests use an
/// in-memory double from `test/client/support/`. Keeping the interface here, and
/// the plugin behind it, is what lets the client stay Flutter-free, and keeps a
/// test double out of the shipped tree.
///
/// One store, two keys: the token (`pi_droid_token`) and the endpoint
/// (`pi_droid_endpoint`). The endpoint is not a secret, but folding it in avoids
/// a second plugin wrapper for a value that is a host:port string.
library;

import 'endpoint_store.dart';

abstract class TokenStore {
  Future<String?> read();
  Future<void> write(String token);

  /// Removes the token. Used when the user changes hubs — the old hub's token
  /// must never be offered to a new one.
  Future<void> clear();

  Future<HubEndpoint?> readEndpoint();
  Future<void> writeEndpoint(HubEndpoint endpoint);
  Future<void> clearEndpoint();
}
