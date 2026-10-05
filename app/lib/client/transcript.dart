/// The transcript block model — one ordered list of blocks derived from the raw
/// relayed entries.
///
/// Pure Dart: no Flutter import, so it tests without a widget binding. The live
/// relay appends through a per-session [TranscriptDerivation]; [deriveBlocks]
/// stays the whole-list entry point a reconnect snapshot, a test or any cold
/// caller uses. Both share one emission path, and the two paths carry the same
/// pi *message* shape in different *entry* shapes:
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
/// entries — call it when entries change, never per stream delta. It is the
/// whole-list entry point: the live relay goes through [TranscriptDerivation]
/// and this is what a snapshot, a test or any cold caller uses.
List<TranscriptBlock> deriveBlocks(List<Object?> entries) {
  final derivation = TranscriptDerivation()..rebuild(entries);
  return List<TranscriptBlock>.of(derivation.blocks);
}

/// One session's incremental block derivation.
///
/// [deriveBlocks] stays the pure, whole-list entry point; this is its stateful
/// twin. It owns the entry list, the pass-1 indexes, the emitted block list and
/// one anchor per tool row, so [append] extends the derivation by one entry
/// instead of re-walking the transcript. [rebuild] is the cold path — a
/// snapshot, a session replacement, or #5's prepend — and the only place the
/// whole list is walked.
///
/// Not part of the immutable [SessionTranscript]: the client owns one per live
/// session, keyed by session id, and drops it with the transcript. It never
/// hands these lists to a consumer — the transcript receives *copies*, so
/// nothing a retained snapshot exposes can change underneath it.
class TranscriptDerivation {
  final List<Object?> _entries = <Object?>[];
  final List<TranscriptBlock> _blocks = <TranscriptBlock>[];

  final Map<String, Map<Object?, Object?>> _resultsById = {};
  final Map<String, Object?> _viewsById = {};
  final Set<String> _callIds = {};
  final Map<String, int> _toolIdCounts = {};

  /// One anchor per emitted tool row, in emission order, keyed by call id.
  final Map<String, List<_ToolAnchor>> _anchors = {};

  /// Call ids whose result row was emitted standalone because no call had been
  /// seen. A later call for one of these would drop that row (pass 1 is
  /// first-wins by list order), so that append rebuilds instead.
  final Set<String> _orphanCallIds = {};

  /// Read-only by convention: only [append]/[rebuild] mutate, and the transcript
  /// gets copies — never these lists.
  List<Object?> get entries => _entries;
  List<TranscriptBlock> get blocks => _blocks;

  /// The whole-list baseline: replace the entries and re-derive every block.
  /// #5's prepend calls this with `[...older, ...entries]` (a fresh list — never
  /// `_entries` itself).
  void rebuild(List<Object?> entries) {
    // Snapshot before clearing: a caller passing this derivation's own
    // `entries` list would otherwise have it emptied by the `clear()` below
    // before the copy is taken (a cascade evaluates `addAll`'s argument after
    // `clear` runs).
    final source = List<Object?>.of(entries);
    _entries
      ..clear()
      ..addAll(source);
    _rebuildFromEntries();
  }

  /// The hot path: extend the derivation by one entry, O(1) plus the one row it
  /// may patch.
  void append(Object? entry) {
    _entries.add(entry);
    // A call for an id already emitted as a standalone orphan is retroactive
    // (the orphan row disappears and the result pairs into the new call row);
    // a paired result carrying decodable images inserts rows mid-list. Both
    // change the block count, and a patch is count-preserving, so both rebuild
    // — O(N) once on a rare shape, never per ordinary entry.
    if (_introducedCallIds(entry).any(_orphanCallIds.contains) ||
        _pairedResultHasImages(entry)) {
      _rebuildFromEntries();
      return;
    }
    _indexEntry(entry);
    _emitEntry(entry, incremental: true);
  }

  void _rebuildFromEntries() {
    _blocks.clear();
    _resultsById.clear();
    _viewsById.clear();
    _callIds.clear();
    _toolIdCounts.clear();
    _anchors.clear();
    _orphanCallIds.clear();
    for (final entry in _entries) {
      _indexEntry(entry);
    }
    for (final entry in _entries) {
      _emitEntry(entry, incremental: false);
    }
  }

