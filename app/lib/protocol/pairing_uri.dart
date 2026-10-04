/// A hand-port of `pc/src/protocol/pairing-uri.ts`'s parse half.
///
/// Pure `dart:core` only: no Flutter imports, no packages. The app only ever
/// consumes a hub-minted `pidroid://pair` URI, so this port has no formatter —
/// the shared vectors pin parse semantics only.
///
/// Grammar (pinned in `protocol/fixtures/pairing/vectors.json`):
///
///   pidroid://pair?v=1&code=ABCD2345[&port=8787][&lan=…][&ts=…]
///
/// `v` must appear exactly once and be `"1"`; anything else is
/// [pairingErrorUnsupportedVersion]. `code` is normalized through
/// [normalizeTicket]. `port` is present iff at least one address is present, and
/// each address must classify to its own param kind. Every param read takes the
/// **first** value (`queryParametersAll[...].first`), matching the PC's
/// `searchParams.get`; unknown params are ignored, and params are
/// case-sensitive, so `LAN=` is not `lan=`. `Uri.tryParse` lowercases scheme and
/// host, so `PIDROID://PAIR` parses identically on both sides.
library;

import 'ticket.dart';

/// The pairing protocol version this port understands.
const int pairingProtocolVersion = 1;

/// The literal error strings a rejected URI reports.
const String pairingErrorNotAUri = 'not-a-pairing-uri';
const String pairingErrorUnsupportedVersion = 'unsupported-version';
const String pairingErrorInvalid = 'invalid-pairing-uri';

/// The two address families a pairing URI may carry: a private LAN address or a
/// Tailscale/CGNAT (`100.64/10`) address.
enum PairingAddressKind { lan, ts }

/// One address from a pairing URI, in its param-declared kind.
class PairingAddress {
  const PairingAddress({required this.kind, required this.host});

  final PairingAddressKind kind;
  final String host;
}

/// A successfully parsed pairing URI.
class PairingPayload {
  const PairingPayload({
    required this.code,
    required this.viewerPort,
    required this.addresses,
  });

  /// Canonical 8-character ticket, no dash.
  final String code;

  /// The viewer port, or null when there are no addresses.
  final int? viewerPort;

  /// LAN addresses first, then Tailscale, each group host-sorted.
  final List<PairingAddress> addresses;
}

/// The result of [parsePairingUri]: either [PairingOk] or [PairingFailure].
sealed class PairingParseResult {
  const PairingParseResult();
}

final class PairingOk extends PairingParseResult {
  const PairingOk(this.pairing);

  final PairingPayload pairing;
}

final class PairingFailure extends PairingParseResult {
  const PairingFailure(this.error);

  final String error;
}

/// A canonical decimal octet: `0`, or `[1-9]` followed by at most two digits.
final RegExp _octet = RegExp(r'^(?:0|[1-9][0-9]{0,2})$');

/// A canonical decimal port: no leading zeros, at most five digits.
final RegExp _port = RegExp(r'^[1-9][0-9]{0,4}$');

/// The four octets of a canonical IPv4 literal, or null.
///
/// Strict dotted-quad: exactly four decimal octets, each `0` or
/// `[1-9][0-9]{0,2}` and ≤255 — leading zeros are refused, matching Node's
/// `net.isIPv4`.
List<int>? _ipv4Octets(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final octets = <int>[];
  for (final part in parts) {
    if (!_octet.hasMatch(part)) return null;
    final value = int.parse(part);
    if (value > 255) return null;
    octets.add(value);
  }
  return octets;
}

/// Classifies an IPv4 literal as LAN, Tailscale/CGNAT, or neither (null).
PairingAddressKind? classifyAddress(String host) {
  final octets = _ipv4Octets(host);
  if (octets == null) return null;
  final [a, b, _, _] = octets;
  if (a == 10) return PairingAddressKind.lan;
  if (a == 172 && b >= 16 && b <= 31) return PairingAddressKind.lan;
  if (a == 192 && b == 168) return PairingAddressKind.lan;
  if (a == 100 && b >= 64 && b <= 127) return PairingAddressKind.ts;
  return null;
}

int? _parsePort(String? raw) {
  if (raw == null || !_port.hasMatch(raw)) return null;
  final port = int.parse(raw);
  return port >= 1 && port <= 65535 ? port : null;
}

/// Order-independent canonical ordering: LAN before TS, then by host.
int _compareAddresses(PairingAddress a, PairingAddress b) {
  if (a.kind != b.kind) {
    return a.kind == PairingAddressKind.lan ? -1 : 1;
  }
  return a.host.compareTo(b.host);
}

/// Parses a `pidroid://pair` URI, never throwing.
PairingParseResult parsePairingUri(String raw) {
  final url = Uri.tryParse(raw);
  if (url == null) return const PairingFailure(pairingErrorNotAUri);
  if (url.scheme != 'pidroid' || url.host != 'pair') {
    return const PairingFailure(pairingErrorNotAUri);
  }

  final versions = url.queryParametersAll['v'];
  if (versions == null ||
      versions.length != 1 ||
      versions.first != '$pairingProtocolVersion') {
    return const PairingFailure(pairingErrorUnsupportedVersion);
  }

  final code = normalizeTicket(url.queryParametersAll['code']?.first);
  if (code == null) return const PairingFailure(pairingErrorInvalid);

  final addresses = <PairingAddress>[];
  for (final host in url.queryParametersAll['lan'] ?? const <String>[]) {
    if (classifyAddress(host) != PairingAddressKind.lan) {
      return const PairingFailure(pairingErrorInvalid);
    }
    addresses.add(PairingAddress(kind: PairingAddressKind.lan, host: host));
  }
  for (final host in url.queryParametersAll['ts'] ?? const <String>[]) {
    if (classifyAddress(host) != PairingAddressKind.ts) {
      return const PairingFailure(pairingErrorInvalid);
    }
    addresses.add(PairingAddress(kind: PairingAddressKind.ts, host: host));
  }
  addresses.sort(_compareAddresses);

  if (addresses.isEmpty) {
    if (url.queryParametersAll.containsKey('port')) {
      return const PairingFailure(pairingErrorInvalid);
    }
    return PairingOk(
      PairingPayload(code: code, viewerPort: null, addresses: addresses),
    );
  }

  final viewerPort = _parsePort(url.queryParametersAll['port']?.first);
  if (viewerPort == null) return const PairingFailure(pairingErrorInvalid);
  return PairingOk(
    PairingPayload(code: code, viewerPort: viewerPort, addresses: addresses),
  );
}
