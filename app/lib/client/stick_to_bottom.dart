/// Whether the transcript viewport is at the bottom, kept pure and Flutter-free
/// so the decision is testable without a widget binding.
///
/// The transcript is a natural-order list, so offset 0 is the *top* and the
/// bottom is `maxScrollExtent`. A viewer within [threshold] of that bottom is
/// following new content; anyone further up has scrolled away deliberately and
/// must not be yanked back by growth. The threshold absorbs sub-pixel residue
/// at a resting view.
library;

/// The distance from the bottom that still counts as "at the bottom".
const double atBottomThreshold = 24;

/// Whether [offset] is at (or within [threshold] of) the bottom of a list whose
/// farthest reachable offset is [maxScrollExtent].
bool isAtBottom(
  double offset,
  double maxScrollExtent, {
  double threshold = atBottomThreshold,
}) => maxScrollExtent - offset <= threshold;
