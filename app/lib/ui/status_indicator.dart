/// The live status indicator shown above the compose bar.
///
/// [statusLabel] is pure: it reads only the transcript's running/thinking/
/// streaming state, so it tests without a widget binding. The distinction that
/// matters is the *precise* one: `Thinking…` appears only when the bridge
/// actually signalled the phase, never as a guess for a slow first token.
library;

import 'package:flutter/material.dart';

import '../client/hub_client.dart';

/// The label for [transcript], or null when no turn is running.
String? statusLabel(SessionTranscript transcript) {
  if (transcript.agentState != 'running') return null;
  if (transcript.streamingText.isNotEmpty) return 'Responding…';
  if (transcript.thinking) return 'Thinking…';
  return 'Working…';
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