  /// Pass 1 for one entry — identical rules to the whole-list index loop. A
  /// `kind:'tool'` frame's view is indexed **regardless of a truncated marker**,
  /// matching the whole-list pass-1 order.
  void _indexEntry(Object? entry) {
    if (entry is! Map) return;
    if (entry['kind'] == 'tool') {
      final callId = entry['toolCallId'];
      // Last-wins applies to present views only: a done frame may carry no
      // view, and clobbering the running frame's input-only view would drop
      // the structured render for the generic fallback.
      if (callId is String && entry['view'] != null) {
        _viewsById[callId] = entry['view'];
      }
      return;
    }
    final source = _unwrap(entry);
    if (source == null) return;
    final role = source['role'];
    if (role == 'toolResult') {
      // First-wins by list order: a resumed/forked branch can surface the same
      // call twice, and the call row must show the first result.
      final callId = source['toolCallId'];
      if (callId is String && !_resultsById.containsKey(callId)) {
        _resultsById[callId] = source;
      }
    } else if (role == 'assistant') {
      _collectToolCallIds(source['content'], _callIds);
    }
  }

  /// Pass 2 for one entry. [incremental] is false only during a rebuild, where
  /// the indexes are already whole-list and a paired result / view frame needs
  /// no patch — its target block was emitted with the final value.
  void _emitEntry(Object? entry, {required bool incremental}) {
    if (entry is! Map) return;
    final idBase = identityHashCode(entry);

    // A `kind:'tool'` frame is an annotation, never a row of its own. But the
    // whole-list pass indexes its view in pass 1 *before* the truncated check
    // below, so a frame carrying both a `view` and a `{truncated:true, bytes}`
    // marker gets its view attached AND emits the notice. Patch the view first,
    // then fall through to the notice, so the incremental path matches exactly.
    if (entry['kind'] == 'tool') {
      if (incremental) _patchAnchors(entry['toolCallId']);
      if (!(entry['truncated'] == true && entry['bytes'] is int)) return;
    }

    // A message the bridge could not relay whole: an honest notice, not a gap.
    if (entry['truncated'] == true && entry['bytes'] is int) {
      _blocks.add(
        TranscriptBlock(
          kind: TranscriptBlockKind.notice,
          id: '$idBase:0',
          text: 'reply too large to display (${entry['bytes']} bytes)',
        ),
      );
      return;
    }
    // A relayed status payload (e.g. an error) is a notice.
    if (entry['kind'] == 'status' && entry['message'] is String) {
      final message = entry['message'] as String;
      if (message.isEmpty) return;
      _blocks.add(
        TranscriptBlock(
          kind: TranscriptBlockKind.notice,
          id: '$idBase:0',
          text: message,
        ),
      );
      return;
    }

    // A summary pi wrote when it rewrote the context — a branch summary from
    // tree navigation, or a compaction. pi shows it as a notice rather than a
    // chat turn; without a row here the phone silently skips the point the
    // conversation was summarized, which reads as messages going missing.
    final summaryNotice = _summaryNoticeText(entry);
    if (summaryNotice != null) {
      _blocks.add(
        TranscriptBlock(
          kind: TranscriptBlockKind.notice,
          id: '$idBase:0',
          text: summaryNotice,
        ),
      );
      return;
    }

    final source = _unwrap(entry);
    if (source == null) {
      // The flattened fixture shape `{type: 'user'|'assistant', text}`.
      final type = entry['type'];
      if ((type == 'user' || type == 'assistant') && entry['text'] is String) {
        final text = entry['text'] as String;
        if (text.isEmpty) return;
        _blocks.add(
          TranscriptBlock(
            kind: TranscriptBlockKind.text,
            id: '$idBase:0',
            text: text,
            fromUser: type == 'user',
          ),
        );
      }
      return;
    }

    final role = source['role'];
    if (role == 'user') {
      _emitTextContent(_blocks, source['content'], idBase, fromUser: true);
    } else if (role == 'assistant') {
      _emitAssistantContent(
        _blocks,
        source['content'],
        idBase,
        _resultsById,
        _viewsById,
        _toolIdCounts,
        onToolBlock: (callId, part, toolId, index) => _recordAnchor(
          _ToolAnchor(
            callId: callId,
            callPart: part,
            toolId: toolId,
            index: index,
          ),
        ),
      );
    } else if (role == 'toolResult') {
      final callId = source['toolCallId'];
      // Paired: already rendered at its call in the assistant message.
      if (callId is String && _callIds.contains(callId)) {
        if (incremental) _patchAnchors(callId);
        return;
      }
      final index = _blocks.length;
      final toolId = _emitToolResult(
        _blocks,
        source,
        idBase,
        _viewsById,
        _toolIdCounts,
      );
      if (callId is String) {
        _recordAnchor(
          _ToolAnchor(
            callId: callId,
            resultSource: source,
            toolId: toolId,
            index: index,
          ),
        );
        // Both modes: a real orphan in either.
        _orphanCallIds.add(callId);
      }
    }
    // `system`, `custom` and bookkeeping roles take no block.
  }

