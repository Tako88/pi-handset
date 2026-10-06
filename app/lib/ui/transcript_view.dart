/// The transcript view — the B0 mitigation made concrete.
///
/// Renders the client's derived [SessionTranscript.blocks] in order, plus the
/// single in-flight streaming row. A streaming message renders as cheap plain
/// `Text` (it is rebuilt on every coalesced frame); a completed text block
/// renders through `MarkdownBody`. Every row is wrapped in a `RepaintBoundary`
/// keyed by its stable block id, so a streamed frame repaints only the
/// streaming row, and the list is a lazy `ListView.builder` so a frame never
/// touches (or re-parses) rows that are off-screen.
///
/// **Stick-to-bottom uses a natural-order list, not `reverse: true`.** In a
/// forward list, appending at the end leaves the position of earlier content
/// untouched — a viewer who scrolled away is never moved, and growth while
/// following is handled by a post-frame jump to `maxScrollExtent`. The viewed
/// content is therefore stable, not merely the pixel offset: with a reversed
/// list a new row is inserted at the scrollable's origin and Flutter preserves
/// `pixels`, silently shifting everything the viewer sees on every frame of
/// streaming growth.
///
/// The same natural order is why a **prepend** needs correcting: inserting an
/// older page at the top preserves `pixels`, so the viewed content slides down
/// by the inserted height. The prepend is detected by entry-object identity and
/// undone with a post-frame jump — never a follow-jump — so loading a page does
/// not move the content being read. The correction is approximate: it measures
/// the inserted height as the `maxScrollExtent` delta, which `ListView.builder`
/// estimates and which under-measures when the pre-prepend content fitted the
/// viewport (that case is skipped rather than guessed).
///
/// Presentational: block derivation happens in the client, not here, so a
/// stream delta never re-walks the transcript.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../client/hub_models.dart';
import '../client/stick_to_bottom.dart';
import '../client/transcript.dart';
import 'transcript_blocks.dart';
import 'theme.dart';

/// Puts [text] on the system clipboard. Injectable so a widget test can
/// assert the copy wiring without a platform channel (as `onOpenLink` is).
Future<void> copyToClipboard(String text) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
  } catch (_) {
    // Nothing the viewer can do; same policy as openExternalLink.
  }
}

class TranscriptView extends StatefulWidget {
  const TranscriptView({
    super.key,
    required this.transcript,
    required this.onLoadOlder,
    this.search = TranscriptSearch.none,
    this.onOpenLink = openExternalLink,
    this.onCopyText = copyToClipboard,
  });

  final SessionTranscript transcript;

  /// The find-in-transcript state: which rows match and which one is current.
  /// Defaults to [TranscriptSearch.none], so a view with no search tints
  /// nothing.
  final TranscriptSearch search;

  /// Loads one older page into the transcript. Required, not optional: an
  /// omitted handler would render a control that does nothing.
  final VoidCallback onLoadOlder;

  /// How a tapped link is opened, threaded to every [TextBlock]. Injectable so
  /// a widget test can assert the wiring without a platform channel.
  final Future<void> Function(Uri uri) onOpenLink;

  /// How a row's whole-message copy is delivered. Injectable so a widget test
  /// can assert the wiring without a platform channel; production writes to
  /// the system clipboard.
  final void Function(String text) onCopyText;

  /// The tint alpha for a row that matches the query. Public so the contrast
  /// test pins the same number the widget paints.
  static const double hitHighlightAlpha = 0.22;

  /// The tint alpha for the current match — deliberately stronger than
  /// [hitHighlightAlpha], so the row the stepper is on reads differently.
  static const double currentHitHighlightAlpha = 0.40;

  /// The toolbar item that copies the whole row, as opposed to the system's
  /// own Copy, which copies only the selected substring.
  static const String copyMessageLabel = 'Copy message';

  static const String emptyMessage = 'No messages yet.';

  /// Shown above the oldest row a truncated history kept. The window is a
  /// suffix, so the cut is at the *top*; without this the transcript looks like
  /// the session simply began at that message.
  static const String truncatedNotice =
      'Older messages are not loaded — this session is longer than the history limit.';

  /// The streaming row's key. Stable across frames so its element and repaint
  /// boundary are reused while deltas accumulate.
  static const Key streamingKey = ValueKey('transcript-streaming');

