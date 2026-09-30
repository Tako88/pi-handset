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
/// Presentational: block derivation happens in the client, not here, so a
/// stream delta never re-walks the transcript.
library;

import 'package:flutter/material.dart';

import '../client/hub_client.dart';
import '../client/transcript.dart';
import 'transcript_blocks.dart';

class TranscriptView extends StatelessWidget {
  const TranscriptView({super.key, required this.transcript});

  final SessionTranscript transcript;

  static const String emptyMessage = 'No messages yet.';

  /// The streaming row's key. Stable across frames so its element and repaint
  /// boundary are reused while deltas accumulate.
  static const Key streamingKey = ValueKey('transcript-streaming');

  @override
  Widget build(BuildContext context) {
    final blocks = transcript.blocks;
    final streaming =
        transcript.streaming && transcript.streamingText.isNotEmpty;
    final itemCount = blocks.length + (streaming ? 1 : 0);
    if (itemCount == 0) {
      return const Center(child: Text(TranscriptView.emptyMessage));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index >= blocks.length) {
          return RepaintBoundary(
            key: TranscriptView.streamingKey,
            child: TextBlock(
              block: TranscriptBlock(
                kind: TranscriptBlockKind.text,
                id: 'streaming',
                text: transcript.streamingText,
                complete: false,
              ),
            ),
          );
        }
        final block = blocks[index];
        return RepaintBoundary(
          key: ValueKey(block.id),
          child: _block(block),
        );
      },
    );
  }

  Widget _block(TranscriptBlock block) {
    switch (block.kind) {
      case TranscriptBlockKind.text:
        return TextBlock(block: block);
      case TranscriptBlockKind.thinking:
        return ThinkingBlock(block: block);
      case TranscriptBlockKind.tool:
        return ToolBlock(block: block);
      case TranscriptBlockKind.notice:
        return NoticeBlock(block: block);
    }
  }
}
