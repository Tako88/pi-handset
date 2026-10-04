// The pure tool-view model: parsing the bridge's discriminated `view` payload
// into typed Dart, and the one-line summary a collapsed row shows.
//
// Pure Dart: no Flutter import, so it tests without a widget binding.

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/client/tool_view.dart';
import 'package:pi_droid/protocol/protocol.dart';

Map<String, Object?> view(String type, [Map<String, Object?> rest = const {}]) =>
    {'type': type, ...rest};

void main() {
  test('every declared view type parses to a view', () {
    for (final type in viewTypes) {
      expect(
        parseToolView(view(type)),
        isNotNull,
        reason: '$type is declared in viewTypes but has no case in parseToolView',
      );
    }
  });

  group('parseToolView', () {
    test('parses a diff view with its lines in order', () {
      final parsed = parseToolView(
        view('diff', {
          'path': 'app/foo.dart',
          'lines': [
            {'kind': 'ctx', 'text': 'void main() {'},
            {'kind': 'del', 'text': "  print('old');"},
            {'kind': 'add', 'text': "  print('new');"},
            {'kind': 'ctx', 'text': '}'},
          ],
        }),
      );

      expect(parsed, isA<DiffView>());
      final diff = parsed as DiffView;
      expect(diff.path, 'app/foo.dart');
      expect(diff.lines.map((line) => line.kind), ['ctx', 'del', 'add', 'ctx']);
      expect(diff.lines[2].text, "  print('new');");
      expect(diff.lines[2].isAdd, isTrue);
      expect(diff.lines[1].isDel, isTrue);
      expect(diff.truncated, isFalse);
    });

    test('parses a file view with its range', () {
      final parsed = parseToolView(
        view('file', {
          'path': 'app/foo.dart',
          'content': 'line one\nline two',
          'startLine': 2,
          'endLine': 3,
        }),
      );

      final file = parsed as FileView;
      expect(file.path, 'app/foo.dart');
      expect(file.content, 'line one\nline two');
      expect(file.startLine, 2);
      expect(file.endLine, 3);
    });

    test('a file view without a range leaves start/end null', () {
      final file = parseToolView(view('file', {'path': 'a.dart', 'content': 'x'}))
          as FileView;
      expect(file.startLine, isNull);
      expect(file.endLine, isNull);
    });

    test('parses a command view and a present exit code', () {
      final parsed = parseToolView(
        view('command', {'command': 'ls -1', 'output': 'a\nb', 'exitCode': 0}),
      );

      final command = parsed as CommandView;
      expect(command.command, 'ls -1');
      expect(command.output, 'a\nb');
      expect(command.exitCode, 0);
    });

    test('a command view without an exit code stays null', () {
      final command =
          parseToolView(view('command', {'command': 'sleep 1', 'output': 'x'}))
              as CommandView;
      expect(command.exitCode, isNull);
    });

    test('parses a matches view grouped by file', () {
      final parsed = parseToolView(
        view('matches', {
          'matches': [
            {'file': 'a.dart', 'line': 3, 'text': 'x'},
            {'file': 'a.dart', 'line': 9, 'text': 'y'},
            {'file': 'b.dart', 'line': 1, 'text': 'z'},
          ],
        }),
      );

      final matches = parsed as MatchesView;
      expect(matches.matches, hasLength(3));
      expect(matches.matches[0].file, 'a.dart');
      expect(matches.matches[0].line, 3);
      expect(matches.matches[0].text, 'x');
      expect(matches.matches[0].isPathOnly, isFalse);
    });

    test('an empty matches view parses to a matches view, not null', () {
      // "no matches" is a real result, not a parse failure.
      final parsed = parseToolView(view('matches', {'matches': []}));

      expect(parsed, isA<MatchesView>());
      expect((parsed as MatchesView).matches, isEmpty);
    });

    test('a find match is line 0 with empty text — a path-only hit', () {
      // The bridge's find view uses `line: 0, text: ''` for "a file matched,
      // no line"; that must stay a path, never render as line number 0.
      final match = (parseToolView(
        view('matches', {
          'matches': [
            {'file': 'src/a.dart', 'line': 0, 'text': ''},
          ],
        }),
      ) as MatchesView)
          .matches
          .single;

      expect(match.line, 0);
      expect(match.text, '');
      expect(match.isPathOnly, isTrue);
    });

    test('parses a table view with its columns and rows', () {
      final parsed = parseToolView(
        view('table', {
          'columns': ['name', 'type'],
          'rows': [
            ['app', 'directory'],
            ['README.md', 'file'],
          ],
        }),
      );

      final table = parsed as TableView;
      expect(table.columns, ['name', 'type']);
      expect(table.rows, hasLength(2));
      expect(table.rows[1], ['README.md', 'file']);
    });

    test('an empty table view parses to a table view, not null', () {
      // "(empty directory)" is a real result, not a parse failure.
      final parsed = parseToolView(view('table', {'columns': ['name', 'type'], 'rows': []}));

      expect(parsed, isA<TableView>());
      expect((parsed as TableView).rows, isEmpty);
    });

    test('parses a generic view with its target', () {
      final generic = parseToolView(view('generic', {'target': 'app/foo.dart'}))
          as GenericView;
      expect(generic.target, 'app/foo.dart');
    });

    test('a generic view without a target is still a view', () {
      final parsed = parseToolView(view('generic'));
      expect(parsed, isA<GenericView>());
      expect((parsed as GenericView).target, isNull);
    });

    test('the truncated flag is carried through', () {
      final parsed = parseToolView(
        view('command', {'command': 'x', 'output': 'y', 'truncated': true}),
      );
      expect(parsed!.truncated, isTrue);
    });

    test('null, a non-map and an unknown type all parse to null', () {
      // Version skew: the caller falls back to the generic preview.
      expect(parseToolView(null), isNull);
      expect(parseToolView('a string'), isNull);
      expect(parseToolView(42), isNull);
      expect(parseToolView(<Object?>[]), isNull);
      expect(parseToolView(<String, Object?>{}), isNull);
      expect(parseToolView(view('future-thing', {'detail': 'unknown'})), isNull);
    });
  });

  group('toolSummary', () {
    test('a diff names the path and the added/removed counts', () {
      final diff = parseToolView(
        view('diff', {
          'path': 'app/foo.dart',
          'lines': [
            {'kind': 'ctx', 'text': 'x'},
            {'kind': 'add', 'text': 'a'},
            {'kind': 'add', 'text': 'b'},
            {'kind': 'del', 'text': 'c'},
          ],
        }),
      );

      expect(toolSummary(diff), 'app/foo.dart +2 −1');
    });

    test('a write diff names only the line count, never a delta', () {
      // There is no old file to diff against, so `+N −0` would be a lie.
      final diff = parseToolView(
        view('diff', {
          'path': 'app/new.dart',
          'lines': [
            {'kind': 'add', 'text': 'line one'},
            {'kind': 'add', 'text': 'line two'},
          ],
        }),
      );

      expect(toolSummary(diff, toolName: 'write'), 'app/new.dart (2 lines)');
    });

    test('a file names the path and its range when known', () {
      final ranged = parseToolView(
        view('file', {
          'path': 'app/foo.dart',
          'content': 'x',
          'startLine': 1,
          'endLine': 2,
        }),
      );
      final plain = parseToolView(view('file', {'path': 'app/foo.dart', 'content': 'x'}));

      expect(toolSummary(ranged), 'app/foo.dart:1-2');
      expect(toolSummary(plain), 'app/foo.dart');
    });

    test('a command is the command text', () {
      final command = parseToolView(
        view('command', {'command': 'ls -1', 'output': 'x'}),
      );
      expect(toolSummary(command), 'ls -1');
    });

    test('a matches view counts the hits, and zero says "no matches"', () {
      final hits = parseToolView(
        view('matches', {
          'matches': [
            {'file': 'a.dart', 'line': 1, 'text': 'x'},
            {'file': 'a.dart', 'line': 2, 'text': 'y'},
            ...List.generate(5, (i) => {'file': 'b.dart', 'line': i + 1, 'text': 'z'}),
          ],
        }),
      );
      final none = parseToolView(view('matches', {'matches': []}));

      expect(toolSummary(hits), '7 matches');
      expect(toolSummary(none), 'no matches');
    });

    test('a table view counts the rows, and zero says "empty directory"', () {
      final rows = parseToolView(
        view('table', {
          'columns': ['name', 'type'],
          'rows': List.generate(12, (i) => ['entry$i', 'file']),
        }),
      );
      final empty = parseToolView(view('table', {'columns': ['name', 'type'], 'rows': []}));

      expect(toolSummary(rows), '12 entries');
      expect(toolSummary(empty), 'empty directory');
    });

    test('a generic view names its target, and null has no summary', () {
      final generic = parseToolView(view('generic', {'target': 'app/foo.dart'}));

      expect(toolSummary(generic), 'app/foo.dart');
      expect(toolSummary(null), isNull);
    });
  });
}
