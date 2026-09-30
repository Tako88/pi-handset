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

/// The kinds of row a transcript renders, in order of appearance.
enum TranscriptBlockKind { text, thinking, tool, notice }

/// One rendered row, derived from an entry (and, from M2, a paired result).
class TranscriptBlock {
  final TranscriptBlockKind kind;

  /// Stable row key. A prepend or a truncation must not shift it.
  final String id;

  /// The text/thinking body, or the notice message.
  final String text;

  /// Text blocks: the user's own message styling.
  final bool fromUser;

  /// Text blocks: false renders plain `Text` (in-flight), true renders markdown.
  final bool complete;

  final String? toolName;
  final Object? toolArgs;

  /// The raw tool-result message when paired (M2); null while the call runs.
  final Object? toolResult;
  final bool isError;

  const TranscriptBlock({
    required this.kind,
    required this.id,
    this.text = '',
    this.fromUser = false,
    this.complete = true,
    this.toolName,
    this.toolArgs,
    this.toolResult,
    this.isError = false,
  });
}

/// Derives the ordered block list for [entries]. Pure and O(n) in the number of
/// entries — call it when entries change, never per stream delta.
List<TranscriptBlock> deriveBlocks(List<Object?> entries) {
  final blocks = <TranscriptBlock>[];
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
      _emitAssistantContent(blocks, source['content'], idBase);
    } else if (role == 'toolResult') {
      _emitToolResult(blocks, source, idBase);
    }
    // `system`, `custom` and bookkeeping roles take no block.
  }
  return blocks;
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
    sub++;
  }
}

void _emitAssistantContent(
  List<TranscriptBlock> blocks,
  Object? content,
  int idBase,
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
        blocks.add(
          TranscriptBlock(
            kind: TranscriptBlockKind.tool,
            id: 'tool:$callId',
            toolName: part['name'] is String ? part['name'] as String : null,
            toolArgs: part['arguments'],
          ),
        );
      } else if (type == 'image') {
        blocks.add(
          TranscriptBlock(
            kind: TranscriptBlockKind.text,
            id: '$idBase:$sub',
            text: '[image]',
          ),
        );
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

/// A tool result whose assistant call was not in the entries becomes a
/// standalone row rather than vanishing (M1: within a snapshot; M2 pairs it).
void _emitToolResult(
  List<TranscriptBlock> blocks,
  Map<Object?, Object?> source,
  int idBase,
) {
  final content = source['content'];
  final text = content is String
      ? content
      : content is List
      ? content
            .whereType<Map>()
            .where((part) => part['type'] == 'text' && part['text'] is String)
            .map((part) => part['text'] as String)
            .join()
      : '';
  blocks.add(
    TranscriptBlock(
      kind: TranscriptBlockKind.tool,
      id: '$idBase:0',
      text: text,
      toolName: source['toolName'] is String ? source['toolName'] as String : null,
      toolResult: source,
      isError: source['isError'] == true,
    ),
  );
}