  void _recordAnchor(_ToolAnchor anchor) =>
      (_anchors[anchor.callId] ??= <_ToolAnchor>[]).add(anchor);

  /// The call ids [entry] introduces (an assistant message's `toolCall`
  /// parts), for the orphan-pairing rebuild predicate.
  Set<String> _introducedCallIds(Object? entry) {
    final ids = <String>{};
    if (entry is! Map || entry['kind'] == 'tool') return ids;
    final source = _unwrap(entry);
    if (source != null && source['role'] == 'assistant') {
      _collectToolCallIds(source['content'], ids);
    }
    return ids;
  }

  /// True when [entry] is a paired result whose decodable image parts will
  /// insert rows mid-list, so [append] must rebuild (the patch is
  /// count-preserving). Note: this decodes the images once here and
  /// [_resultImageBlocks] decodes them again on the rebuild — deliberate. It
  /// runs only for a paired result that carries images (rare), and the rebuild
  /// it triggers is already O(N), so a memo would add state for no measurable
  /// gain. Revisit only against a profile.
  bool _pairedResultHasImages(Object? entry) {
    if (entry is! Map || entry['kind'] == 'tool') return false;
    final source = _unwrap(entry);
    if (source == null || source['role'] != 'toolResult') return false;
    final callId = source['toolCallId'];
    return callId is String &&
        _callIds.contains(callId) &&
        _resultImageBlocks(source, '').isNotEmpty;
  }

  void _patchAnchors(Object? rawCallId) {
    if (rawCallId is! String) return;
    final anchors = _anchors[rawCallId];
    if (anchors == null) return;
    for (final a in anchors) {
      // Patch in place; the index stays valid because any count-changing
      // append rebuilt instead (and rebuilt indices with it).
      _blocks[a.index] = a.callPart != null
          ? _callToolBlock(
              callId: a.callId,
              part: a.callPart!,
              toolId: a.toolId,
              resultsById: _resultsById,
              viewsById: _viewsById,
            )
          : _orphanToolBlock(
              source: a.resultSource!,
              callId: a.callId,
              toolId: a.toolId,
              viewsById: _viewsById,
            );
    }
  }
}

/// One emitted tool row: enough to re-emit it in place when its result or view
/// lands. Absolute [index] is safe because patches are count-preserving; any
/// count-changing append rebuilds.
class _ToolAnchor {
  final String callId;
  final Map<Object?, Object?>? callPart; // null => standalone result row
  final Map<Object?, Object?>? resultSource; // null => call row
  final String toolId; // preserves a fork's `#n` suffix
  final int index;

  const _ToolAnchor({
    required this.callId,
    this.callPart,
    this.resultSource,
    required this.toolId,
    required this.index,
  });
}

/// The tool row an assistant `toolCall` part contributes. Shared by emission and
/// in-place patching so the two cannot drift.
TranscriptBlock _callToolBlock({
  required String callId,
  required Map<Object?, Object?> part,
  required String toolId,
  required Map<String, Map<Object?, Object?>> resultsById,
  required Map<String, Object?> viewsById,
}) {
  final result = resultsById[callId];
  return TranscriptBlock(
    kind: TranscriptBlockKind.tool,
    id: toolId,
    toolName: part['name'] is String ? part['name'] as String : null,
    toolArgs: part['arguments'],
    text: result == null ? '' : _resultText(result),
    toolResult: result,
    toolView: parseToolView(viewsById[callId]),
    isError: result != null && result['isError'] == true,
  );
}

/// The standalone tool row a result with no call contributes.
TranscriptBlock _orphanToolBlock({
  required Map<Object?, Object?> source,
  required Object? callId,
  required String toolId,
  required Map<String, Object?> viewsById,
}) => TranscriptBlock(
  kind: TranscriptBlockKind.tool,
  id: toolId,
  text: _resultText(source),
  toolName: source['toolName'] is String ? source['toolName'] as String : null,
  toolResult: source,
  toolView: callId is String ? parseToolView(viewsById[callId]) : null,
  isError: source['isError'] == true,
);

