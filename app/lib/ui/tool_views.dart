/// Per-kind renderers for the bridge's normalized tool payloads.
///
/// [ToolViewBody] dispatches on the sealed [ToolView] to one body per kind. The
/// collapsed state caps a body to `toolResultPreviewLines` and shows a
/// `… (N more lines)` marker, matching the generic tool preview; a view the
/// bridge itself bounded ([ToolView.truncated]) carries an explicit marker so a
/// partial payload never masquerades as whole.
///
/// Pure presentation: everything here reads a parsed [ToolView]. Parsing and the
/// version-skew fallback live in `client/tool_view.dart`.
library;

import 'package:flutter/material.dart';

import '../client/tool_view.dart';
import '../client/transcript.dart';

/// The row body for a parsed [ToolView]. [text] is the raw result text, used
/// only by the generic fallback body.
class ToolViewBody extends StatelessWidget {
  const ToolViewBody({
    super.key,
    required this.view,
    required this.expanded,
    required this.text,
    this.isError = false,
  });

  final ToolView view;
  final bool expanded;
  final String text;
  final bool isError;

  /// Shown when the bridge bounded the view to its byte budget.
  static const String truncationMarker = '[view truncated]';

  @override
  Widget build(BuildContext context) {
    final Widget body = switch (view) {
      DiffView v => DiffBody(view: v, expanded: expanded),
      FileView v => FileBody(view: v, expanded: expanded),
      CommandView v => CommandBody(view: v, expanded: expanded),
      MatchesView v => MatchesBody(view: v, expanded: expanded),
      TableView v => TableBody(view: v, expanded: expanded),
      GenericView() => GenericToolBody(
        text: text,
        expanded: expanded,
        isError: isError,
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        body,
        if (view.truncated)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              truncationMarker,
              style: TextStyle(
                color: Theme.of(context).colorScheme.outline,
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
      ],
    );
  }
}

/// The generic fallback: the capped (or full, when expanded) result text. Shared
/// by [ToolViewBody]'s generic case and a null view in `ToolBlock`, so both
/// paths render identically.
class GenericToolBody extends StatelessWidget {
  const GenericToolBody({
    super.key,
    required this.text,
    required this.expanded,
    this.isError = false,
  });

  final String text;
  final bool expanded;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final preview = previewToolResult(text);
    final body = expanded ? text : preview.shown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (body.isNotEmpty)
          Text(
            body,
            style: TextStyle(
              fontFamily: 'monospace',
              color: isError ? colors.onErrorContainer : colors.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        if (!expanded && preview.isTruncated)
          Text(
            '… (${preview.hiddenLines} more lines)',
            style: TextStyle(color: colors.outline, fontSize: 12),
          ),
      ],
    );
  }
}

/// A unified diff (`edit`) or all-addition body (`write`).
class DiffBody extends StatelessWidget {
  const DiffBody({super.key, required this.view, required this.expanded});

  final DiffView view;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final lines = _visible(view.lines, expanded).map((line) {
      final background = line.isAdd
          ? colors.primaryContainer
          : line.isDel
          ? colors.errorContainer
          : null;
      final prefix = line.isAdd ? '+' : line.isDel ? '-' : ' ';
      return Container(
        width: double.infinity,
        color: background,
        child: Text(
          '$prefix ${line.text}',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      );
    }).toList();
    return _CappedLines(
      lines: lines,
      totalLines: view.lines.length,
      expanded: expanded,
    );
  }
}

/// A file's text body (`read`).
class FileBody extends StatelessWidget {
  const FileBody({super.key, required this.view, required this.expanded});

  final FileView view;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final all = view.content.split('\n');
    final lines = _visible(all, expanded)
        .map(
          (line) =>
              Text(line, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        )
        .toList();
    return _CappedLines(
      lines: lines,
      totalLines: all.length,
      expanded: expanded,
    );
  }
}

/// A shell command and its merged output (`bash`).
class CommandBody extends StatelessWidget {
  const CommandBody({super.key, required this.view, required this.expanded});

  final CommandView view;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final all = view.output.split('\n');
    final outputLines = _visible(all, expanded)
        .map(
          (line) =>
              Text(line, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '\$ ${view.command}',
          style: TextStyle(
            fontFamily: 'monospace',
            fontWeight: FontWeight.w600,
            fontSize: 12,
            color: colors.onSurface,
          ),
        ),
        _CappedLines(
          lines: outputLines,
          totalLines: all.length,
          expanded: expanded,
        ),
      ],
    );
  }
}

/// Search hits grouped by file. A `find` file match is path-only (line 0, empty
/// text) and renders the path without inventing `:0`.
class MatchesBody extends StatelessWidget {
  const MatchesBody({super.key, required this.view, required this.expanded});

  final MatchesView view;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    if (view.matches.isEmpty) return const Text('no matches');
    final colors = Theme.of(context).colorScheme;
    final grouped = <String, List<Match>>{};
    for (final match in view.matches) {
      grouped.putIfAbsent(match.file, () => []).add(match);
    }
    final all = <({String text, bool header})>[];
    grouped.forEach((file, matches) {
      all.add((text: file, header: true));
      for (final match in matches) {
        if (match.isPathOnly) continue;
        all.add((text: '${match.line}: ${match.text}', header: false));
      }
    });
    final rows = _visible(all, expanded)
        .map(
          (row) => Text(
            row.text,
            style: row.header
                ? TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    color: colors.onSurface,
                  )
                : const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        )
        .toList();
    return _CappedLines(
      lines: rows,
      totalLines: all.length,
      expanded: expanded,
    );
  }
}

/// A tabular result (`ls`).
class TableBody extends StatelessWidget {
  const TableBody({super.key, required this.view, required this.expanded});

  final TableView view;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    if (view.rows.isEmpty) return const Text('empty directory');
    final colors = Theme.of(context).colorScheme;
    final all = <({String text, bool header})>[
      (text: view.columns.join('  '), header: true),
      for (final row in view.rows) (text: row.join('  '), header: false),
    ];
    final rows = _visible(all, expanded)
        .map(
          (row) => Text(
            row.text,
            style: row.header
                ? TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    color: colors.onSurface,
                  )
                : const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        )
        .toList();
    return _CappedLines(
      lines: rows,
      totalLines: all.length,
      expanded: expanded,
    );
  }
}

/// The prefix of [items] a collapsed body renders: the cap, or everything when
/// expanded. Bodies map this lazily, so the discarded rows never become widgets.
Iterable<T> _visible<T>(List<T> items, bool expanded) =>
    expanded ? items : items.take(toolResultPreviewLines);

/// Renders [lines] (already capped by the caller when collapsed) plus a
/// hidden-line marker when [totalLines] exceeds the cap. It never receives the
/// discarded widgets, so a large collapsed view builds only its visible rows.
class _CappedLines extends StatelessWidget {
  const _CappedLines({
    required this.lines,
    required this.totalLines,
    required this.expanded,
  });

  final List<Widget> lines;
  final int totalLines;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    if (expanded || totalLines <= toolResultPreviewLines) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines);
    }
    final hidden = totalLines - toolResultPreviewLines;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...lines,
        Text(
          '… ($hidden more lines)',
          style: TextStyle(
            color: Theme.of(context).colorScheme.outline,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
