/// Owns the find-in-transcript state: the query field's controller and focus,
/// whether the search is open, the current match's id, and the memo of the last
/// match computation.
///
/// A plain object, like the shell's other `*Actions` controllers: it never
/// calls `setState` itself, it reports through [onChanged]. [reset]
/// deliberately does not report, because the shell calls it from inside its own
/// `setState`.
library;

import 'package:flutter/material.dart';

import '../client/transcript.dart';

class TranscriptSearchController {
  TranscriptSearchController({
    required this.controller,
    required this.focus,
    required this.isMounted,
    required this.onChanged,
  });

  /// The query field's text.
  final TextEditingController controller;

  /// The query field's focus, held so opening the search can focus it.
  final FocusNode focus;

  /// Whether the owning state is still mounted, guarding a post-frame focus.
  final bool Function() isMounted;

  /// Notifies the owner that the search state changed and it must rebuild.
  final void Function() onChanged;

  /// Whether the find-in-transcript query field is open.
  bool open = false;

  /// The id of the current match, or null. Tracked by id (not index) so a
  /// prepend or append keeps the current row; an id that disappears falls back
  /// to the first match.
  String? currentId;

  /// The memoised matches for [_matchesQuery]/[_blocksForMatches].
  List<TranscriptBlock> _matches = const [];

  /// The **blocks list** [_matches] was computed from - not the matches. The
  /// identity check against this is what keeps streaming frames (whose
  /// `blocks` identity is stable) from re-scanning the transcript.
  List<TranscriptBlock>? _blocksForMatches;

  /// The query [_matches] was computed for, so a rebuild with an unchanged
  /// query and blocks reuses the list.
  String _matchesQuery = '';

  /// The matches for [blocks], memoised so a streaming frame (which keeps the
  /// same `blocks` identity) does not re-scan the transcript. Closed means no
  /// matches.
  List<TranscriptBlock> matchesFor(List<TranscriptBlock> blocks) {
    if (!open) return const [];
    if (controller.text == _matchesQuery &&
        identical(blocks, _blocksForMatches)) {
      return _matches;
    }
    final matches = blocksMatching(blocks, controller.text);
    _matches = matches;
    _blocksForMatches = blocks;
    _matchesQuery = controller.text;
    return matches;
  }

  /// The current match's index in [matches], falling back to the first when the
  /// tracked id is gone (a prepend/append that dropped it), or -1 when empty.
  int currentIndex(List<TranscriptBlock> matches) {
    if (matches.isEmpty) return -1;
    final index = matches.indexWhere((b) => b.id == currentId);
    return index < 0 ? 0 : index;
  }

  void openSearch() {
    controller.clear();
    open = true;
    currentId = null;
    onChanged();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isMounted()) focus.requestFocus();
    });
  }

  void closeSearch() {
    controller.clear();
    focus.unfocus();
    open = false;
    currentId = null;
    onChanged();
  }

  /// Steps the current match by [delta], wrapping around the matches.
  void step(int delta, List<TranscriptBlock> matches) {
    if (matches.isEmpty) return;
    final index = currentIndex(matches);
    final next = (index + delta + matches.length) % matches.length;
    currentId = matches[next].id;
    onChanged();
  }

  /// Re-anchors the current match to the first hit after a query edit: the
  /// exact behaviour the query field's `onChanged` had inline.
  void queryChanged() {
    currentId = null;
    onChanged();
  }

  /// Clears the search without notifying the owner: called inside the shell's
  /// own `setState` when the active session changes.
  void reset() {
    open = false;
    currentId = null;
    controller.clear();
  }

  void dispose() {
    controller.dispose();
    focus.dispose();
  }
}
