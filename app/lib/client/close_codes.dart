/// The public close-code and reconnect-delay constants the connection uses.
///
/// Extracted from `hub_client.dart` so `hub_connection.dart` can import them
/// without a part directive; re-exported from `hub_client.dart` so every
/// existing importer keeps resolving them.
library;

/// The close code the hub sends for a capability violation. Retrying a bridge
/// bug at capped backoff would reconnect forever, so this one never reconnects.
const int closeCapability = 4003;

/// The close code the hub sends when the credential attempt cap is reached.
const int closeRateLimited = 4008;

/// The fixed wait after a `4008` close. The hub delayed that close on purpose;
/// retrying sooner would only add load.
const Duration rateLimitedReconnectDelay = Duration(milliseconds: 30000);
