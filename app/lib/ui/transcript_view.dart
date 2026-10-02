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
/// Presentational: block derivation happens in the client, not here, so a
/// stream delta never re-walks the transcript.
library;

import 'package:flutter/material.dart';

import '../client/hub_client.dart';
import '../client/stick_to_bottom.dart';
import '../client/transcript.dart';
import 'transcript_blocks.dart';

class TranscriptView extends StatefulWidget {
  const TranscriptView({super.key, required this.transcript});

  final SessionTranscript transcript;

  static const String emptyMessage = 'No messages yet.';

  /// Shown above the oldest row a truncated history kept. The window is a
  /// suffix, so the cut is at the *top*; without this the transcript looks like
  /// the session simply began at that message.
  static const String truncatedNotice =
      'Older messages are not loaded — this session is longer than the history limit.';

  /// The streaming row's key. Stable across frames so its element and repaint
  /// boundary are reused while deltas accumulate.
  static const Key streamingKey = ValueKey('transcript-streaming');

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
                ),
              );
            }
            final block = blocks[blockIndex];
            return RepaintBoundary(
              key: ValueKey(block.id),
              child: _block(block),
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
              child: const Icon(Icons.arrow_downward),
            ),
          ),
      ],
    );
  }

  Widget _block(TranscriptBlock block) {
    switch (block.kind) {
      case TranscriptBlockKind.text:
        return TextBlock(block: block);
      case TranscriptBlockKind.thinking:
        return ThinkingBlock(block: block);
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
    }
  }
}
