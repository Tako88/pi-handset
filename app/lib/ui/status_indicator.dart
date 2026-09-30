/// The live status indicator shown above the compose bar.
///
/// [statusLabel] is pure: it reads only the transcript's running/thinking/
/// streaming state, so it tests without a widget binding. The distinction that
/// matters is the *precise* one: `Thinking…` appears only when the bridge
/// actually signalled the phase, never as a guess for a slow first token.
library;

import 'package:flutter/material.dart';

import '../client/hub_client.dart';
import '../client/transcript.dart';

/// The label for [transcript], or null when no turn is running.
String? statusLabel(SessionTranscript transcript) {
  if (transcript.agentState != 'running') return null;
  final tool = _pendingToolName(transcript.blocks);
  if (tool != null) return 'Running $tool…';
  if (transcript.streamingText.isNotEmpty) return 'Responding…';
  if (transcript.thinking) return 'Thinking…';
  return 'Working…';
}

/// The name of the trailing tool block while it has no result, else null. A
/// tool call arrives with the assistant message before the tool runs, so an
/// unresolved *trailing* tool block is the precise "a tool is running" signal.
/// Only the trailing block counts: a tool followed by a notice or by continued
/// text was abandoned or has already returned its result, and scanning further
/// back would let a stale tool poison the label for the rest of the turn.
String? _pendingToolName(List<TranscriptBlock> blocks) {
  if (blocks.isEmpty) return null;
  final last = blocks.last;
  if (last.kind != TranscriptBlockKind.tool) return null;
  return last.toolResult == null ? (last.toolName ?? 'tool') : null;
}

/// Renders [statusLabel] for the active transcript, or nothing when idle.
class StatusIndicator extends StatelessWidget {
  const StatusIndicator({super.key, required this.transcript});

  final SessionTranscript transcript;

  @override
  Widget build(BuildContext context) {
    final label = statusLabel(transcript);
    if (label == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(label, key: const Key('status-label')),
        ],
      ),
    );
  }
}
