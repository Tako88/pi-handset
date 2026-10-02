/// The block renderers: one widget per [TranscriptBlockKind].
///
/// Each is keyed by the view (through the block id) and wrapped in a
/// `RepaintBoundary` there, so a streamed frame repaints only the streaming row.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../client/tool_view.dart';
import '../client/transcript.dart';
import 'tool_views.dart';

/// The width cap handed to the decoder. Only the width: with *both* cache
/// dimensions set, `ResizeImage` defaults to `ResizeImagePolicy.exact`
/// (`BoxFit.fill`), which squashes every image into a square.
const int imageDecodeMaxExtent = 1024;

/// The tallest an image row may display. The decoder bounds the width; this
/// bounds the row so a panoramic or very tall image cannot dominate the
/// transcript. (`BoxConstraints.maxHeight` takes a `double`, so this is not an
/// `int` even though the value is whole.)
const double imageMaxDisplayHeight = 320;

/// The `Uri` a tapped markdown link should open, or null when the link is not
/// one this app opens.
///
/// Only `http`/`https` are handed to the platform. An anchor (`#...`), a
/// `mailto:`, a bare relative path, and an empty or null href all return null:
/// the renderer may produce them, but the phone has no handler we want to
/// invoke, and `url_launcher` would either fail or open an unrelated app.
Uri? linkUriToOpen(String? href) {
  if (href == null || href.isEmpty) return null;
  final uri = Uri.tryParse(href);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri;
}

/// The real opener: hands [uri] to the platform's browser. A launch that fails
/// — no handler, a platform error — is a silent no-op; there is nothing the
/// viewer can do with an error about a link that would not open.
Future<void> openExternalLink(Uri uri) async {
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // Deliberately swallowed; see above.
  }
}

/// A committed or in-flight text block. Plain `Text` until [TranscriptBlock.complete],
/// then markdown; the user's own messages are aligned and tinted apart.
class TextBlock extends StatelessWidget {
  const TextBlock({
    super.key,
    required this.block,
    this.onOpenLink = openExternalLink,
  });

  final TranscriptBlock block;

  /// How a tapped link is opened. Injectable so a widget test can assert the
  /// wiring without a platform channel; production uses [openExternalLink].
  final Future<void> Function(Uri uri) onOpenLink;

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
            ? MarkdownBody(
                data: block.text,
                onTapLink: (text, href, title) {
                  final uri = linkUriToOpen(href);
                  if (uri != null) onOpenLink(uri);
                },
              )
            : Text(block.text),
      ),
    );
  }
}

/// An image part, rendered from the bytes decoded at parse time. Reuses
/// [TextBlock]'s alignment and tint so a user's image reads as their own
/// message. Only the width is capped for decoding (see [imageDecodeMaxExtent]).
class ImageBlock extends StatelessWidget {
  const ImageBlock({super.key, required this.block});

  final TranscriptBlock block;

  @override
  Widget build(BuildContext context) {
    final bytes = block.imageBytes;
    final colors = Theme.of(context).colorScheme;
    // Unreachable in practice: TranscriptBlock asserts image blocks carry
    // bytes. Rendering nothing beats a crash if that invariant ever breaks.
    if (bytes == null) return const SizedBox.shrink();
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
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: imageMaxDisplayHeight),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              bytes,
              // ONLY cacheWidth. With cacheHeight also set, ResizeImage defaults
              // to ResizeImagePolicy.exact, which is BoxFit.fill — it would
              // squash the image into a square. One dimension keeps the ratio.
              cacheWidth: imageDecodeMaxExtent,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) => const Text('[image]'),
            ),
          ),
        ),
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

/// A tool call row: a header of icon + name + summary, and a body dispatched
/// by the bridge's normalized view — or the generic result preview when the
/// frame carried none (version skew). Controlled by [TranscriptView], which owns
/// the single-expanded-row rule; tapping always toggles, because the row always
/// has a header. An error result is tinted and iconed apart. The TUI's own
/// `[Showing lines … Full output: …]` note is inside the result and renders
/// verbatim — the path is never fetched (the phone cannot read the PC's temp
/// file).
class ToolBlock extends StatelessWidget {
  const ToolBlock({
    super.key,
    required this.block,
    required this.expanded,
    required this.onToggle,
  });

  final TranscriptBlock block;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final name = block.toolName ?? 'tool';
    final view = block.toolView;
    final summary = toolSummary(view, toolName: block.toolName);
    final args = argumentsLabel(block.toolArgs);
    final accent = block.isError ? colors.error : colors.outline;
    final Widget body = view == null
        ? GenericToolBody(
            text: block.text,
            expanded: expanded,
            isError: block.isError,
          )
        : ToolViewBody(
            view: view,
            expanded: expanded,
            text: block.text,
            isError: block.isError,
          );
    return InkWell(
      onTap: onToggle,
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
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    summary != null && summary.isNotEmpty ? summary : args,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: body,
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