  /// The load-older control's key, present only while the transcript has an
  /// [SessionTranscript.olderCursor] to resume from.
  static const Key loadOlderKey = ValueKey('history-load-older');

  /// The load-older control's idle label.
  static const String loadOlderLabel = 'Load older messages';

  /// The load-older control's label while a page is in flight.
  static const String loadingOlderLabel = 'Loading older messages…';

  /// The live reasoning row's key. It exists only while the reasoning streams,
  /// and is replaced by the committed thinking block when the message lands.
  static const Key liveThinkingKey = ValueKey('transcript-live-thinking');

  /// How many blocks the list builds when a session opens. Derived from the
  /// device measurement in the brief: a 149k-token open built ~440 text rows in
  /// one 117.5 ms frame, so a text row costs ~0.27 ms; 30 rows ≈ 8 ms, inside a
  /// 16.7 ms frame with ~2× headroom (it takes >0.55 ms/row to breach it).
  ///
  /// The caveat is load-bearing: that cost is text rows on one AVD run only. An
  /// image or tool-diff row is taller and costlier, so a window of tall rows can
  /// still breach a frame (measured check 1 in the plan).
  static const int windowBlocks = 30;

  /// How many blocks the window reveals per growth step. The same 30, so a
  /// reveal frame lays out ~chunk + viewport rows ≈ 45 rows ≈ 12 ms, bounded
  /// the same way as [windowBlocks].
  static const int windowChunk = 30;

  /// How close to the top (in pixels) the list must be scrolled before a growth
  /// step is scheduled. Kept comfortably above the scroll slop.
  static const double windowGrowThreshold = 200;

  @override
  State<TranscriptView> createState() => _TranscriptViewState();
}

class _TranscriptViewState extends State<TranscriptView> {
  final ScrollController _controller = ScrollController();

  /// How many extra frames a settling jump may take before giving up. A
  /// variable-height transcript exposes a truer `maxScrollExtent` on each frame
  /// (the first is an estimate from the rows built so far), so one jump lands
  /// short; re-jumping converges. The cap stops a pathological list spinning
  /// forever.
  static const int _maxJumpAttempts = 10;

  /// Frames one reveal may probe before giving up. The bisection normally
  /// converges in O(log extent) frames (≈15 for a 30k-px transcript), but this
  /// bound is genuinely reachable: a stalled or oscillating bracket, or repeated
  /// no-measurement frames, can spend frames without halving. Hitting it ends
  /// the seek (see [_endSeek]) rather than
  /// spinning; the row tint still marks the match if it is ever built.
  static const int _maxSeekFrames = 40;

  /// Whether the viewer is following the bottom. It is *not* recomputed from
  /// the offset after content growth (in a forward list that would read as "not
  /// at the bottom" the instant `maxScrollExtent` grew), so it must be read
  /// before the new content is laid out.
  bool _following = true;

  /// Whether the viewer was following when the search opened, so closing the
  /// search can restore it (rules R1/R2). Following is paused while the search
  /// is open: a stream append must not yank the view off the current match.
  bool _searchWasFollowing = true;

  /// A [GlobalKey] per committed row, so a reveal can measure and scroll to a
  /// row that is outside the built window. Bounded by the loaded block count
  /// and dropped with this per-session [State].
  final Map<String, GlobalKey> _rowKeys = {};

  GlobalKey _rowKey(String id) => _rowKeys.putIfAbsent(id, () => GlobalKey());

  String? _seekId; // the match this seek belongs to
  double? _seekLow; // an offset known to be before the target row
  double? _seekHigh; // an offset known to be at or past the target row
  int _seekFrames = 0; // total frames this seek has probed

  /// The id of the tool row whose body is expanded, or null when every tool row
  /// is collapsed. There is exactly one: the derivation below owns it while a
  /// turn runs, and a tap replaces it.
  String? _expandedToolId;

