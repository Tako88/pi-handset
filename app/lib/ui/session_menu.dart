/// The transcript app bar's overflow menu: new, fork, mute, compact, rename,
/// thinking level and model.
///
/// The menu is the reachable path to commands the bridge already implements and
/// both allowlists already permit; the pieces of state it displays from the hub
/// are the active thinking level and the current model, both of which ride the
/// existing `usage` event payload. New and fork replace the session, which only
/// a hub advertising the `session-control` capability can do, so the shell
/// passes their callbacks as null without it and the items are omitted.
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
    required this.muted,
    required this.onCompact,
    required this.onRename,
    required this.onThinkingLevel,
    required this.onModel,
    required this.onToggleNotify,
    this.onNewSession,
    this.onFork,
  });

  /// The level pi currently reports, or null when no `usage` event has arrived
  /// (or an older bridge omits the field).
  final String? thinkingLevel;

  /// The name of the model pi currently reports, or null when no `usage` event
  /// has arrived (or an older bridge omits the field).
  final String? model;

  /// Whether the active session's notifications are muted. The item shows the
  /// action available, so this drives the `Mute`/`Unmute` label.
  final bool muted;

  final VoidCallback onCompact;
  final VoidCallback onRename;
  final VoidCallback onThinkingLevel;
  final VoidCallback onModel;

  /// Flips the active session's muted flag.
  final VoidCallback onToggleNotify;

  /// Replaces the session with a fresh one. Null (no `session-control`
  /// capability) hides the item.
  final VoidCallback? onNewSession;

  /// Replaces the session with a fork of it. Null hides the item.
  final VoidCallback? onFork;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      key: const Key('session-menu'),
      icon: const Icon(Icons.more_vert),
      tooltip: 'Session menu',
      onSelected: (value) {
        switch (value) {
          case 'new':
            onNewSession?.call();
          case 'fork':
            onFork?.call();
          case 'notify':
            onToggleNotify();
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
        if (onNewSession != null)
          const PopupMenuItem<String>(
            key: Key('session-menu-new'),
            value: 'new',
            child: Text('New session'),
          ),
        if (onFork != null)
          const PopupMenuItem<String>(
            key: Key('session-menu-fork'),
            value: 'fork',
            child: Text('Fork'),
          ),
        PopupMenuItem<String>(
          key: const Key('session-menu-notify'),
          value: 'notify',
          child: Text(muted ? 'Unmute' : 'Mute'),
        ),
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

/// Asks before replacing the session with a fresh one. Returns false on cancel
/// or dismissal.
Future<bool> confirmNewSession(BuildContext context) async {
  final decision = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const Key('new-session-confirm'),
      title: const Text('Start a new session?'),
      content: const Text(
        'pi will replace this session with a fresh one. The current '
        'conversation stays on disk but the transcript on screen is replaced.',
      ),
      actions: [
        TextButton(
          key: const Key('new-session-confirm-no'),
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('new-session-confirm-yes'),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('New session'),
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

/// The label shown for a tree node: its own label when pi set one, otherwise
/// the message text, with a placeholder so an empty message is still tappable
/// and distinguishable.
String _treeLabel(TreeNodeSummary node) {
  final label = node.label ?? node.text;
  return label.isEmpty ? '(empty message)' : label;
}

/// Depth of [node] inside [visible], following `parentId` chains. A parent that
/// is not in [visible] — filtered out, or a root — ends the walk, so an orphaned
/// parent reads as depth 0. The seen-guard bounds a malformed cycle rather than
/// looping forever; pi's tree cannot cycle.
int _treeDepth(TreeNodeSummary node, Map<String, TreeNodeSummary> visible) {
  var depth = 0;
  final seen = <String>{node.id};
  var parentId = node.parentId;
  while (parentId != null && seen.add(parentId)) {
    final parent = visible[parentId];
    if (parent == null) break;
    depth++;
    parentId = parent.parentId;
  }
  return depth;
}

/// Shows the session-tree picker, keeping only user nodes when [userOnly] is
/// set. Returns the tapped node, or null if dismissed.
///
/// [truncated] adds a note when older entries were dropped, so a capped list
/// never looks like the whole tree. The list scrolls under the sheet's height
/// (the thinking picker's pattern), so a long tree stays usable at a large text
/// scale.
Future<TreeNodeSummary?> pickTreeNode(
  BuildContext context,
  List<TreeNodeSummary> nodes, {
  required bool userOnly,
  bool truncated = false,
}) {
  final visible = userOnly
      ? [
          for (final node in nodes)
            if (node.role == 'user') node,
        ]
      : List<TreeNodeSummary>.of(nodes);
  final byId = {for (final node in visible) node.id: node};
  return showModalBottomSheet<TreeNodeSummary>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        key: const Key('tree-picker'),
        shrinkWrap: true,
        children: [
          if (truncated)
            const ListTile(
              key: Key('tree-picker-truncated'),
              title: Text('Older entries are hidden'),
            ),
          if (visible.isEmpty)
            const ListTile(
              key: Key('tree-picker-empty'),
              title: Text('No messages to fork from'),
            )
          else
            for (final node in visible)
              ListTile(
                key: Key('tree-node-${node.id}'),
                contentPadding: EdgeInsets.only(
                  left: 16 + 16.0 * _treeDepth(node, byId),
                  right: 16,
                ),
                title: Text(
                  _treeLabel(node),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(sheetContext, node),
              ),
        ],
      ),
    ),
  );
}

/// The models matching [query]: a case-insensitive substring match against the
/// [ModelSummary.name], [ModelSummary.provider] or [ModelSummary.id]. A blank
/// query returns every model, in order, as a copy (never the caller's list).
List<ModelSummary> modelsMatching(List<ModelSummary> models, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return List.of(models);
  return models
      .where(
        (m) =>
            m.name.toLowerCase().contains(needle) ||
            m.provider.toLowerCase().contains(needle) ||
            m.id.toLowerCase().contains(needle),
      )
      .toList();
}

/// Shows the model picker with a live search field, marking [current]. Returns
/// the tapped model, or null if dismissed.
///
/// The field filters the list as you type; the list scrolls under the sheet's
/// height, so a long model list stays usable at a large text scale. The
/// keyboard is avoided by explicit `viewInsets` padding (the framework does not
/// inset sheet content), and the field is deliberately not autofocused so
/// opening the sheet does not summon the keyboard.
Future<ModelSummary?> pickModel(
  BuildContext context,
  List<ModelSummary> models,
  ModelSummary? current,
) {
  return showModalBottomSheet<ModelSummary>(
    context: context,
    // Keep the sheet clear of the status bar and any notch. Without this the
    // route strips the top padding from the sheet's MediaQuery, so a sheet tall
    // enough to reach the top (a long model list) puts the field at y=0.
    useSafeArea: true,
    // Full height, so the sheet can grow. NOTE: `isScrollControlled` gives
    // height, NOT keyboard avoidance — the framework does not add viewInsets
    // padding to sheet content (see bottom_sheet.dart). `_ModelPicker` adds
    // that padding explicitly.
    isScrollControlled: true,
    builder: (sheetContext) => _ModelPicker(models: models, current: current),
  );
}

class _ModelPicker extends StatefulWidget {
  const _ModelPicker({required this.models, required this.current});
  final List<ModelSummary> models;
  final ModelSummary? current;
  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matches = modelsMatching(widget.models, _query.text);
    return SafeArea(
      // Explicit keyboard avoidance: the framework does not inset sheet
      // content, so reserve the keyboard height ourselves or the field and the
      // filtered rows sit under the keyboard. Inert when viewInsets is zero.
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: TextField(
                key: const Key('model-search'),
                controller: _query,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search models',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            // Flexible + shrinkWrap: bounded by the sheet, so the list scrolls
            // when the matches are tall and the sheet stays short when they are
            // not. Expanded would force the sheet to full height for one row.
            Flexible(
              child: ListView(
                key: const Key('model-picker'),
                shrinkWrap: true,
                children: [
                  if (matches.isEmpty)
                    const ListTile(
                      key: Key('model-picker-empty'),
                      title: Text('No models match'),
                    )
                  else
                    for (final model in matches)
                      ListTile(
                        key: Key('model-${model.provider}-${model.id}'),
                        title: Text(model.name),
                        subtitle: Text('${model.provider}/${model.id}'),
                        trailing:
                            (model.provider == widget.current?.provider &&
                                    model.id == widget.current?.id)
                                ? const Icon(Icons.check)
                                : null,
                        onTap: () => Navigator.pop(context, model),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
