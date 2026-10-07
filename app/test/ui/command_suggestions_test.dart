// The `/` suggestion rule and the panel that shows the matches. The rule is
// pure, so it gets the exhaustive cases; the panel is dumb and only needs to
// render what it is given and report a tap.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_handset/client/hub_client.dart';
import 'package:pi_handset/ui/command_suggestions.dart';
import 'package:pi_handset/ui/theme.dart';

const review = SlashCommand(name: 'review', description: 'Review the working tree');
const implement = SlashCommand(name: 'implement-vetted');
const skillReviewer = SlashCommand(
  name: 'skill:reviewer',
  description: 'Reviews things',
);
const all = [review, implement, skillReviewer];

List<String> names(List<SlashCommand> commands) =>
    commands.map((command) => command.name).toList();

Widget wrapPanel(
  List<SlashCommand> commands, {
  ValueChanged<String>? onPick,
  double maxHeight = 200,
}) => MaterialApp(
      theme: piTheme(Brightness.dark),
  home: Scaffold(
    body: CommandSuggestionPanel(
      commands: commands,
      maxHeight: maxHeight,
      onPick: onPick ?? (_) {},
    ),
  ),
);

void main() {
  group('suggestionsFor', () {
    test('bare slash returns every command in pi order', () {
      expect(names(suggestionsFor(all, '/')), [
        'review',
        'implement-vetted',
        'skill:reviewer',
      ]);
    });

    test('bare slash returns a copy, not the caller\'s list', () {
      final commands = [...all];
      final suggestions = suggestionsFor(commands, '/');

      commands.clear();

      expect(suggestions, isNotEmpty);
    });

    test('a prefix narrows to the matching name', () {
      expect(names(suggestionsFor(all, '/rev')), ['review']);
    });

    test('matching is case-insensitive', () {
      expect(names(suggestionsFor(all, '/REV')), ['review']);
    });

    test('a colon is not whitespace', () {
      expect(names(suggestionsFor(all, '/skill:rev')), ['skill:reviewer']);
    });

    test('a trailing space hides the panel (arguments have begun)', () {
      expect(suggestionsFor(all, '/review '), isEmpty);
    });

    test('a draft without a leading slash is ignored', () {
      expect(suggestionsFor(all, 'hello'), isEmpty);
    });

    test('an empty draft is ignored', () {
      expect(suggestionsFor(all, ''), isEmpty);
    });

    test('a non-matching prefix returns nothing', () {
      expect(suggestionsFor(all, '/zzz'), isEmpty);
    });

    test('no commands means no suggestions, whatever the draft', () {
      for (final draft in ['/', '/rev', 'hello', '']) {
        expect(suggestionsFor(const [], draft), isEmpty);
      }
    });
  });

  group('isCommandDraft', () {
    test('a leading slash with no whitespace is a command draft', () {
      expect(isCommandDraft('/'), isTrue);
      expect(isCommandDraft('/re'), isTrue);
    });

    test('empty, plain text and a spaced command are not', () {
      expect(isCommandDraft(''), isFalse);
      expect(isCommandDraft('hello'), isFalse);
      expect(isCommandDraft('/review '), isFalse);
    });
  });

  group('CommandSuggestionPanel', () {
    testWidgets('renders a keyed tile per command with its slash name', (
      tester,
    ) async {
      await tester.pumpWidget(wrapPanel(all));

      expect(
        find.byKey(const Key('compose-suggestion-0-review')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('compose-suggestion-1-implement-vetted')),
        findsOneWidget,
      );
      expect(find.text('/review'), findsOneWidget);
      expect(find.text('/skill:reviewer'), findsOneWidget);
    });

    testWidgets('a null description gives no subtitle', (tester) async {
      await tester.pumpWidget(wrapPanel(const [implement]));

      final tile = tester.widget<ListTile>(
        find.byKey(const Key('compose-suggestion-0-implement-vetted')),
      );
      expect(tile.subtitle, isNull);
    });

    testWidgets('a long description is ellipsized, not overflowed', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrapPanel([
          SlashCommand(name: 'review', description: 'x' * 500),
        ]),
      );

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('compose-suggestion-0-review')),
        findsOneWidget,
      );
    });

    testWidgets('a long command name is ellipsized, not overflowed', (
      tester,
    ) async {
      final name = 'x' * 200;
      await tester.pumpWidget(wrapPanel([SlashCommand(name: name)]));

      final title = tester.renderObject<RenderParagraph>(find.text('/$name'));
      // A bare `Text` does not throw on overflow; it silently paints past the
      // tile. The ellipsis only happens if the title is clamped to one line.
      expect(title.didExceedMaxLines, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('duplicate command names render without a key clash', (
      tester,
    ) async {
      String? picked;
      await tester.pumpWidget(
        wrapPanel(const [review, review], onPick: (name) => picked = name),
      );

      expect(
        find.byKey(const Key('compose-suggestion-0-review')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('compose-suggestion-1-review')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('compose-suggestion-1-review')));
      await tester.pump();

      expect(picked, 'review');
    });

    testWidgets('tapping a tile reports the bare name', (tester) async {
      String? picked;
      await tester.pumpWidget(wrapPanel(all, onPick: (name) => picked = name));

      await tester.tap(find.byKey(const Key('compose-suggestion-0-review')));
      await tester.pump();

      expect(picked, 'review');
    });

    testWidgets('the panel exposes a screen-reader label', (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(wrapPanel(all));

      expect(find.bySemanticsLabel('Slash commands'), findsOneWidget);

      handle.dispose();
    });
  });
}
