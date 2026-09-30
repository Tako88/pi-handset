/// The transcript view — the B0 mitigation made concrete.
///
/// A streaming message renders as cheap plain `Text` (it is rebuilt on every
/// coalesced frame); a completed message renders through `MarkdownBody`. Every
/// message is wrapped in a `RepaintBoundary` so a streamed frame repaints only
/// the streaming bubble, and the list is a lazy `ListView.builder` so a frame
/// never touches (or re-parses) rows that are off-screen.
///
/// Presentational: it renders a snapshot of the client's [SessionTranscript].
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../client/hub_client.dart';

class TranscriptView extends StatelessWidget {
  const TranscriptView({super.key, required this.transcript});

  final SessionTranscript transcript;

  static const String emptyMessage = 'No messages yet.';

  /// The streaming bubble's key. Stable across frames so its element and
  /// repaint boundary are reused while deltas accumulate.
  static const Key streamingKey = ValueKey('transcript-streaming');

  @override
  Widget build(BuildContext context) {
    final entries = transcript.entries;
    final streaming = transcript.streaming && transcript.streamingText.isNotEmpty;
    final itemCount = entries.length + (streaming ? 1 : 0);
    if (itemCount == 0) {
      return const Center(child: Text(TranscriptView.emptyMessage));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index >= entries.length) {
          return _bubble(
            TranscriptView.streamingKey,
            transcript.streamingText,
            completed: false,
          );
        }
        final entry = entries[index];
        final text = entryText(entry);
        // Status/tool payloads with no displayable text take no row.
        if (text == null) return const SizedBox.shrink();
        // Keyed by entry identity, not position: a prepend or a truncation must
        // not shift every key and throw away element/repaint state.
        return _bubble(ObjectKey(entry), text, completed: true);
      },
    );
  }

  Widget _bubble(Key key, String text, {required bool completed}) =>
      RepaintBoundary(
        key: key,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: MessageBubble(text: text, completed: completed),
        ),
      );
}

/// One message. Plain `Text` until [completed], then markdown.
class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.text, required this.completed});

  final String text;
  final bool completed;

  @override
  Widget build(BuildContext context) =>
      completed ? MarkdownBody(data: text) : Text(text);
}

/// Extracts the displayable text of one raw transcript entry, or null when the
/// entry carries none.
///
/// Two shapes exist on the wire: history/snapshot entries
/// (`{type: 'user'|'assistant', text}`) and relayed assistant messages
/// (`{role, content: [{type: 'text', text}]}`). Status payloads carry a
/// user-visible `message`. Tool payloads are not rendered yet.
String? entryText(Object? entry) {
  if (entry is! Map) return null;
  final type = entry['type'];
  if ((type == 'user' || type == 'assistant') && entry['text'] is String) {
    return entry['text'] as String;
  }
  if (entry['role'] is String) {
    final content = entry['content'];
    if (content is String) return content;
    if (content is List) {
      final buffer = StringBuffer();
      for (final part in content) {
        if (part is Map && part['type'] == 'text' && part['text'] is String) {
          buffer.write(part['text']);
        }
      }
      if (buffer.isNotEmpty) return buffer.toString();
    }
  }
  if (entry['kind'] == 'status' && entry['message'] is String) {
    return entry['message'] as String;
  }
  return null;
}
