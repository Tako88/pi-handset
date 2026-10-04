/// The block renderers: one widget per [TranscriptBlockKind].
///
/// The transcript is a **document**, not a chat of bubbles. Every row begins at
/// the same left text edge ([DocumentRow]), and a rule in the gutter carries
/// the row's role: the user's violet, a tool row's state, a thinking row's
/// level. Colours are pi's own — see `theme.dart` and
/// `.pi/plans/redesign/spec.md`.
///
/// Each row is keyed by the view (through the block id) and wrapped in a
/// `RepaintBoundary` there, so a streamed frame repaints only the streaming row.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../client/tool_view.dart';
import '../client/transcript.dart';
import 'theme.dart';
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

/// pi's markdown roles applied to a rendered block.
///
/// Fenced code takes [PiRoles.mdCodeBlock] — pi's own colour for code it cannot
/// syntax-highlight, which is every code block here, since the app has no
/// highlighter. Inline code takes [PiRoles.mdCode].
MarkdownStyleSheet piMarkdownStyle(PiRoles roles, {Color? bodyColor}) {
  final body = TextStyle(
    color: bodyColor ?? roles.text,
    fontSize: 15,
    height: 1.45,
  );
  return MarkdownStyleSheet(
    p: body,
    a: body.copyWith(
      color: roles.mdLink,
      decoration: TextDecoration.underline,
      decorationColor: roles.mdLink,
    ),
    em: body.copyWith(fontStyle: FontStyle.italic),
    strong: body.copyWith(fontWeight: FontWeight.w600),
    del: body.copyWith(decoration: TextDecoration.lineThrough),
    code: piMono(color: roles.mdCode, fontSize: 13),
    codeblockPadding: const EdgeInsets.all(10),
    codeblockDecoration: BoxDecoration(
      color: roles.cardBg,
      border: Border(left: BorderSide(color: roles.mdCodeBlockBorder, width: 3)),
    ),
    h1: piMono(color: roles.mdHeading, fontSize: 20, fontWeight: FontWeight.w600),
    h2: piMono(color: roles.mdHeading, fontSize: 18, fontWeight: FontWeight.w600),
    h3: piMono(color: roles.mdHeading, fontSize: 16, fontWeight: FontWeight.w600),
    h4: piMono(color: roles.mdHeading, fontSize: 15, fontWeight: FontWeight.w600),
    h5: piMono(color: roles.mdHeading, fontSize: 15, fontWeight: FontWeight.w600),
    h6: piMono(color: roles.mdHeading, fontSize: 15, fontWeight: FontWeight.w600),
    blockSpacing: 10,
    blockquote: body.copyWith(color: roles.mdQuote),
    blockquotePadding: const EdgeInsets.only(left: 10),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: roles.mdQuote, width: 3)),
    ),
    listBullet: body.copyWith(color: roles.mdListBullet),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: roles.dim)),
    ),
  );
}

/// A committed or in-flight text block. Plain `Text` until [TranscriptBlock.complete],
/// then markdown. The user's own messages carry the violet rule and pi's user
/// message tint; the agent's prose carries no rules and no surface, because it
/// is the document's default voice.
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
    final roles = Theme.of(context).extension<PiRoles>()!;
    final mine = block.fromUser;
    final bodyColor = mine ? roles.userMessageText : roles.text;
    return DocumentRow(
      rule: mine ? roles.accent : null,
      background: mine ? roles.userMessageBg : null,
      child: block.complete
          ? MarkdownBody(
              data: block.text,
              styleSheet: piMarkdownStyle(roles, bodyColor: bodyColor),
              onTapLink: (text, href, title) {
                final uri = linkUriToOpen(href);
                if (uri != null) onOpenLink(uri);
              },
            )
          : Text(
              block.text,
              style: TextStyle(color: bodyColor, fontSize: 15, height: 1.45),
            ),
    );
  }
}

/// An image part, rendered from the bytes decoded at parse time. Carries the
/// user's rule and tint so an image reads as part of their message. Only the
/// width is capped for decoding (see [imageDecodeMaxExtent]).
class ImageBlock extends StatelessWidget {
  const ImageBlock({super.key, required this.block});

  final TranscriptBlock block;

  @override
  Widget build(BuildContext context) {
    final bytes = block.imageBytes;
    final roles = Theme.of(context).extension<PiRoles>()!;
    // Unreachable in practice: TranscriptBlock asserts image blocks carry
    // bytes. Rendering nothing beats a crash if that invariant ever breaks.
    if (bytes == null) return const SizedBox.shrink();
    final mine = block.fromUser;
    return DocumentRow(
      rule: mine ? roles.accent : roles.dim,
      background: mine ? roles.userMessageBg : roles.cardBg,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: imageMaxDisplayHeight),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(2),
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
    );
  }
}

