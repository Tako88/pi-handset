/// The transcript block model — one ordered list of blocks derived from the raw
/// relayed entries.
///
/// Pure Dart: no Flutter import, so it tests without a widget binding. The same
/// [deriveBlocks] serves the live relay and the reconnect snapshot, because the
/// two paths carry the same pi *message* shape in different *entry* shapes:
/// live is a bare `{role, content}`; a snapshot entry is wrapped
/// `{type: 'message', message: {…}}` and interleaved with bookkeeping rows.
///
/// Deliberately not a widget concern: the view reads blocks; nothing here knows
/// how a block is painted.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'tool_view.dart';

/// The kinds of row a transcript renders, in order of appearance.
enum TranscriptBlockKind { text, thinking, tool, notice, image }

/// One rendered row, derived from an entry (and, from M2, a paired result).
class TranscriptBlock {
  final TranscriptBlockKind kind;

  /// Stable row key. A prepend or a truncation must not shift it.
  final String id;

  /// The text/thinking body, or the notice message.
  final String text;

  /// Text blocks: the user's own message styling.
  final bool fromUser;

  /// False while the block is still arriving. Text blocks: plain `Text` rather
  /// than markdown. Thinking blocks: the live row, which is not collapsible and
  /// is replaced by the committed block when the message lands.
  final bool complete;

  final String? toolName;
  final Object? toolArgs;

  /// The raw tool-result message when paired (M2); null while the call runs.
  final Object? toolResult;

  /// The bridge's parsed render model for this tool call (M3); null when the
  /// frame carried none (version skew) or an unknown `view.type`, in which case
  /// the renderer falls back to the generic preview.
  final ToolView? toolView;
  final bool isError;

  /// The decoded bytes of an image part. Non-null exactly when [kind] is
  /// [TranscriptBlockKind.image]; the constructor asserts that invariant.
  final Uint8List? imageBytes;

  const TranscriptBlock({
    required this.kind,
    required this.id,
    this.text = '',
    this.fromUser = false,
    this.complete = true,
    this.toolName,
    this.toolArgs,
    this.toolResult,
    this.toolView,
    this.isError = false,
    this.imageBytes,
  }) : assert(
         kind != TranscriptBlockKind.image || imageBytes != null,
         'an image block must carry decoded bytes',
       );
}

/// Derives the ordered block list for [entries]. Pure and O(n) in the number of
/// entries — call it when entries change, never per stream delta.
List<TranscriptBlock> deriveBlocks(List<Object?> entries) {
  // Pass 1 — index tool results by call id (first-wins) and collect the call
  // ids the assistant issued. A resumed/forked branch can surface the same
  // call twice; dropping a later duplicate rather than overwriting keeps the
  // call row showing the first result, not the second. The result may appear
  // before or after its call, so the index is built before pass 2 emits.
  final resultsById = <String, Map<Object?, Object?>>{};
  // A second, SEPARATE index for the bridge's `kind:'tool'` annotation frames,
  // with the OPPOSITE rule: last-wins, because a call emits `running` then
  // `done` and the done view must replace the input-only running one. Keeping
  // the two rules apart is deliberate — reusing `resultsById` would flip the
  // fork semantics above.
  final viewsById = <String, Object?>{};
  final callIds = <String>{};
  for (final entry in entries) {
    if (entry is! Map) continue;
    if (entry['kind'] == 'tool') {
      final callId = entry['toolCallId'];
      // Last-wins applies to present views only: a done frame may carry no
      // view, and clobbering the running frame's input-only view would drop
      // the structured render for the generic fallback.
      if (callId is String && entry['view'] != null) {
        viewsById[callId] = entry['view'];
      }
      continue;
    }
    final source = _unwrap(entry);
    if (source == null) continue;
    final role = source['role'];
    if (role == 'toolResult') {
      final callId = source['toolCallId'];
      if (callId is String && !resultsById.containsKey(callId)) {
        resultsById[callId] = source;
      }
    } else if (role == 'assistant') {
      _collectToolCallIds(source['content'], callIds);
    }
  }

  final blocks = <TranscriptBlock>[];
  // Per-derivation counts of emitted tool ids: a fork can surface the same call
  // id twice, and two blocks sharing an `id` collide the view's `ValueKey`.
  final toolIdCounts = <String, int>{};
  for (final entry in entries) {
    if (entry is! Map) continue;
    final idBase = identityHashCode(entry);

    // A message the bridge could not relay whole: an honest notice, not a gap.
    if (entry['truncated'] == true && entry['bytes'] is int) {
      blocks.add(
        TranscriptBlock(
          kind: TranscriptBlockKind.notice,
          id: '$idBase:0',
          text: 'reply too large to display (${entry['bytes']} bytes)',
        ),
      );
      continue;
    }
    // A relayed status payload (e.g. an error) is a notice.
    if (entry['kind'] == 'status' && entry['message'] is String) {
      final message = entry['message'] as String;
      if (message.isEmpty) continue;
      blocks.add(
        TranscriptBlock(
          kind: TranscriptBlockKind.notice,
          id: '$idBase:0',
          text: message,
        ),
      );
      continue;
    }

    // A relayed `kind:'tool'` frame is an annotation on a call or result row,
    // never a row source of its own: pass 1 indexed its view, and it was
    // attached in pass 2. Emitting it here would render a duplicate row.
    if (entry['kind'] == 'tool') continue;

    final source = _unwrap(entry);
    if (source == null) {
      // The flattened fixture shape `{type: 'user'|'assistant', text}`.
      final type = entry['type'];
      if ((type == 'user' || type == 'assistant') && entry['text'] is String) {
        final text = entry['text'] as String;
        if (text.isEmpty) continue;
        blocks.add(
          TranscriptBlock(
            kind: TranscriptBlockKind.text,
            id: '$idBase:0',
            text: text,
            fromUser: type == 'user',
          ),
        );
      }
      continue;
    }

    final role = source['role'];
    if (role == 'user') {
      _emitTextContent(blocks, source['content'], idBase, fromUser: true);
    } else if (role == 'assistant') {
      _emitAssistantContent(
        blocks,
        source['content'],
        idBase,
        resultsById,
        viewsById,
        toolIdCounts,
      );
    } else if (role == 'toolResult') {
      final callId = source['toolCallId'];
      // Paired: already rendered at its call in the assistant message.
      if (callId is String && callIds.contains(callId)) continue;
      _emitToolResult(blocks, source, idBase, viewsById, toolIdCounts);
    }
    // `system`, `custom` and bookkeeping roles take no block.
  }
  return blocks;
}

