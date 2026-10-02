/// The transcript app bar's overflow menu: compact, rename, thinking level and
/// model.
///
/// The menu is the reachable path to four commands the bridge already
/// implements and both allowlists already permit; the pieces of state it
/// displays from the hub are the active thinking level and the current model,
/// both of which ride the existing `usage` event payload.
library;

import 'package:flutter/material.dart';
import 'package:pi_droid/client/hub_client.dart';

/// pi's canonical thinking levels.
///
/// Hardcoded deliberately: `getAvailableThinkingLevels()` lives on pi's
/// internal `AgentSession` only, and the extension surface exposes just
/// `getThinkingLevel()`/`setThinkingLevel()`, so the app cannot ask which
/// levels the current model supports. The list is pi's full set
/// (`pi-agent-core/dist/types.d.ts`: `"off" | "minimal" | "low" | "medium" |
/// "high" | "xhigh" | "max"`). `pi.setThinkingLevel` clamps an unsupported
/// level, and the next `usage` event reports the clamped value, so picking a
/// level the model does not support simply shows the value snap back.
const List<String> thinkingLevels = [
  'off',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
];

/// The ⋮ action for the transcript app bar.
class SessionMenuButton extends StatelessWidget {
  const SessionMenuButton({
    super.key,
    required this.thinkingLevel,
    required this.model,
    required this.onCompact,
    required this.onRename,
    required this.onThinkingLevel,
    required this.onModel,
  });

  /// The level pi currently reports, or null when no `usage` event has arrived
  /// (or an older bridge omits the field).
  final String? thinkingLevel;

  /// The name of the model pi currently reports, or null when no `usage` event
  /// has arrived (or an older bridge omits the field).
  final String? model;

  final VoidCallback onCompact;
  final VoidCallback onRename;
  final VoidCallback onThinkingLevel;
  final VoidCallback onModel;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      key: const Key('session-menu'),
      icon: const Icon(Icons.more_vert),
      tooltip: 'Session menu',
      onSelected: (value) {
        switch (value) {
          case 'compact':
            onCompact();
          case 'rename':
            onRename();
          case 'thinking':
            onThinkingLevel();
          case 'model':
            onModel();
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem<String>(
          key: Key('session-menu-compact'),
          value: 'compact',
          child: Text('Compact'),
        ),
        const PopupMenuItem<String>(
          key: Key('session-menu-rename'),
          value: 'rename',
          child: Text('Rename'),
        ),
        PopupMenuItem<String>(
          key: const Key('session-menu-thinking'),
          value: 'thinking',
          child: Row(
            children: [
              // Flexible so the label yields to the value and the item can never
              // overflow its allotted width.
              const Expanded(
                child: Text('Thinking level', overflow: TextOverflow.ellipsis),
              ),
              if (thinkingLevel != null) ...[
                const SizedBox(width: 8),
                Text(
                  thinkingLevel!,
                  key: const Key('session-menu-thinking-level'),
                ),
              ],
            ],
          ),
        ),
        PopupMenuItem<String>(
          key: const Key('session-menu-model'),
          value: 'model',
          child: Row(
            children: [
              const Expanded(
                child: Text('Model', overflow: TextOverflow.ellipsis),
              ),
              if (model != null)
                // Flexible so the value ellipsizes rather than overflowing the
                // popup — the same class of bug the thinking item hit.
                Flexible(
                  child: Text(
                    model!,
                    key: const Key('session-menu-model-name'),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Asks before compacting. Returns false on cancel or dismissal.
Future<bool> confirmCompact(BuildContext context) async {
  final decision = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const Key('compact-confirm'),
      title: const Text('Compact session?'),
      content: const Text(
        'pi will summarize this session and drop older history. '
        'This cannot be undone, and a running turn is interrupted.',
      ),
      actions: [
        TextButton(
          key: const Key('compact-confirm-no'),
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('compact-confirm-yes'),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Compact'),
        ),
      ],
    ),
  );
  return decision ?? false;
}

/// Prompts for a new session name, prefilled with [current]. Returns the
/// trimmed name, or null if cancelled or empty.
Future<String?> promptRename(BuildContext context, String current) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => _RenameDialog(initial: current),
  );
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
    // Rebuild so the submit button tracks the trimmed value.
    _controller.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = _controller.text.trim();
    return AlertDialog(
      title: const Text('Rename session'),
      content: TextField(
        key: const Key('rename-field'),
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Session name'),
        onSubmitted: name.isEmpty ? null : (_) => Navigator.pop(context, name),
      ),
      actions: [
        TextButton(
          key: const Key('rename-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('rename-submit'),
          onPressed: name.isEmpty ? null : () => Navigator.pop(context, name),
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

/// Shows the thinking-level picker, marking [current]. Returns the tapped
/// level, or null if dismissed.
///
/// The list scrolls: `shrinkWrap` sizes it to its content but the sheet's own
/// maximum height clamps it, which is what keeps the seven rows usable at a
/// large text scale instead of overflowing the sheet.
Future<String?> pickThinkingLevel(BuildContext context, String? current) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        key: const Key('thinking-picker'),
        shrinkWrap: true,
        children: [
          for (final level in thinkingLevels)
            ListTile(
              key: Key('thinking-$level'),
              title: Text(level),
              trailing: level == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(sheetContext, level),
            ),
        ],
      ),
    ),
  );
}

/// Shows the model picker, marking [current]. Returns the tapped model, or null
/// if dismissed.
///
/// The list scrolls: `shrinkWrap` sizes it to its content but the sheet's own
/// maximum height clamps it, which keeps a long model list usable at a large
/// text scale instead of overflowing the sheet.
Future<ModelSummary?> pickModel(
  BuildContext context,
  List<ModelSummary> models,
  ModelSummary? current,
) {
  return showModalBottomSheet<ModelSummary>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        key: const Key('model-picker'),
        shrinkWrap: true,
        children: [
          for (final model in models)
            ListTile(
              key: Key('model-${model.provider}-${model.id}'),
              title: Text(model.name),
              subtitle: Text('${model.provider}/${model.id}'),
              trailing:
                  (model.provider == current?.provider && model.id == current?.id)
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.pop(sheetContext, model),
            ),
        ],
      ),
    ),
  );
}
