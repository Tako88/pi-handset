/// A hand-port of `pc/src/hub/pairing.ts`'s ticket normalization.
///
/// Pure: `dart:core` only. The shared vectors in
/// `protocol/fixtures/tickets/vectors.json` are asserted against both this and
/// the TypeScript original, so the two cannot drift silently.
library;

/// Digits plus A-Z minus the ambiguous `I`, `L`, `O`, `U`. Exactly 32 characters.
const String ticketAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// The number of characters in a normalized ticket.
const int ticketLength = 8;

final RegExp _separators = RegExp(r'[-\s]');

/// Code points where JS `String.prototype.toUpperCase` performs a full case
/// mapping that Dart's does not (`ß` -> `SS`, ligatures -> two letters).
///
/// All eight are pinned with an exact accept/reject vector in
/// `protocol/fixtures/tickets/vectors.json`, asserted against BOTH this port
/// and the JS original — the vectors, not this comment, are the oracle. The
/// full-BMP scan that derived the list was a one-off and is deliberately not
/// committed; `U+0149` -> `ʼN` is a ninth divergence that is pinned as a reject
/// because `ʼ` is outside the alphabet.
///
/// ponytail: a fixed eight-entry map. Ceiling: a divergence introduced by a
/// different Unicode version or outside the scanned range is not handled. Add a
/// vector, re-run the scan if needed, and extend the map when one appears.
final RegExp _jsFullCaseUpper = RegExp(r'[\u00df\ufb00-\ufb06]');
const Map<String, String> _jsFullCaseUpperMap = {
  '\u00df': 'SS',
  '\ufb00': 'FF',
  '\ufb01': 'FI',
  '\ufb02': 'FL',
  '\ufb03': 'FFI',
  '\ufb04': 'FFL',
  '\ufb05': 'ST',
  '\ufb06': 'ST',
};

String _jsUpperCase(String value) => value
    .replaceAllMapped(_jsFullCaseUpper, (match) => _jsFullCaseUpperMap[match[0]!]!)
    .toUpperCase();

/// Uppercases, strips dashes and whitespace, then **rejects** (never maps) any
/// character outside [ticketAlphabet]. Returns the 8-character form, or null.
String? normalizeTicket(Object? raw) {
  if (raw is! String) return null;
  final compact = _jsUpperCase(raw.replaceAll(_separators, ''));
  if (compact.length != ticketLength) return null;
  for (final rune in compact.runes) {
    if (!ticketAlphabet.contains(String.fromCharCode(rune))) return null;
  }
  return compact;
}

/// Groups a normalized 8-character ticket as `XXXX-XXXX` for display, matching
/// what the hub prints. A value that is not exactly [ticketLength] characters is
/// returned unchanged; callers only ever pass a normalized ticket.
String formatTicketDisplay(String code) => code.length == ticketLength
    ? '${code.substring(0, 4)}-${code.substring(4)}'
    : code;
