/// Removed: the endpoint is persisted by `SecureTokenStore` under its own key
/// (`pi_droid_endpoint`), so a second `flutter_secure_storage` wrapper was
/// redundant. The value type lives in `endpoint_store.dart`.
///
/// This file is intentionally empty; physical deletion is a human step (the
/// agent may not remove files — see AGENTS.md).
library;