  /// The last id the derivation selected, tracked apart from [_expandedToolId]
  /// so a rebuild that derives the same current tool does not stomp a manual
  /// tap.
  String? _lastDerivedToolId;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    _adoptDerived(_currentToolId(widget.transcript));
    // R3: an already-open search starts paused, not following.
    if (widget.search.open) {
      _searchWasFollowing = _following;
      _following = false;
    }
    final matchId = widget.search.currentMatch?.id;
    if (matchId != null) {
      // The search is already open with a current match: reveal it rather than
      // opening at the newest row.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _settleToMatch(matchId),
      );
    } else {
      // A tall transcript must open at its newest row, not its oldest.
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(TranscriptView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // R1/R2: snapshot following when the search opens and restore it when it
    // closes, *before* the prepend/follow logic below so the restored flag is
    // what drives the single follow-jump (never a second, independent jump).
    if (!oldWidget.search.open && widget.search.open) {
      _searchWasFollowing = _following;
      _following = false;
    } else if (oldWidget.search.open && !widget.search.open) {
      _following = _searchWasFollowing;
    }
    // R5: reveal only when the current match id changes (including the open
    // edge), never per frame, and never touching _following.
    final matchId = widget.search.currentMatch?.id;
    if (matchId != null && matchId != oldWidget.search.currentMatch?.id) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _settleToMatch(matchId),
      );
    }
    // Collapse what is no longer current: the in-flight call moved on, or the
    // turn settled. A no-op while the derivation is unchanged.
    _adoptDerived(_currentToolId(widget.transcript));
    // A prepend grows the list at the top. In a natural-order list `pixels` is
    // preserved, so the viewed content would slide down by the inserted height;
    // correct it in a post-frame callback, when the new extent is measurable.
    // Never follow-jump on a prepend: the content being read must not move.
    if (_isPrepend(oldWidget.transcript.entries, widget.transcript.entries)) {
      final oldOffset = _controller.hasClients ? _controller.offset : null;
      final oldMax =
          _controller.hasClients ? _controller.position.maxScrollExtent : null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_controller.hasClients) return;
        if (oldOffset == null || oldMax == null) return;
        // `maxScrollExtent` is an estimate under `ListView.builder`, and when
        // the pre-prepend content fitted the viewport (`oldMax <= 0`) the
        // viewport absorbs part of the insertion, so this delta under-measures
        // it. Skip rather than guess; the seam-loss is a documented limit.
        final inserted = _controller.position.maxScrollExtent - oldMax;
        if (oldMax <= 0 || inserted <= 0) return;
        _controller.jumpTo(oldOffset + inserted);
      });
      return;
    }
    // Read the flag *before* the change is laid out: once the list grows, a
    // follower's old offset no longer looks like the bottom.
    final wasFollowing = _following;
    if (wasFollowing) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
    }
  }

  /// The in-flight tool: while the agent runs, the LAST tool row with no result
  /// yet. Null once every call has a result, or the turn is not running — which
  /// collapses every row.
  String? _currentToolId(SessionTranscript transcript) {
    if (transcript.agentState != 'running') return null;
    for (var i = transcript.blocks.length - 1; i >= 0; i--) {
      final block = transcript.blocks[i];
      if (block.kind == TranscriptBlockKind.tool && block.toolResult == null) {
        return block.id;
      }
    }
    return null;
  }

  /// Auto-expands the derived current tool, collapsing when it changes or the
  /// turn settles. A no-op when the derivation is unchanged, so a manual tap
  /// survives rebuilds.
  void _adoptDerived(String? derived) {
    if (derived == _lastDerivedToolId) return;
    _lastDerivedToolId = derived;
    _expandedToolId = derived;
  }

  void _onScroll() {
    // R4: a user scroll during a search must not re-enable following and let
    // the next append yank the view off the current match.
    if (widget.search.open) return;
    if (!_controller.hasClients) return;
    final atBottom = isAtBottom(
      _controller.offset,
      _controller.position.maxScrollExtent,
    );
    if (atBottom != _following) setState(() => _following = atBottom);
  }

  void _jumpToBottom() => _settleToBottom(0);

  /// Jump to the bottom, then re-check after the frame has laid more of the list
  /// out. `ListView.builder` estimates `maxScrollExtent` from the rows built so
  /// far, so on a variable-height transcript the first jump targets an estimate
  /// and lands short; each further frame reveals a truer extent. Re-jump until
  /// actually at the bottom, bounded by [_maxJumpAttempts].
  void _settleToBottom(int attempt) {
    if (!mounted || !_controller.hasClients) return;
    _controller.jumpTo(_controller.position.maxScrollExtent);
    if (attempt >= _maxJumpAttempts) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      if (_following &&
          !isAtBottom(
            _controller.offset,
            _controller.position.maxScrollExtent,
          )) {
        _settleToBottom(attempt + 1);
      }
    });
  }

  /// Reveal the row [id] for the current match.
  ///
  /// The row can only be measured once built, and `ListView.builder` builds a
  /// contiguous index window around the current offset. That window is the
  /// oracle: probe the middle of the offset range, see whether the target index
  /// is above or below the window, and halve. `maxScrollExtent` is re-read every
  /// probe because it is an estimate that grows as more rows are built, and a
  /// growing estimate is what lets a *downward* search reach a target past the
  /// initial one (measured: 25511 at the top of a 30476 px list). Once the
  /// target is built, [Scrollable.ensureVisible] places it.
  ///
  /// **Stranded-state policy.** After a give-up the seek is abandoned for that
  /// match id and is not retried until the current match changes or the search
  /// is reopened; a stream append changes the transcript but not the match id,
  /// so it does not re-arm the seek. The row tint still marks the match.
  void _settleToMatch(String id) {
    if (!mounted || !_controller.hasClients) return;
    // A newer reveal superseded this one (or the search closed).
    if (widget.search.currentMatch?.id != id) {
      if (_seekId == id) _endSeek();
      return;
    }
    // Fast path: already built — unchanged from before.
    final ctx = _rowKeys[id]?.currentContext;
    if (ctx != null) {
      _endSeek();
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.3,
        duration: const Duration(milliseconds: 150),
      );
      return;
    }
    final targetIndex = _listIndexOf(id);
    if (targetIndex == null) {
      // The block this match names is gone from the transcript (a prepend or
      // replacement changed the ids). Nothing to reveal.
      _endSeek();
      return;
    }
    if (_seekId != id) {
      _seekId = id;
      _seekLow = null;
      _seekHigh = null;
      _seekFrames = 0;
    }
    if (_seekFrames >= _maxSeekFrames) {
      // Give up explicitly. _endSeek clears the seek so no later frame resumes
      // a bracket with stale bounds. It is not retried for this match id; see
      // the stranded-state policy in the class docs / known-limits.
      _endSeek();
      return;
    }
    _seekFrames++;

    final offset = _controller.offset;
    final range = _builtIndexRange();

    if (range == null) {
      // Nothing laid out to measure: aim at the proportional estimate, retry.
      final count = _itemCount();
      if (count <= 1) {
        _endSeek();
        return;
      }
      _seekJump(_controller.position.maxScrollExtent * targetIndex / (count - 1));
      return;
    }

    if (targetIndex > range.max) {
      // Target below the window: this offset is before it.
      _seekLow = _seekLow == null ? offset : (_seekLow! > offset ? _seekLow! : offset);
    } else if (targetIndex < range.min) {
      // Target above the window: this offset is at or past it.
      _seekHigh = _seekHigh == null ? offset : (_seekHigh! < offset ? _seekHigh! : offset);
    } else {
      // Inside the window but not built. Contiguity says this cannot happen; a
      // frame caught mid-teardown could still show it. Retry next frame rather
      // than strand — the frame cap is the backstop.
      _seekAgain();
      return;
    }

    var low = _seekLow ?? 0.0;
    var high = _seekHigh ?? _controller.position.maxScrollExtent;
    final max = _controller.position.maxScrollExtent;
    if (low > max) low = max;
    if (high > max) high = max;
    if (high < low) high = low;
    if (high - low < 1.0) {
      // The bracket collapsed without building the target (contradictory
      // oracle readings or a stale estimate). Give up explicitly, never strand.
      _endSeek();
      return;
    }
    _seekJump((low + high) / 2);
  }

  void _seekJump(double offset) {
    _controller.jumpTo(offset.clamp(0.0, _controller.position.maxScrollExtent));
    _seekAgain();
  }

  /// Schedule one more probe for the in-flight seek next frame.
  void _seekAgain() {
    final id = _seekId;
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      _settleToMatch(id);
    });
  }

  void _endSeek() {
    _seekId = null;
    _seekLow = null;
    _seekHigh = null;
    _seekFrames = 0;
  }

  int? _listIndexOf(String id) => transcriptListIndexOf(widget.transcript, id);

  /// The smallest and largest list indices among the committed rows currently
  /// built, or null when none is. `ListView.builder` builds a contiguous index
  /// window, so this is that window's extent.
  ({int min, int max})? _builtIndexRange() {
    final blocks = widget.transcript.blocks;
    final listOffset = widget.transcript.truncated ? 1 : 0;
    int? min;
    int? max;
    for (var i = 0; i < blocks.length; i++) {
      if (_rowKeys[blocks[i].id]?.currentContext == null) continue;
      final index = i + listOffset;
      if (min == null || index < min) min = index;
      if (max == null || index > max) max = index;
    }
    return min == null ? null : (min: min, max: max!);
  }

  /// The number of list items the builder would produce for this transcript.
  int _itemCount() {
    final t = widget.transcript;
    return t.blocks.length +
        (t.truncated ? 1 : 0) +
        (t.streamingThinking.isNotEmpty ? 1 : 0) +
        (t.streaming && t.streamingText.isNotEmpty ? 1 : 0);
  }

  Future<void> _returnToBottom() async {
    if (!_controller.hasClients) return;
    try {
      await _controller.animateTo(
        _controller.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } on Object {
      // The controller can be disposed mid-flight (e.g. a session switch),
      // which makes the awaited future complete with an error. The view is
      // gone; there is nothing left to re-pin.
      return;
    }
    if (!mounted) return;
    // Content may have grown during the animation, so the target was stale:
    // resume following and settle to the true bottom. setState so the FAB
    // disappears even when nothing else triggers a rebuild.
    setState(() => _following = true);
    _jumpToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final blocks = widget.transcript.blocks;
    final matchIds = {for (final b in widget.search.matches) b.id};
    final currentId = widget.search.currentMatch?.id;
    final truncated = widget.transcript.truncated;
    final liveThinking = widget.transcript.streamingThinking.isNotEmpty;
    final streaming =
        widget.transcript.streaming &&
        widget.transcript.streamingText.isNotEmpty;
    final itemCount =
        blocks.length +
        (truncated ? 1 : 0) +
        (liveThinking ? 1 : 0) +
        (streaming ? 1 : 0);
    if (itemCount == 0) {
      return const Center(child: Text(TranscriptView.emptyMessage));
    }
    return Stack(
      children: [
        ListView.builder(
          controller: _controller,
          // Bottom clearance so the jump-to-latest button never sits on the
          // newest (often still-streaming) row.
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 72),
          itemCount: itemCount,
          itemBuilder: (context, index) {
            if (truncated && index == 0) {
              if (widget.transcript.olderCursor != null) {
                final loading = widget.transcript.historyLoading;
                return RepaintBoundary(
                  key: TranscriptView.loadOlderKey,
                  child: TextButton(
                    onPressed: loading ? null : widget.onLoadOlder,
                    child: Text(
                      loading
                          ? TranscriptView.loadingOlderLabel
                          : TranscriptView.loadOlderLabel,
                    ),
                  ),
                );
              }
              return const RepaintBoundary(
                key: ValueKey('history-truncated'),
                child: NoticeBlock(
                  block: TranscriptBlock(
                    kind: TranscriptBlockKind.notice,
                    id: 'history-truncated',
                    text: TranscriptView.truncatedNotice,
                  ),
                ),
              );
            }
            final blockIndex = truncated ? index - 1 : index;
            if (blockIndex == blocks.length && liveThinking) {
              return RepaintBoundary(
                key: TranscriptView.liveThinkingKey,
                child: ThinkingBlock(
                  block: TranscriptBlock(
                    kind: TranscriptBlockKind.thinking,
                    id: 'live-thinking',
                    text: widget.transcript.streamingThinking,
                    complete: false,
                  ),
                  thinkingLevel: widget.transcript.thinkingLevel,
                ),
              );
            }
            if (blockIndex >= blocks.length) {
              return RepaintBoundary(
                key: TranscriptView.streamingKey,
                child: TextBlock(
                  block: TranscriptBlock(
                    kind: TranscriptBlockKind.text,
                    id: 'streaming',
                    text: widget.transcript.streamingText,
                    complete: false,
                  ),
                  onOpenLink: widget.onOpenLink,
                ),
              );
            }
            final block = blocks[blockIndex];
            // The ValueKey stays outermost: existing tests (and the
            // RepaintBoundary contract) depend on it. The GlobalKey sits inside
            // it so the reveal can measure a row without changing that key.
            return RepaintBoundary(
              key: ValueKey(block.id),
              child: KeyedSubtree(
                key: _rowKey(block.id),
                child: _selectable(
                  block,
                  _block(block, _highlightFor(block.id, matchIds, currentId)),
                ),
              ),
            );
          },
        ),
        // R4: no jump-to-latest affordance while a search owns the view.
        if (!_following && !widget.search.open)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.small(
              onPressed: _returnToBottom,
              tooltip: 'Jump to latest',
              // Quiet, not the accent: this is a convenience, not the screen's
              // one action, and it floats over the transcript while you read.
              backgroundColor: Theme.of(
                context,
              ).extension<PiRoles>()!.cardBg,
              foregroundColor: Theme.of(context).extension<PiRoles>()!.text,
              child: const Icon(Icons.arrow_downward),
            ),
          ),
      ],
    );
  }

  /// Wraps one committed row in a [SelectionArea] whose toolbar also offers
  /// the whole row. Per row, not per list: rows are lazily unmounted, and the
  /// copy item needs the row it belongs to.
  Widget _selectable(TranscriptBlock block, Widget child) {
    final text = copyTextForBlock(block);
    if (text == null || text.isEmpty) return child;
    return SelectionArea(
      contextMenuBuilder: (context, state) =>
          AdaptiveTextSelectionToolbar.buttonItems(
        anchors: state.contextMenuAnchors,
        buttonItems: [
          ...state.contextMenuButtonItems,
          ContextMenuButtonItem(
            label: TranscriptView.copyMessageLabel,
            onPressed: () {
              state.hideToolbar();
              widget.onCopyText(text);
            },
          ),
        ],
      ),
      child: child,
    );
  }

  /// The tint for the row [id]: the current match is stronger than the other
  /// hits, and a non-match has none.
  ///
  /// [matchIds] is built from the *matched blocks*, so the synthetic notice the
  /// view constructs in its own item builder is never a member and can never be
  /// tinted.
  Color? _highlightFor(String id, Set<String> matchIds, String? currentId) {
    final roles = Theme.of(context).extension<PiRoles>()!;
    if (currentId == id) {
      return roles.warning.withValues(
        alpha: TranscriptView.currentHitHighlightAlpha,
      );
    }
    if (matchIds.contains(id)) {
      return roles.warning.withValues(alpha: TranscriptView.hitHighlightAlpha);
    }
    return null;
  }

  Widget _block(TranscriptBlock block, Color? highlight) {
    switch (block.kind) {
      case TranscriptBlockKind.text:
        return TextBlock(
          block: block,
          highlight: highlight,
          onOpenLink: widget.onOpenLink,
        );
      case TranscriptBlockKind.thinking:
        return ThinkingBlock(
          block: block,
          thinkingLevel: widget.transcript.thinkingLevel,
          highlight: highlight,
        );
      case TranscriptBlockKind.tool:
        final expanded = block.id == _expandedToolId;
        return ToolBlock(
          block: block,
          expanded: expanded,
          highlight: highlight,
          onToggle: () => setState(() {
            _expandedToolId = expanded ? null : block.id;
          }),
        );
      case TranscriptBlockKind.notice:
        return NoticeBlock(block: block, highlight: highlight);
      case TranscriptBlockKind.image:
        return ImageBlock(block: block);
    }
  }
}