/// A tool-block id, disambiguated when a fork surfaces the same call id twice.
/// The first occurrence keeps the bare `tool:<callId>` so the common case is
/// unchanged; later occurrences get a `#n` suffix, keeping every `ValueKey`
/// distinct so expansion state cannot attach to the wrong row.
String _toolBlockId(String callId, Map<String, int> seen) {
  final index = seen[callId] ?? 0;
  seen[callId] = index + 1;
  return index == 0 ? 'tool:$callId' : 'tool:$callId#$index';
}

/// Collects the `toolCall` ids in an assistant message's content.
void _collectToolCallIds(Object? content, Set<String> ids) {
  if (content is! List) return;
  for (final part in content) {
    if (part is Map && part['type'] == 'toolCall' && part['id'] is String) {
      ids.add(part['id'] as String);
    }
  }
}

/// Unwraps a snapshot entry (`{type:'message', message:{…}}`) or accepts a bare
/// message (`{role, content}`). Returns null for anything else, including the
/// flattened fixture shape and bookkeeping rows.
Map<Object?, Object?>? _unwrap(Map<Object?, Object?> entry) {
  final nested = entry['message'];
  if (nested is Map) return nested;
  if (entry['role'] is String) return entry;
  return null;
}

/// The decoded bytes of an `ImageContent` part, or null when the part is not
/// renderable — missing/empty/non-string `data`, or `data` that is not base64.
/// Never throws: `base64Decode` raises `FormatException`, and a throw here
/// would escape `deriveBlocks` and blank the transcript.
Uint8List? _decodeImageBytes(Map<Object?, Object?> part) {
  final data = part['data'];
  if (data is! String || data.isEmpty) return null;
  try {
    return base64Decode(data);
  } on FormatException {
    return null;
  }
}

void _emitTextContent(
  List<TranscriptBlock> blocks,
  Object? content,
  int idBase, {
  required bool fromUser,
}) {
  if (content is String) {
    if (content.isEmpty) return;
    blocks.add(
      TranscriptBlock(
        kind: TranscriptBlockKind.text,
        id: '$idBase:0',
        text: content,
        fromUser: fromUser,
      ),
    );
    return;
  }
  if (content is! List) return;
  var sub = 0;
  for (final part in content) {
    if (part is Map) {
      final type = part['type'];
      if (type == 'text' && part['text'] is String) {
        final text = part['text'] as String;
        if (text.isNotEmpty) {
          blocks.add(
            TranscriptBlock(
              kind: TranscriptBlockKind.text,
              id: '$idBase:$sub',
              text: text,
              fromUser: fromUser,
            ),
          );
        }
      } else if (type == 'image') {
        final bytes = _decodeImageBytes(part);
        if (bytes != null) {
          blocks.add(
            TranscriptBlock(
              kind: TranscriptBlockKind.image,
              id: '$idBase:$sub',
              imageBytes: bytes,
              fromUser: fromUser,
            ),
          );
        } else {
          blocks.add(
            TranscriptBlock(
              kind: TranscriptBlockKind.text,
              id: '$idBase:$sub',
              text: '[image]',
              fromUser: fromUser,
            ),
          );
        }
      }
    }
    sub++;
  }
}

