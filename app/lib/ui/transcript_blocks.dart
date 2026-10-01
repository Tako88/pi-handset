/// The block renderers: one widget per [TranscriptBlockKind].
///
/// Each is keyed by the view (through the block id) and wrapped in a
/// `RepaintBoundary` there, so a streamed frame repaints only the streaming row.
library;

import 'dart:convert';

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
/// and collapses to its label on tap. An in-flight row (`complete == false`) is
/// not collapsible: it is rebuilt on every delta, and a tap target that resets
/// or vanishes mid-turn is a control changing under the user. It is replaced by
/// the committed, collapsible block when the assistant message lands.
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
    final body = Padding(
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
          if (widget.block.complete ? _expanded : true)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                widget.block.text,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
    if (!widget.block.complete) return body;
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: body,
    );
  }
}

/// A tool call row: collapsed by default, showing the tool name, its arguments
/// and a capped result preview; tap to expand the full result. An error result
/// is tinted and iconed apart. The TUI's own `[Showing lines … Full output: …]`
/// note is inside the result and renders verbatim — the path is never fetched
/// (the phone cannot read the PC's temp file).
class ToolBlock extends StatefulWidget {
  const ToolBlock({super.key, required this.block});

  final TranscriptBlock block;

  @override
  State<ToolBlock> createState() => _ToolBlockState();
}

class _ToolBlockState extends State<ToolBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final block = widget.block;
    final name = block.toolName ?? 'tool';
    final args = argumentsLabel(block.toolArgs);
    final hasResult = block.toolResult != null;
    final preview = previewToolResult(block.text);
    final body = _expanded ? block.text : preview.shown;
    final accent = block.isError ? colors.error : colors.outline;
    return InkWell(
      onTap: hasResult ? () => setState(() => _expanded = !_expanded) : null,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: block.isError
              ? colors.errorContainer
              : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  block.isError ? Icons.error_outline : Icons.build,
                  size: 16,
                  color: accent,
                ),
                const SizedBox(width: 6),
                Text(
                  name,
                  style: TextStyle(fontWeight: FontWeight.w600, color: colors.onSurface),
                ),
                if (args.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      args,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
                    ),
                  ),
                ],
              ],
            ),
            if (hasResult && body.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  body,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: block.isError ? colors.onErrorContainer : colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
            if (hasResult && !_expanded && preview.isTruncated)
              Text(
                '… (${preview.hiddenLines} more lines)',
                style: TextStyle(color: colors.outline, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }
}

/// The most argument characters the header row shows. A `write`/`edit` call
/// carries the whole file body in its arguments, and without a cap the header
/// would hand kilobytes to layout (and measure them). One generic cap; the
/// spinner never depends on the exact width.
const int toolArgumentsLabelMaxChars = 200;

/// Renders tool arguments compactly for the header line: JSON when structured,
/// the raw string otherwise, capped with an ellipsis.
String argumentsLabel(Object? args) {
  final raw = args == null
      ? ''
      : args is String
      ? args
      : args is Map
      ? jsonEncode(args)
      : args.toString();
  if (raw.length <= toolArgumentsLabelMaxChars) return raw;
  return '${raw.substring(0, toolArgumentsLabelMaxChars)}…';
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
