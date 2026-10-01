// The context-usage readout: how full the model's window is, as used / window
// and a percentage. Pure Dart, no Flutter, so it tests without a binding.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/context_usage.dart';

void main() {
  group('formatContextUsage', () {
    test('renders used, window and percent', () {
      expect(
        formatContextUsage(
          const ContextUsage(tokens: 23400, contextWindow: 128000),
        ),
        '23k / 128k · 18%',
      );
    });

    test('renders an unknown count with a question mark', () {
      // pi reports the count as unknown right after a compaction, until the next
      // response gives it something to measure.
      expect(
        formatContextUsage(const ContextUsage(tokens: null, contextWindow: 128000)),
        '? / 128k',
      );
    });

    test('renders a zero count as a number, not as unknown', () {
      expect(
        formatContextUsage(const ContextUsage(tokens: 0, contextWindow: 128000)),
        '0 / 128k · 0%',
      );
    });

    test('renders nothing when there is no usable window', () {
      expect(
        formatContextUsage(const ContextUsage(tokens: 1, contextWindow: 0)),
        isNull,
      );
      expect(
        formatContextUsage(const ContextUsage(tokens: null, contextWindow: -1)),
        isNull,
      );
    });

    test('rounds the percentage to a whole number', () {
      // 17.6% rounds to 18; the deliberate deviation from pi's footer, which
      // prints one decimal.
      expect(
        formatContextUsage(const ContextUsage(tokens: 17600, contextWindow: 100000)),
        '18k / 100k · 18%',
      );
      expect(
        formatContextUsage(const ContextUsage(tokens: 17400, contextWindow: 100000)),
        '17k / 100k · 17%',
      );
    });

    test('reports usage above the window rather than clamping it', () {
      expect(
        formatContextUsage(const ContextUsage(tokens: 128000, contextWindow: 64000)),
        '128k / 64k · 200%',
      );
    });
  });

  group('token scaling', () {
    // Same bands pi's own footer uses, so the two readouts agree.
    test('is exact below a thousand', () {
      expect(formatTokenCount(0), '0');
      expect(formatTokenCount(999), '999');
    });

    test('uses one decimal of thousands below ten thousand', () {
      expect(formatTokenCount(1000), '1.0k');
      expect(formatTokenCount(2340), '2.3k');
      expect(formatTokenCount(9999), '10.0k');
    });

    test('rounds to whole thousands below a million', () {
      expect(formatTokenCount(10000), '10k');
      expect(formatTokenCount(23400), '23k');
      expect(formatTokenCount(999999), '1000k');
    });

    test('uses millions above that', () {
      expect(formatTokenCount(1000000), '1.0M');
      expect(formatTokenCount(2340000), '2.3M');
      expect(formatTokenCount(10000000), '10M');
    });
  });
}