/// Clamps a window start to the block list's bounds. A start past the end
/// renders nothing; a negative one is the open window.
int _clampWindowStart(int windowStart, int length) {
  if (windowStart < 0) return 0;
  if (windowStart > length) return length;
  return windowStart;
}

/// The list index of [id] in [transcript]'s builder when the rendered window
/// starts at [windowStart], including the synthetic truncated-history notice
/// row only when the window reaches block 0. Returns null when [id] names no
/// block or the block sits before the window. Exposed so the search's index
/// space and the builder's can be asserted to match.
@visibleForTesting
int? transcriptListIndexOf(
  SessionTranscript transcript,
  String id, {
  int windowStart = 0,
}) {
  final blocks = transcript.blocks;
  final start = _clampWindowStart(windowStart, blocks.length);
  final blockIndex = blocks.indexWhere((b) => b.id == id);
  if (blockIndex < 0 || blockIndex < start) return null;
  return blockIndex - start + (transcript.truncated && start == 0 ? 1 : 0);
}

/// The number of list items the builder would produce for [transcript] when the
/// rendered window starts at [windowStart]. The window is **open at the
/// bottom**: it renders every block from [windowStart] to the end, so a stream
/// append is always included and only the top is bounded.
///
/// [windowStart] is clamped to `[0, blocks.length]`. The synthetic truncation
/// row is counted only when the window actually reaches block 0, matching
/// [transcriptListIndexOf] and the builder's index space.
@visibleForTesting
int transcriptItemCount(SessionTranscript transcript, {int windowStart = 0}) {
  final blocks = transcript.blocks;
  final start = _clampWindowStart(windowStart, blocks.length);
  return (blocks.length - start) +
      (transcript.truncated && start == 0 ? 1 : 0) +
      (transcript.streamingThinking.isNotEmpty ? 1 : 0) +
      (transcript.streaming && transcript.streamingText.isNotEmpty ? 1 : 0);
}

