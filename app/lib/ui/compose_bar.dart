/// The compose bar: send a `prompt` to the open session, or abort it.
///
/// Presentational: the owner supplies the draft controller and focus node; the
/// bar renders them and reports the intents. A tap sends a `prompt`; a long
/// press sends a `followup`, which runs after the current turn instead of
/// joining it. Other allowlisted commands have no UI yet. A send that fails (not
/// connected, timed out, hub-refused) surfaces through a snackbar rather than
/// vanishing.
library;

import 'package:flutter/material.dart';

import '../client/attachment.dart';
import '../client/hub_client.dart';

class ComposeBar extends StatefulWidget {
  const ComposeBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onAbort,
    required this.onFollowUp,
    this.enabled = true,
    this.attachment,
    this.onAttach,
    this.onRemoveAttachment,
  });

  /// The draft. The owner supplies it because the shell must read the text to
  /// filter commands and must write a picked name back into the field.
  final TextEditingController controller;

  /// The field's focus. The owner holds it so a command pick can return focus to
  /// the field.
  final FocusNode focusNode;
  final Future<CommandResult> Function(String text) onSend;
  final VoidCallback onAbort;

  /// Send the draft so it runs *after* the current turn instead of joining it.
  /// Required rather than optional: an omitted handler would leave the gesture
  /// inert, which reads as a broken button rather than a degraded mode.
  final Future<CommandResult> Function(String text) onFollowUp;
  final bool enabled;

  /// The image picked for this send, or null for no chip.
  final PickedImage? attachment;

  /// Opens the gallery. Optional: an old hub advertises no attachments
  /// capability, so the shell passes null and no attach button renders — the
  /// capability gate.
  final VoidCallback? onAttach;

  /// Removes the picked image. Null disables the remove button.
  final VoidCallback? onRemoveAttachment;

  @override
  State<ComposeBar> createState() => _ComposeBarState();
}

class _ComposeBarState extends State<ComposeBar> {
  Future<void> _send() => _submit(widget.onSend, followUp: false);

  Future<void> _followUp() => _submit(widget.onFollowUp, followUp: true);

  Future<void> _submit(
    Future<CommandResult> Function(String text) send, {
    required bool followUp,
  }) async {
    final text = widget.controller.text.trim();
    if (text.isEmpty) {
      // The bridge refuses an empty `text`, so an image alone cannot be sent.
      // Say why rather than leaving a dead tap.
      if (widget.attachment != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Add a caption to send the image')),
        );
      }
      return;
    }
    widget.controller.clear();
    final result = await send(text);
    if (!mounted) return;
    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error ?? 'the hub refused that command')),
      );
      return;
    }
    if (followUp) {
      // The app knows it sent a `followup`; whether pi queues it or runs it now
      // is pi's call — an idle agent ignores the mode. Claim the send, not the
      // timing.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sent as a follow-up')),
      );
      return;
    }
    if (result.queued == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Queued for the running turn')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.attachment != null)
              Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  key: const Key('compose-attachment'),
                  height: 48,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: SizedBox(
                          width: 40,
                          height: 40,
                          child: Image.memory(
                            widget.attachment!.bytes,
                            cacheWidth: 80,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stack) =>
                                const Icon(Icons.broken_image),
                          ),
                        ),
                      ),
                      IconButton(
                        key: const Key('compose-attachment-remove'),
                        onPressed: widget.enabled
                            ? widget.onRemoveAttachment
                            : null,
                        icon: const Icon(Icons.close),
                        tooltip: 'Remove image',
                      ),
                    ],
                  ),
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('compose-field'),
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    enabled: widget.enabled,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: 'Message pi',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: widget.onAttach == null
                          ? null
                          : IconButton(
                              key: const Key('compose-attach'),
                              onPressed:
                                  widget.enabled ? widget.onAttach : null,
                              icon: const Icon(Icons.add_photo_alternate_outlined),
                              tooltip: 'Attach an image',
                            ),
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('compose-abort'),
                  onPressed: widget.enabled ? widget.onAbort : null,
                  icon: const Icon(Icons.stop_circle_outlined),
                  tooltip: 'Abort',
                ),
                IconButton(
                  key: const Key('compose-send'),
                  onPressed: widget.enabled ? _send : null,
                  onLongPress: widget.enabled ? _followUp : null,
                  icon: const Icon(Icons.send),
                  tooltip: 'Send (long-press to run after this turn)',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
