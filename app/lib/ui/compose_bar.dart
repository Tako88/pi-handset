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
    if (text.isEmpty) return;
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
        child: Row(
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
                decoration: const InputDecoration(
                  hintText: 'Message pi',
                  border: OutlineInputBorder(),
                  isDense: true,
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
      ),
    );
  }
}