void _emitAssistantContent(
  List<TranscriptBlock> blocks,
  Object? content,
  int idBase,
  Map<String, Map<Object?, Object?>> resultsById,
  Map<String, Object?> viewsById,
  Map<String, int> toolIdCounts,
) {
  if (content is String) {
    if (content.isEmpty) return;
    blocks.add(
      TranscriptBlock(
        kind: TranscriptBlockKind.text,
        id: '$idBase:0',
        text: content,
      ),
    );
    return;
  }
  if (content is! List) return;
  var sub = 0;
  for (final part in content) {
    if (part is Map) {
      final type = part['type'];
      if (type == 'text') {
        final text = part['text'];
        if (text is String && text.isNotEmpty) {
          blocks.add(
            TranscriptBlock(
              kind: TranscriptBlockKind.text,
              id: '$idBase:$sub',
              text: text,
            ),
          );
        }
      } else if (type == 'thinking') {
        final body = _thinkingBody(part);
        if (body != null) _addThinking(blocks, '$idBase:$sub', body);
      } else if (type == 'toolCall') {
        final callId = part['id'] is String ? part['id'] as String : '$idBase:$sub';
        final result = resultsById[callId];
        blocks.add(
          TranscriptBlock(
            kind: TranscriptBlockKind.tool,
            id: _toolBlockId(callId, toolIdCounts),
            toolName: part['name'] is String ? part['name'] as String : null,
            toolArgs: part['arguments'],
            text: result == null ? '' : _resultText(result),
            toolResult: result,
            toolView: parseToolView(viewsById[callId]),
            isError: result != null && result['isError'] == true,
          ),
        );
      } else if (type == 'image') {
        final bytes = _decodeImageBytes(part);
        if (bytes != null) {
          blocks.add(
            TranscriptBlock(
              kind: TranscriptBlockKind.image,
              id: '$idBase:$sub',
              imageBytes: bytes,
            ),
          );
        } else {
          blocks.add(
            TranscriptBlock(
              kind: TranscriptBlockKind.text,
              id: '$idBase:$sub',
              text: '[image]',
            ),
          );
        }
      }
    }
    sub++;
  }
}

/// Reads the `thinking` field — never `text` — and never the opaque `redacted`
/// blob, which exists only for multi-turn continuity.
String? _thinkingBody(Map<Object?, Object?> part) {
  if (part['redacted'] == true) return '[reasoning redacted]';
  final body = part['thinking'];
  if (body is! String || body.trim().isEmpty) return null;
  return body;
}

/// Coalesces consecutive thinking blocks into one, joined by a blank line — TUI
/// parity, and one row instead of one per chunk.
void _addThinking(List<TranscriptBlock> blocks, String id, String body) {
  if (blocks.isNotEmpty && blocks.last.kind == TranscriptBlockKind.thinking) {
    final last = blocks.removeLast();
    blocks.add(
      TranscriptBlock(
        kind: TranscriptBlockKind.thinking,
        id: last.id,
        text: '${last.text}\n\n$body',
      ),
    );
    return;
  }
  blocks.add(
    TranscriptBlock(
      kind: TranscriptBlockKind.thinking,
      id: id,
      text: body,
    ),
  );
}

/// The number of lines a collapsed tool result shows. One generic cap, not a
/// per-tool table: a test pins it so tuning it cannot silently change behaviour.
const int toolResultPreviewLines = 8;

/// The visible prefix of a collapsed tool result and how many lines it hides.
class ToolPreview {
  final String shown;
  final int hiddenLines;
  const ToolPreview(this.shown, this.hiddenLines);

  bool get isTruncated => hiddenLines > 0;
}

/// Splits [text] at [maxLines], reporting how many lines it hid.
ToolPreview previewToolResult(
  String text, {
  int maxLines = toolResultPreviewLines,
}) {
  if (text.isEmpty) return const ToolPreview('', 0);
  final lines = text.split('\n');
  if (lines.length <= maxLines) return ToolPreview(text, 0);
  return ToolPreview(lines.take(maxLines).join('\n'), lines.length - maxLines);
}

/// A tool result whose assistant call was not in the entries becomes a
/// standalone row rather than vanishing (a history projection may cut the call
/// but keep the result).
void _emitToolResult(
  List<TranscriptBlock> blocks,
  Map<Object?, Object?> source,
  int idBase,
  Map<String, Object?> viewsById,
  Map<String, int> toolIdCounts,
) {
  final callId = source['toolCallId'];
  blocks.add(
    TranscriptBlock(
      kind: TranscriptBlockKind.tool,
      id: callId is String ? _toolBlockId(callId, toolIdCounts) : '$idBase:0',
      text: _resultText(source),
      toolName: source['toolName'] is String ? source['toolName'] as String : null,
      toolResult: source,
      toolView: callId is String ? parseToolView(viewsById[callId]) : null,
      isError: source['isError'] == true,
    ),
  );
}

/// The result's display text: text parts joined, images as an `[image]`
/// placeholder. Image bytes are never fetched (and a placeholder is not a
/// renderer).
String _resultText(Map<Object?, Object?> source) {
  final content = source['content'];
  if (content is String) return content;
  if (content is! List) return '';
  final parts = <String>[];
  for (final part in content) {
    if (part is! Map) continue;
    final type = part['type'];
    if (type == 'text' && part['text'] is String) {
      parts.add(part['text'] as String);
    } else if (type == 'image') {
      parts.add('[image]');
    }
  }
  return parts.join('\n');
}
