/// The transcript route's body: the transcript (with the status banner and the
/// floating command suggestions over it), the status indicator, and the compose
/// bar.
///
/// Presentational: the shell injects the composer's controller and focus node
/// and every intent. The `ValueListenableBuilder` and the suggestion overlay's
/// `LayoutBuilder` live here, so typing still rebuilds only the suggestion panel
/// and never the transcript.
library;

import 'dart:math';

import 'package:flutter/material.dart';

import '../client/attachment.dart';
import '../client/hub_models.dart';
import '../client/transcript.dart';
import 'command_suggestions.dart';
import 'compose_bar.dart';
import 'status_banner.dart';
import 'status_indicator.dart';
import 'transcript_view.dart';

class TranscriptComposer extends StatelessWidget {
  const TranscriptComposer({
    super.key,
    required this.activeId,
    required this.transcript,
    required this.search,
    this.error,
    this.dismissedError,
    required this.connected,
    required this.onDismissError,
    required this.commands,
    required this.controller,
    required this.focusNode,
    required this.enabled,
    this.attachment,
    required this.attachmentsEnabled,
    required this.onPickCommand,
    this.onAttach,
    required this.onRemoveAttachment,
    required this.onSend,
    required this.onAbort,
    required this.onFollowUp,
    required this.onLoadOlder,
  });

  /// The active session's id, keying the transcript view so a new session is a
  /// new view.
  final String activeId;

  /// The active session's transcript.
  final SessionTranscript transcript;

  /// The find-in-transcript state: which rows match and which one is current.
  final TranscriptSearch search;

  /// The client's most recent error, shown in the banner.
  final String? error;

  /// The last error the user dismissed, so the banner does not re-show it.
  final String? dismissedError;

  /// Whether the hub is connected; false shows the banner's reconnect row.
  final bool connected;

  /// Dismisses the banner's error.
  final VoidCallback onDismissError;

  /// The active session's command list, raw: the panel slices it per keystroke.
  final List<SlashCommand> commands;

  /// The composer draft. Injected, never re-created here.
  final TextEditingController controller;

  /// The composer field's focus. Injected, never re-created here.
  final FocusNode focusNode;

  /// Whether the composer accepts input (the hub is connected).
  final bool enabled;

  /// The image picked for the next send, or null. Gated by
  /// [attachmentsEnabled].
  final PickedImage? attachment;

  /// Whether the hub advertises the attachments capability.
  final bool attachmentsEnabled;

  /// Writes a picked command name into the draft.
  final ValueChanged<String> onPickCommand;

  /// Opens the gallery. Gated by [attachmentsEnabled].
  final VoidCallback? onAttach;

  /// Removes the picked image.
  final VoidCallback onRemoveAttachment;

  final Future<CommandResult> Function(String text) onSend;
  final VoidCallback onAbort;
  final Future<CommandResult> Function(String text) onFollowUp;

  /// Loads one older page into the transcript.
  final VoidCallback onLoadOlder;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => Stack(
              children: [
                StatusBanner(
                  error: error,
                  dismissedError: dismissedError,
                  connected: connected,
                  onDismiss: onDismissError,
                  // Keyed on the session: a new session is a new view, so its
                  // scroll position and following state are not inherited from
                  // the last one.
                  child: TranscriptView(
                    key: ValueKey(activeId),
                    transcript: transcript,
                    onLoadOlder: onLoadOlder,
                    search: search,
                  ),
                ),
                // The suggestions float over the transcript instead of taking
                // a Column slot, so there is no `Flex` here to overflow. The
                // real safety is the `min(200, ...)` cap: an oversized
                // `Positioned` would be hard-clipped, not resized.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  // Inside the `Positioned`, so typing rebuilds only the
                  // panel — never the transcript.
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, value, _) {
                      final suggestions = suggestionsFor(commands, value.text);
                      if (suggestions.isEmpty) {
                        return const SizedBox.shrink();
                      }
                      return CommandSuggestionPanel(
                        commands: suggestions,
                        maxHeight: min(200, constraints.maxHeight),
                        onPick: onPickCommand,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        StatusIndicator(transcript: transcript),
        ComposeBar(
          controller: controller,
          focusNode: focusNode,
          enabled: enabled,
          thinkingLevel: transcript.thinkingLevel,
          attachment: attachmentsEnabled ? attachment : null,
          onAttach: attachmentsEnabled ? onAttach : null,
          onRemoveAttachment: onRemoveAttachment,
          onSend: onSend,
          onAbort: onAbort,
          onFollowUp: onFollowUp,
        ),
      ],
    );
  }
}
