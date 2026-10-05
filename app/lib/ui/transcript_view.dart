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
    this.onOpenLink = openExternalLink,
    this.onCopyText = copyToClipboard,
  });

  final SessionTranscript transcript;

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

  /// Whether the viewer is following the bottom. It is *not* recomputed from
  /// the offset after content growth (in a forward list that would read as "not
  /// at the bottom" the instant `maxScrollExtent` grew), so it must be read
  /// before the new content is laid out.
  bool _following = true;

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
    // A tall transcript must open at its newest row, not its oldest.
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
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
            return RepaintBoundary(
              key: ValueKey(block.id),
              child: _selectable(block, _block(block)),
            );
          },
        ),
        if (!_following)
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

  Widget _block(TranscriptBlock block) {
    switch (block.kind) {
      case TranscriptBlockKind.text:
        return TextBlock(block: block, onOpenLink: widget.onOpenLink);
      case TranscriptBlockKind.thinking:
        return ThinkingBlock(
          block: block,
          thinkingLevel: widget.transcript.thinkingLevel,
        );
      case TranscriptBlockKind.tool:
        final expanded = block.id == _expandedToolId;
        return ToolBlock(
          block: block,
          expanded: expanded,
          onToggle: () => setState(() {
            _expandedToolId = expanded ? null : block.id;
          }),
        );
      case TranscriptBlockKind.notice:
        return NoticeBlock(block: block);
      case TranscriptBlockKind.image:
        return ImageBlock(block: block);
    }
  }
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
