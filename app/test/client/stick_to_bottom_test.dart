// The at-bottom decision, kept pure and Flutter-free in the client so the
// threshold is testable without a widget binding. The view is a natural-order
// list, so offset 0 is the top and the bottom is maxScrollExtent.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/stick_to_bottom.dart';

void main() {
  test('maxScrollExtent is the bottom of a natural-order list', () {
    expect(isAtBottom(1000, 1000), isTrue);
  });

  test('an offset beyond the threshold above the bottom is not the bottom', () {
    expect(isAtBottom(800, 1000), isFalse);
  });

  test('the threshold boundary is inclusive', () {
    expect(
      isAtBottom(1000 - atBottomThreshold, 1000, threshold: atBottomThreshold),
      isTrue,
    );
    expect(
      isAtBottom(
        1000 - atBottomThreshold - 1,
        1000,
        threshold: atBottomThreshold,
      ),
      isFalse,
    );
  });

  test('a small residual offset still counts as the bottom', () {
    // Sub-pixel scroll residue must not flash the affordance at a resting view.
    expect(isAtBottom(999.5, 1000), isTrue);
  });

  test('content shorter than the viewport counts as the bottom', () {
    expect(isAtBottom(0, 0), isTrue);
  });
}
