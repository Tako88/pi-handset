/// How full the model's context window is, and how to render it.
///
/// Pure Dart: no Flutter import, so it tests without a binding. The numbers come
/// from pi through the `usage` event payload; the percentage is derived here
/// rather than sent, because it is exactly `tokens / contextWindow` and a second
/// source of truth for it would be one too many.
library;

/// One context-usage reading.
class ContextUsage {
  /// Estimated tokens currently in context, or null when pi cannot say — which
  /// is the state right after a compaction, until the next response lands.
  final int? tokens;

  /// The model's window, in tokens. Zero means "no usable window", and the
  /// readout is then not rendered at all.
  final int contextWindow;

  const ContextUsage({required this.tokens, required this.contextWindow});
}

/// `23k / 128k · 18%`, or `? / 128k` when the count is unknown, or null when
/// there is no usable window to report against.
String? formatContextUsage(ContextUsage usage) {
  if (usage.contextWindow <= 0) return null;
  final window = formatTokenCount(usage.contextWindow);
  final tokens = usage.tokens;
  if (tokens == null) return '? / $window';
  // Rounded to a whole number, deliberately unlike pi's footer, which prints one
  // decimal. The phone has less room and a tenth of a percent changes nothing.
  final percent = (tokens / usage.contextWindow * 100).round();
  return '${formatTokenCount(tokens)} / $window · $percent%';
}

/// Scales a token count the way pi's own footer does, so the two readouts agree
/// band for band: exact below a thousand, one decimal of thousands below ten
/// thousand, whole thousands below a million, then millions.
String formatTokenCount(int count) {
  if (count < 1000) return count.toString();
  if (count < 10000) return '${(count / 1000).toStringAsFixed(1)}k';
  if (count < 1000000) return '${(count / 1000).round()}k';
  if (count < 10000000) return '${(count / 1000000).toStringAsFixed(1)}M';
  return '${(count / 1000000).round()}M';
}
