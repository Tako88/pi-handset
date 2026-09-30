/// The block renderers: one widget per [TranscriptBlockKind].
///
/// Each is keyed by the view (through the block id) and wrapped in a
/// `RepaintBoundary` there, so a streamed frame repaints only the streaming row.
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../client/transcript.dart';

/// A committed or in-flight text block. Plain `Text` until [TranscriptBlock.complete],
/// then markdown; the user's own messages are aligned and tinted apart.
class TextBlock extends StatelessWidget {
  const TextBlock({super.key, required this.block});

  final TranscriptBlock block;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: block.fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: block.fromUser
              ? colors.primaryContainer
              : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: block.complete
            ? MarkdownBody(data: block.text)
            : Text(block.text),
      ),
    );
  }
}

/// Thinking is rendered visibly by default (the point of rendering it at all)
/// and collapses to its label on tap.
class ThinkingBlock extends StatefulWidget {
  const ThinkingBlock({super.key, required this.block});

  final TranscriptBlock block;

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.psychology, size: 16, color: colors.outline),
                const SizedBox(width: 6),
                Text(
                  'Thinking',
                  style: TextStyle(color: colors.outline, fontSize: 12),
                ),
              ],
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  widget.block.text,
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A tool call row. M1 labels the call; M2 adds the collapsed result.
class ToolBlock extends StatelessWidget {
  const ToolBlock({super.key, required this.block});

  final TranscriptBlock block;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final name = block.toolName ?? 'tool';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        'tool · $name',
        style: TextStyle(color: colors.outline, fontSize: 12),
      ),
    );
  }
}

/// A truncation or status notice.
class NoticeBlock extends StatelessWidget {
  const NoticeBlock({super.key, required this.block});

  final TranscriptBlock block;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        block.text,
        style: TextStyle(color: colors.outline, fontStyle: FontStyle.italic),
      ),
    );
  }
}
