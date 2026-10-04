/// The persistence seam for the pairing token and the remembered endpoint.
///
/// The pure client only depends on this interface. The platform-backed store
/// (`secure_token_store.dart`) imports `flutter_secure_storage`; tests use an
/// in-memory double from `test/client/support/`. Keeping the interface here, and
/// the plugin behind it, is what lets the client stay Flutter-free, and keeps a
/// test double out of the shipped tree.
///
/// One store, four keys: the token (`pi_droid_token`), the candidate endpoint
/// list (`pi_droid_endpoints`), the legacy single endpoint
/// (`pi_droid_endpoint`) and the notify policy (`pi_droid_notify_state`). The
/// latter three are not secrets, but folding them in avoids a second plugin
/// wrapper for values that are an address list and a JSON blob.
library;

import 'endpoint_store.dart';

abstract class TokenStore {
  Future<String?> read();
  Future<void> write(String token);

  /// Removes the token. Used when the user changes hubs — the old hub's token
  /// must never be offered to a new one.
  Future<void> clear();

  /// The remembered candidate addresses, empty when none are stored. The list
  /// is newline-joined under `pi_droid_endpoints`; a legacy single value under
  /// `pi_droid_endpoint` is read back as a one-element list for migration.
  Future<List<HubEndpoint>> readEndpoints();

  /// Persists the candidate list and keeps the first candidate under the legacy
  /// single-value key.
  Future<void> writeEndpoints(List<HubEndpoint> endpoints);

  /// Removes both the list and the legacy single value.
  Future<void> clearEndpoints();

  /// The persisted notification policy blob, or null when nothing has been
  /// stored. Not a secret; it is the escape hatch that keeps the per-session
  /// engaged/muted flags across a restart.
  Future<String?> readNotifyState();
  Future<void> writeNotifyState(String state);
}