/// Thinking is rendered visibly by default (the point of rendering it at all)
/// and collapses to its label on tap. An in-flight row (`complete == false`) is
/// not collapsible: it is rebuilt on every delta, and a tap target that resets
/// or vanishes mid-turn is a control changing under the user. It is replaced by
/// the committed, collapsible block when the assistant message lands.
///
/// The **icon** takes the colour pi gives [thinkingLevel] — the one piece of the
/// palette that encodes state you would otherwise have to ask for — and the
/// label names the level in words, so the signal is never colour-only. The ramp
/// cannot go on the label text: it is a border colour, and its values are 3–4:1,
/// under the 4.5:1 a line of text needs.
///
/// The rule is [PiRoles.dim], not the ramp. A ramp colour up here would be
/// violet at `high` — the same violet as the user's own rule — so two different
/// things would read as one. Neutral means "the agent's internal work"; the
/// violet rule means "you".
class ThinkingBlock extends StatefulWidget {
  const ThinkingBlock({
    super.key,
    required this.block,
    required this.thinkingLevel,
  });

  final TranscriptBlock block;

  /// pi's current thinking level, or null when the session has not reported one
  /// (a fresh session, or a bridge older than the level).
  final String? thinkingLevel;

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final roles = Theme.of(context).extension<PiRoles>()!;
    final level = thinkingLevelColor(roles, widget.thinkingLevel);
    final label = widget.thinkingLevel == null
        ? 'Thinking'
        : 'Thinking · ${widget.thinkingLevel}';
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.psychology, size: 16, color: level),
            const SizedBox(width: 6),
            Text(label, style: piMono(fontSize: 12, color: roles.muted)),
          ],
        ),
        if (widget.block.complete ? _expanded : true)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              widget.block.text,
              style: TextStyle(color: roles.muted, height: 1.45),
            ),
          ),
      ],
    );
    return DocumentRow(
      rule: roles.dim,
      child: widget.block.complete
          ? InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: body,
            )
          : body,
    );
  }
}

/// A tool call row: a header of icon + name + summary, and a body dispatched
/// by the bridge's normalized view — or the generic result preview when the
/// frame carried none (version skew). Controlled by [TranscriptView], which owns
/// the single-expanded-row rule; tapping always toggles, because the row always
/// has a header.
///
/// The row is tinted and ruled by its **state** — running, succeeded, failed —
/// which the client already knows, so the colour is information rather than
/// decoration. The TUI's own `[Showing lines … Full output: …]` note is inside
/// the result and renders verbatim — the path is never fetched (the phone cannot
/// read the PC's temp file).
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
    final roles = Theme.of(context).extension<PiRoles>()!;
    final name = block.toolName ?? 'tool';
    final view = block.toolView;
    final summary = toolSummary(view, toolName: block.toolName);
    final args = argumentsLabel(block.toolArgs);
    // A call with no result yet is still running; `complete` is not the signal,
    // because a tool call entry is complete the moment it is written.
    final pending = block.toolResult == null;
    final state = block.isError
        ? roles.error
        : pending
        ? roles.muted
        : roles.success;
    final surface = block.isError
        ? roles.toolErrorBg
        : pending
        ? roles.toolPendingBg
        : roles.toolSuccessBg;
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
    return DocumentRow(
      rule: state,
      background: surface,
      onTap: onToggle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                block.isError ? Icons.error_outline : Icons.build,
                size: 16,
                color: state,
              ),
              const SizedBox(width: 6),
              Text(
                name,
                style: piMono(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: roles.toolTitle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  summary != null && summary.isNotEmpty ? summary : args,
                  overflow: TextOverflow.ellipsis,
                  style: piMono(fontSize: 12, color: roles.toolOutput),
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

/// A truncation or status notice: the document's footnote, with no rule and no
/// surface of its own.
class NoticeBlock extends StatelessWidget {
  const NoticeBlock({super.key, required this.block});

  final TranscriptBlock block;

  @override
  Widget build(BuildContext context) {
    final roles = Theme.of(context).extension<PiRoles>()!;
    return DocumentRow(
      child: Text(
        block.text,
        style: TextStyle(
          color: roles.muted,
          fontStyle: FontStyle.italic,
          height: 1.45,
        ),
      ),
    );
  }
}
