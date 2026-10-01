/// The pure notification rules: whether a settle should notify, what its body
/// says, and the stable per-session notification id.
///
/// Deliberately Flutter-free, so it is unit-testable without a binding and
/// lives beside the rest of the client's pure logic.
///
/// ## Two caps, one ordering
///
/// The bridge caps the snippet at 200 code points
/// (`SETTLED_TEXT_MAX_CODE_POINTS` in `pc/extensions/pi-droid-bridge.ts`) and
/// flags `truncated`; this file caps the visible body at
/// [notificationBodyMaxCodePoints] (140). **The wire cap must stay ≥ the visible
/// cap**: a body shorter than the visible cap can still be marked `truncated`,
/// but a visible cap above the wire cap would show text the wire never carried.
library;

/// Whether the app is in front of the user.
///
/// `foreground` covers `resumed` and `inactive` (the notification shade, a
/// split-screen or foldable transition); `paused`/`hidden`/`detached` are
/// [background].
enum AppPresence { foreground, background }

/// The body shown when the turn produced no assistant text.
const String notificationFallbackBody = 'No reply';

/// The visible body cap in Unicode code points. Must stay ≤ the bridge's wire
/// cap (200); see the library comment.
const int notificationBodyMaxCodePoints = 140;

/// Whether a settle for [sessionId] should raise a notification.
///
/// Suppressed only when the app is foregrounded on that same session; a
/// foregrounded app showing the session list ([activeSessionId] null) still
/// notifies.
bool shouldNotifyOnSettle(
  AppPresence presence,
  String? activeSessionId,
  String sessionId,
) {
  if (presence != AppPresence.foreground) return true;
  if (activeSessionId == null) return true;
  return activeSessionId != sessionId;
}

/// The notification body for [text]: whitespace collapsed, trimmed, the
/// fallback when empty, and capped at [maxLength] code points. An ellipsis is
/// appended when this function cut the text **or** the bridge already did
/// ([truncated]).
String notificationBody(
  String text, {
  bool truncated = false,
  int maxLength = notificationBodyMaxCodePoints,
}) {
  final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.isEmpty) return notificationFallbackBody;
  final points = collapsed.runes.toList();
  if (points.length <= maxLength) {
    return truncated ? '$collapsed…' : collapsed;
  }
  return '${String.fromCharCodes(points.take(maxLength))}…';
}

/// A deterministic notification id for [sessionId], in the range 1000..1000999.
///
/// The offset keeps it clear of the foreground service's persistent
/// notification (id 1), so a settle can never replace — or be replaced by — the
/// service banner. Repeats for one session reuse the id, so the shade entry is
/// replaced rather than stacked.
int notificationIdForSession(String sessionId) {
  var hash = 0;
  for (final unit in sessionId.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return 1000 + hash % 1000000;
}