/// The image rows for a result, built (not added) so the pairing predicate can
/// reuse the same decode logic without duplication. Emits one
/// [TranscriptBlockKind.image] block per decodable image part; ids are derived
/// from [toolId] so a fork's duplicate call still yields unique row keys.
List<TranscriptBlock> _resultImageBlocks(
  Map<Object?, Object?> source,
  String toolId,
) {
  final content = source['content'];
  if (content is! List) return const [];
  final images = <TranscriptBlock>[];
  var index = 0;
  for (final part in content) {
    if (part is! Map || part['type'] != 'image') continue;
    final bytes = _decodeImageBytes(part);
    if (bytes != null) {
      images.add(
        TranscriptBlock(
          kind: TranscriptBlockKind.image,
          id: '$toolId:img$index',
          imageBytes: bytes,
        ),
      );
    }
    index++;
  }
  return images;
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

/// The notice text for a summary entry — a `branch_summary` written when the
/// tree navigates away from a branch, or a `compaction`. Mirrors the collapsed
/// line pi prints. Null for anything else, and for a summary with no text,
/// which pi itself never renders.
String? _summaryNoticeText(Map<Object?, Object?> entry) {
  final summary = entry['summary'];
  if (summary is! String || summary.trim().isEmpty) return null;
  if (entry['type'] == 'branch_summary') return 'Branch summary';
  if (entry['type'] == 'compaction') {
    final tokens = entry['tokensBefore'];
    return tokens is int
        ? 'Compacted from $tokens tokens'
        : 'Compacted conversation';
  }
  return null;
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
  Map<String, int> toolIdCounts, {
  void Function(String callId, Map<Object?, Object?> part, String toolId, int index)?
  onToolBlock,
}) {
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
        // Capture the tool block's own id (which a fork may disambiguate) so
        // its image rows derive from it and stay unique too.
        final toolId = _toolBlockId(callId, toolIdCounts);
        final index = blocks.length;
        blocks.add(
          _callToolBlock(
            callId: callId,
            part: part,
            toolId: toolId,
            resultsById: resultsById,
            viewsById: viewsById,
          ),
        );
        // Record an anchor for EVERY call id, including a synthetic
        // '$idBase:$sub'. The whole-list path attaches a view for any id, so
        // gating the anchor on a String id would let a view frame whose
        // toolCallId equals the synthetic id patch the whole-list row but not
        // the incremental one. A synthetic id is never consumed by a result
        // (its result is always an orphan), so the anchor is inert unless such
        // a view frame exists — in which case recording it is exactly right.
        onToolBlock?.call(callId, part, toolId, index);
        final result = resultsById[callId];
        if (result != null) blocks.addAll(_resultImageBlocks(result, toolId));
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
/// but keep the result). Returns the tool block's id so the caller can anchor
/// it for a later view frame.
String _emitToolResult(
  List<TranscriptBlock> blocks,
  Map<Object?, Object?> source,
  int idBase,
  Map<String, Object?> viewsById,
  Map<String, int> toolIdCounts,
) {
  final callId = source['toolCallId'];
  final toolId = callId is String
      ? _toolBlockId(callId, toolIdCounts)
      : '$idBase:0';
  blocks.add(
    _orphanToolBlock(
      source: source,
      callId: callId,
      toolId: toolId,
      viewsById: viewsById,
    ),
  );
  blocks.addAll(_resultImageBlocks(source, toolId));
  return toolId;
}

/// The result's display text: the text parts joined on a newline, with an
/// `[image]` placeholder for an image part that did NOT render as a picture —
/// malformed/absent/non-string bytes, or the bridge's part-trimmed
/// `{truncated:true,bytes}` marker. A decodable image becomes its own image
/// block beside this row, so it is deliberately not repeated here as a label.
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
    } else if (type == 'image' && _decodeImageBytes(part) == null) {
      parts.add('[image]');
    }
  }
  return parts.join('\n');
}

/// The tool-argument text, uncapped. The header caps it for layout
/// (`argumentsLabel`); a copy must not.
String toolArgumentsText(Object? args) => args == null
    ? ''
    : args is String
    ? args
    : args is Map
    ? jsonEncode(args)
    : args.toString();

/// The exact text a Copy action puts on the clipboard for [block], or null
/// when the row has nothing to copy (an image).
String? copyTextForBlock(TranscriptBlock block) {
  switch (block.kind) {
    case TranscriptBlockKind.text:
    case TranscriptBlockKind.thinking:
    case TranscriptBlockKind.notice:
      return block.text;
    case TranscriptBlockKind.image:
      return null;
    case TranscriptBlockKind.tool:
      final view = block.toolView;
      final body = view is DiffView ? diffViewText(view) : block.text;
      final args = toolArgumentsText(block.toolArgs);
      return [
        block.toolName ?? 'tool',
        if (args.isNotEmpty) args,
        if (body.isNotEmpty) body,
        // A bounded diff is only part of the change: say so in the copy.
        if (view is DiffView && view.truncated) toolViewTruncationMarker,
      ].join('\n');
  }
}
