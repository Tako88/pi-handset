/// The persistence seam for the pairing token and the remembered endpoint.
///
/// The pure client only depends on this interface. The platform-backed store
/// (`secure_token_store.dart`) imports `flutter_secure_storage`; tests use an
/// in-memory double from `test/client/support/`. Keeping the interface here, and
/// the plugin behind it, is what lets the client stay Flutter-free, and keeps a
/// test double out of the shipped tree.
///
/// One store, three keys: the token (`pi_droid_token`), the endpoint
/// (`pi_droid_endpoint`) and the notify policy (`pi_droid_notify_state`). The
/// latter two are not secrets, but folding them in avoids a second plugin
/// wrapper for values that are a host:port string and a JSON blob.
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

  /// The persisted notification policy blob, or null when nothing has been
  /// stored. Not a secret; it is the escape hatch that keeps the per-session
  /// engaged/muted flags across a restart.
  Future<String?> readNotifyState();
  Future<void> writeNotifyState(String state);
}