/// The window start to carry into [newBlocks] after [oldBlocks] changed.
///
/// [windowStart] was the start in [oldBlocks]. The rules keep the rendered
/// content stable where possible and fall back to the newest window only when
/// the anchor genuinely did not survive:
/// 1. a first (empty) baseline opens at the newest [size] blocks;
/// 2. a prepend re-anchors on the same block id, so the rows already on screen
///    stay on screen (and a window that already reaches block 0 stays open);
/// 3. a pure append/patch (the last old block is still present at its index)
///    keeps the start unchanged — the O(1) tail check the streaming delta path
///    depends on;
/// 4. anything else (a rebuild-shaped append that inserted rows mid-list, a
///    replaced baseline, a truncation) re-anchors on the old window's first
///    block id, so a rebuild that merely inserted rows does not throw the
///    reader back to the newest window.
///
/// Rule 3 precedes rule 4 deliberately: on a streaming delta it costs two
/// indexed reads, which is what keeps the delta test's `reads < 50` green —
/// not the `identical` fast path in the view.
@visibleForTesting
int transcriptWindowStartAfter({
  required List<TranscriptBlock> oldBlocks,
  required List<TranscriptBlock> newBlocks,
  required bool prepend,
  required int windowStart,
  int size = TranscriptView.windowBlocks,
}) {
  int newestStart() {
    final start = newBlocks.length - size;
    return start < 0 ? 0 : start;
  }

  int anchorIndex() => _clampWindowStart(windowStart, oldBlocks.length - 1);

  if (oldBlocks.isEmpty) return newestStart();

  if (prepend) {
    if (windowStart <= 0) return 0;
    final index = _indexOfId(newBlocks, oldBlocks[anchorIndex()].id);
    return index >= 0 ? index : newestStart();
  }

  if (newBlocks.length >= oldBlocks.length &&
      newBlocks[oldBlocks.length - 1].id == oldBlocks.last.id) {
    return windowStart;
  }

  final index = _indexOfId(newBlocks, oldBlocks[anchorIndex()].id);
  return index >= 0 ? index : newestStart();
}

/// The first index in [blocks] whose id is [id], or -1. By id, not identity:
/// a rebuild re-creates every block object.
int _indexOfId(List<TranscriptBlock> blocks, String id) {
  for (var i = 0; i < blocks.length; i++) {
    if (blocks[i].id == id) return i;
  }
  return -1;
}

/// Whether [now] is [old] with entries prepended: the suffix of [now] equals
/// [old] by **object identity**.
///
/// Entries, not blocks: a rebuild re-creates every `TranscriptBlock` object, and
/// block ids are not exact either — prepending an older page can legitimately
/// re-pair a straddling `toolCall`/`toolResult`, changing the suffix's ids. The
/// entry list is exact for the shapes the client produces: a prepend spreads the
/// retained element objects, an append puts them *first* (failing the suffix
/// test), and a baseline decodes fresh objects (also failing it).
bool _isPrepend(List<Object?> old, List<Object?> now) {
  if (now.length <= old.length || old.isEmpty) return false;
  final start = now.length - old.length;
  for (var i = 0; i < old.length; i++) {
    if (!identical(now[start + i], old[i])) return false;
  }
  return true;
}
