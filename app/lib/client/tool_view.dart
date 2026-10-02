/// The bridge's normalized per-tool render model, parsed into typed Dart.
///
/// Pure Dart: no Flutter import. [parseToolView] is the version-skew boundary —
/// a missing payload, a non-map, or a `type` this app does not know returns
/// null, and the renderer falls back to the generic preview rather than
/// dropping the block.
library;

/// The kind of a [DiffLine]: an addition, a removal, or unchanged context.
const String diffLineAdd = 'add';
const String diffLineDel = 'del';
const String diffLineCtx = 'ctx';

/// One line of a [DiffView]. A line whose kind is none of the three is treated
/// as context, so a future kind degrades to unhighlighted text.
class DiffLine {
  final String kind;
  final String text;

  const DiffLine(this.kind, this.text);

  bool get isAdd => kind == diffLineAdd;
  bool get isDel => kind == diffLineDel;
}

/// One search hit. A `find` file match arrives as `line: 0, text: ''`, so
/// [isPathOnly] is the renderer's cue to show the path, never `path:0`.
class Match {
  final String file;
  final int line;
  final String text;

  const Match({required this.file, required this.line, required this.text});

  bool get isPathOnly => line <= 0 && text.isEmpty;
}

/// A discriminated tool view. Sealed so a renderer switch is exhaustive.
sealed class ToolView {
  /// The bridge capped this view to its byte budget; the renderer shows an
  /// explicit marker rather than pretending the payload is whole.
  final bool truncated;

  const ToolView({this.truncated = false});
}

/// A unified diff (`edit`) or an all-addition file body (`write`).
class DiffView extends ToolView {
  final String path;
  final List<DiffLine> lines;

  const DiffView({required this.path, required this.lines, super.truncated});

  int get additions => lines.where((line) => line.isAdd).length;
  int get removals => lines.where((line) => line.isDel).length;
}

/// A file's text content, optionally a line range (`read`).
class FileView extends ToolView {
  final String path;
  final String content;
  final int? startLine;
  final int? endLine;

  const FileView({
    required this.path,
    required this.content,
    this.startLine,
    this.endLine,
    super.truncated,
  });
}

/// A shell command and its merged output (`bash`). [exitCode] is best-effort:
/// pi merges the streams and only one failure text carries a code.
class CommandView extends ToolView {
  final String command;
  final String output;
  final int? exitCode;

  const CommandView({
    required this.command,
    required this.output,
    this.exitCode,
    super.truncated,
  });
}

/// Search hits (`grep`/`find`). An empty list is a real "no matches".
class MatchesView extends ToolView {
  final List<Match> matches;

  const MatchesView({required this.matches, super.truncated});
}

/// A tabular result (`ls`). Empty rows is a real "empty directory".
class TableView extends ToolView {
  final List<String> columns;
  final List<List<String>> rows;

  const TableView({required this.columns, required this.rows, super.truncated});
}

/// The fallback for any tool without a structured view.
class GenericView extends ToolView {
  final String? target;

  const GenericView({this.target, super.truncated});
}

/// Parses one relayed `view` value. Returns null when absent, not a map, or a
/// `type` this build does not know — the caller renders its generic fallback.
///
/// Known types are parsed leniently: a malformed inner field becomes an empty
/// string/list rather than a null view, because the type already told us how to
/// paint the row.
ToolView? parseToolView(Object? raw) {
  if (raw is! Map) return null;
  final map = raw.cast<String, Object?>();
  final truncated = map['truncated'] == true;
  switch (map['type']) {
    case 'diff':
      return DiffView(
        path: _string(map['path']),
        lines: _lines(map['lines']),
        truncated: truncated,
      );
    case 'file':
      return FileView(
        path: _string(map['path']),
        content: _string(map['content']),
        startLine: _int(map['startLine']),
        endLine: _int(map['endLine']),
        truncated: truncated,
      );
    case 'command':
      return CommandView(
        command: _string(map['command']),
        output: _string(map['output']),
        exitCode: _int(map['exitCode']),
        truncated: truncated,
      );
    case 'matches':
      return MatchesView(matches: _matches(map['matches']), truncated: truncated);
    case 'table':
      return TableView(
        columns: _strings(map['columns']),
        rows: _rows(map['rows']),
        truncated: truncated,
      );
    case 'generic':
      final target = map['target'];
      return GenericView(
        target: target is String ? target : null,
        truncated: truncated,
      );
    default:
      return null;
  }
}

/// The one-line summary a collapsed tool row shows, or null when there is no
/// view to summarize. [toolName] distinguishes a `write` all-addition diff
/// (line count only) from an `edit` diff (a real `+N −M` delta).
String? toolSummary(ToolView? view, {String? toolName}) {
  if (view == null) return null;
  switch (view) {
    case DiffView():
      if (toolName == 'write') {
        return '${view.path} (${view.lines.length} lines)';
      }
      return '${view.path} +${view.additions} −${view.removals}';
    case FileView():
      if (view.startLine == null) return view.path;
      if (view.endLine == null) return '${view.path}:${view.startLine}';
      return '${view.path}:${view.startLine}-${view.endLine}';
    case CommandView():
      return view.command;
    case MatchesView():
      return view.matches.isEmpty ? 'no matches' : '${view.matches.length} matches';
    case TableView():
      return view.rows.isEmpty ? 'empty directory' : '${view.rows.length} entries';
    case GenericView():
      return view.target ?? '';
  }
}

String _string(Object? value) => value is String ? value : '';

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

List<String> _strings(Object? value) {
  if (value is! List) return const [];
  return value.whereType<String>().toList();
}

List<DiffLine> _lines(Object? value) {
  if (value is! List) return const [];
  final lines = <DiffLine>[];
  for (final entry in value) {
    if (entry is! Map) continue;
    final map = entry.cast<String, Object?>();
    final kind = map['kind'];
    lines.add(
      DiffLine(
        kind is String ? kind : diffLineCtx,
        map['text'] is String ? map['text'] as String : '',
      ),
    );
  }
  return lines;
}

List<Match> _matches(Object? value) {
  if (value is! List) return const [];
  final matches = <Match>[];
  for (final entry in value) {
    if (entry is! Map) continue;
    final map = entry.cast<String, Object?>();
    matches.add(
      Match(
        file: _string(map['file']),
        line: _int(map['line']) ?? 0,
        text: _string(map['text']),
      ),
    );
  }
  return matches;
}

List<List<String>> _rows(Object? value) {
  if (value is! List) return const [];
  final rows = <List<String>>[];
  for (final entry in value) {
    rows.add(_strings(entry));
  }
  return rows;
}
