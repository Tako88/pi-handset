/// The remembered hub endpoint value type.
///
/// Persistence is not owned here: `SecureTokenStore` keeps the endpoint under
/// its own key (one store, four keys) — the address is not a secret, but it does
/// not deserve a second `flutter_secure_storage` wrapper.
library;

import '../protocol/pairing_uri.dart';

/// A host and port the app has paired with.
class HubEndpoint {
  final String host;
  final int port;

  const HubEndpoint({required this.host, required this.port});

  /// `host:port`. IPv6 literals are not supported; the hub is dialed by a LAN
  /// address or hostname.
  String encode() => '$host:$port';

  /// Parses [raw] back to an endpoint, or null when it does not parse.
  static HubEndpoint? decode(String? raw) {
    if (raw == null) return null;
    final separator = raw.lastIndexOf(':');
    if (separator <= 0) return null;
    final host = raw.substring(0, separator);
    final port = int.tryParse(raw.substring(separator + 1));
    if (port == null || port < 1 || port > 65535) return null;
    return HubEndpoint(host: host, port: port);
  }

  @override
  bool operator ==(Object other) =>
      other is HubEndpoint && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => encode();
}

/// Encodes [endpoints] as a newline-joined list of `host:port` values.
String encodeEndpoints(List<HubEndpoint> endpoints) =>
    endpoints.map((endpoint) => endpoint.encode()).join('\n');

/// Decodes a newline-joined list, skipping any line that does not parse.
///
/// Returns empty for null/empty input, so a missing or corrupt store reads as
/// "nothing stored" rather than throwing.
List<HubEndpoint> decodeEndpoints(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  return raw
      .split('\n')
      .map(HubEndpoint.decode)
      .whereType<HubEndpoint>()
      .toList(growable: false);
}

/// A human label for a stored candidate [host].
///
/// Kind is re-derived from the host by the shared classifier, not stored — the
/// ranges must stay identical to `pairing_uri.dart`'s.
String candidateLabel(String host) => switch (classifyAddress(host)) {
  PairingAddressKind.lan => 'Home network',
  PairingAddressKind.ts => 'Tailscale',
  null => host,
};
