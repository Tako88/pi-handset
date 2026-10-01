/// The `/` command suggestion rule and the floating panel that renders it.
///
/// [suggestionsFor] is the whole trigger rule, kept pure so it can be tested
/// without a widget binding: a leading `/`, no whitespace, and a
/// case-insensitive prefix match. [CommandSuggestionPanel] is dumb — the shell
/// owns the draft and the per-session cache, and handles a pick.
library;

import 'package:flutter/material.dart';

import '../client/hub_client.dart';

/// The commands matching [draft]: those whose [SlashCommand.name] starts with the
/// text after a leading `/`, case-insensitively.
///
/// Empty when there are no commands, when [draft] does not start with `/`, or
/// when it contains whitespace (a command being typed is a single token, and a
/// space means the user has moved on to arguments). The bare `/` matches every
/// command, in pi's order — this function never re-sorts.
List<SlashCommand> suggestionsFor(List<SlashCommand> commands, String draft) {
  if (commands.isEmpty) return const [];
  if (!draft.startsWith('/')) return const [];
  if (RegExp(r'\s').hasMatch(draft)) return const [];
  final prefix = draft.substring(1).toLowerCase();
  if (prefix.isEmpty) return List.of(commands);
  return commands
      .where((command) => command.name.toLowerCase().startsWith(prefix))
      .toList();
}

/// The floating list of matching commands.
///
/// Opaque on purpose: it overlays the transcript, so a bare list would be
/// unreadable over scrolling text. It is capped to [maxHeight] and scrolls when
/// the matches do not fit.
class CommandSuggestionPanel extends StatelessWidget {
  const CommandSuggestionPanel({
    super.key,
    required this.commands,
    required this.maxHeight,
    required this.onPick,
  });

  final List<SlashCommand> commands;
  final double maxHeight;

  /// Called with the bare name (no slash, no trailing space); the shell owns the
  /// text field and decides how to insert it.
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const Key('compose-suggestions'),
      elevation: 8,
      child: Semantics(
        container: true,
        label: 'Slash commands',
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: ListView.builder(
            // The panel sits over the transcript rather than claiming a Column
            // slot, so it must size to its rows (up to the cap) instead of
            // expanding to fill the Stack.
            shrinkWrap: true,
            itemCount: commands.length,
            itemBuilder: (context, index) {
              final command = commands[index];
              final description = command.description;
              return ListTile(
                key: Key('compose-suggestion-$index-${command.name}'),
                dense: true,
                title: Text(
                  '/${command.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: description == null
                    ? null
                    : Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                onTap: () => onPick(command.name),
              );
            },
          ),
        ),
      ),
    );
  }
}
