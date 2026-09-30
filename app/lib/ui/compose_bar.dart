/// The compose bar: send a `prompt` to the open session, or abort it.
///
/// Presentational: it owns only the draft text and reports the two intents.
/// Other allowlisted commands have no UI yet. A send that fails (not connected,
/// timed out, hub-refused) surfaces through a snackbar rather than vanishing.
library;

import 'package:flutter/material.dart';

import '../client/hub_client.dart';

class ComposeBar extends StatefulWidget {
  const ComposeBar({
    super.key,
    required this.onSend,
    required this.onAbort,
    this.enabled = true,
  });

  final Future<CommandResult> Function(String text) onSend;
  final VoidCallback onAbort;
  final bool enabled;

  @override
  State<ComposeBar> createState() => _ComposeBarState();
}

class _ComposeBarState extends State<ComposeBar> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    final result = await widget.onSend(text);
    if (!mounted || result.ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.error ?? 'the hub refused that command')),
    );
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
                controller: _controller,
                enabled: widget.enabled,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
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
              icon: const Icon(Icons.send),
              tooltip: 'Send',
            ),
          ],
        ),
      ),
    );
  }
}
