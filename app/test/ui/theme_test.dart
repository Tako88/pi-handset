/// The pi palette and its mapping onto Flutter.
///
/// Deliberately no literal colour assertions and no goldens: the palette's
/// single source of truth is `lib/ui/theme.dart`, and what can be wrong without
/// looking wrong is a *relationship* — a level with no colour of its own, an
/// unknown level throwing, a theme that never exposes its roles, or Material's
/// own default `surfaceTint` (which is `primary`) tinting every elevated
/// surface violet. Those are the things asserted here.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_droid/ui/theme.dart';

void main() {
  test('every thinking level has its own colour on the ramp', () {
    final ramp = {
      for (final level in piThinkingLevels)
        thinkingLevelColor(piDarkRoles, level),
    };
    expect(
      ramp,
      hasLength(piThinkingLevels.length),
      reason: 'two levels sharing a colour cannot be told apart on screen',
    );
  });

  test('each thinking level maps to the role pi names for it', () {
    expect(thinkingLevelColor(piDarkRoles, 'off'), piDarkRoles.thinkingOff);
    expect(thinkingLevelColor(piDarkRoles, 'minimal'), piDarkRoles.thinkingMinimal);
    expect(thinkingLevelColor(piDarkRoles, 'low'), piDarkRoles.thinkingLow);
    expect(thinkingLevelColor(piDarkRoles, 'medium'), piDarkRoles.thinkingMedium);
    expect(thinkingLevelColor(piDarkRoles, 'high'), piDarkRoles.thinkingHigh);
    expect(thinkingLevelColor(piDarkRoles, 'xhigh'), piDarkRoles.thinkingXhigh);
    expect(thinkingLevelColor(piDarkRoles, 'max'), piDarkRoles.thinkingMax);
  });

  test('an unknown or absent thinking level falls back instead of throwing', () {
    // The bridge may be older than the level it reports, and a fresh session
    // has no level at all until pi says one.
    expect(thinkingLevelColor(piDarkRoles, null), piDarkRoles.thinkingOff);
    expect(thinkingLevelColor(piDarkRoles, ''), piDarkRoles.thinkingOff);
    expect(thinkingLevelColor(piDarkRoles, 'turbo'), piDarkRoles.thinkingOff);
  });

  test('each brightness exposes its own roles through the theme', () {
    expect(piTheme(Brightness.dark).extension<PiRoles>(), piDarkRoles);
    expect(piTheme(Brightness.light).extension<PiRoles>(), piLightRoles);
    expect(piTheme(Brightness.dark).brightness, Brightness.dark);
    expect(piTheme(Brightness.light).brightness, Brightness.light);
  });

  test('no elevated surface is tinted by Material, only by pi', () {
    // `ColorScheme.surfaceTint` defaults to `primary`. Left alone it would wash
    // every elevated surface violet — a leak a grep of the app cannot see.
    for (final theme in [piTheme(Brightness.dark), piTheme(Brightness.light)]) {
      expect(theme.colorScheme.surfaceTint, theme.colorScheme.surface);
      expect(theme.appBarTheme.surfaceTintColor, Colors.transparent);
    }
  });

  test('the light theme is lighter than the dark one', () {
    // The app already asserts this of its rendered scheme; pin it at the source
    // so a hand-mapped palette cannot silently invert.
    expect(
      piTheme(Brightness.dark).colorScheme.surface.computeLuminance(),
      lessThan(piTheme(Brightness.light).colorScheme.surface.computeLuminance()),
    );
  });

  test('the banner colours stay legible against each other', () {
    // The existing app test asserts the banner uses `errorContainer`; this pins
    // that there is still an on-colour for it.
    for (final theme in [piTheme(Brightness.dark), piTheme(Brightness.light)]) {
      final scheme = theme.colorScheme;
      expect(scheme.onErrorContainer, isNot(scheme.errorContainer));
      expect(scheme.onPrimary, isNot(scheme.primary));
    }
  });

  // WCAG 2.1 relative-contrast, matching `Color.computeLuminance`.
  double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  test('every role drawn as text clears AA on the surface it sits on', () {
    // A property, not a value: the palette may change freely, but it may not
    // become unreadable. This is a regression test for a real defect — pi's own
    // light palette does NOT satisfy it (`muted` is 4.32:1 on pi's light page,
    // `thinkingText` 3.21:1), so the light palette derives those values.
    //
    // The pairs are the ones the renderers actually draw. A pair missing from
    // this list is unguarded, which is the honest ceiling of a hand-written
    // table.
    for (final roles in [piDarkRoles, piLightRoles]) {
      for (final (label, fg, bg) in <(String, Color, Color)>[
        ('body text on the page', roles.text, roles.pageBg),
        ('body text on a card', roles.text, roles.cardBg),
        ('secondary text on the page', roles.muted, roles.pageBg),
        ('secondary text on a card', roles.muted, roles.cardBg),
        ('the user\'s own message', roles.userMessageText, roles.userMessageBg),
        ('a tool name while running', roles.toolTitle, roles.toolPendingBg),
        ('a tool name when done', roles.toolTitle, roles.toolSuccessBg),
        ('a tool name on failure', roles.toolTitle, roles.toolErrorBg),
        ('tool output while running', roles.toolOutput, roles.toolPendingBg),
        ('tool output when done', roles.toolOutput, roles.toolSuccessBg),
        ('tool output on failure', roles.toolOutput, roles.toolErrorBg),
        ('an added diff line', roles.toolDiffAdded, roles.toolSuccessBg),
        ('a removed diff line', roles.toolDiffRemoved, roles.toolSuccessBg),
        ('a removed diff line on failure', roles.toolDiffRemoved, roles.toolErrorBg),
        ('a context diff line', roles.toolDiffContext, roles.toolPendingBg),
        ('a heading', roles.mdHeading, roles.pageBg),
        ('a link', roles.mdLink, roles.pageBg),
        ('inline code', roles.mdCode, roles.pageBg),
        ('a blockquote', roles.mdQuote, roles.pageBg),
        ('a list bullet', roles.mdListBullet, roles.pageBg),
        ('a snackbar action', roles.accent, roles.cardBg),
      ]) {
        expect(
          contrast(fg, bg),
          greaterThanOrEqualTo(4.5),
          reason:
              '$label: ${fg.toARGB32().toRadixString(16)} on '
              '${bg.toARGB32().toRadixString(16)}',
        );
      }
    }
  });

  test('every role drawn as a rule clears the 3:1 graphical bar', () {
    // A rule carries meaning — the user's, a tool's state, a thinking level — so
    // it is a graphical object that has to be perceivable, not decoration.
    for (final roles in [piDarkRoles, piLightRoles]) {
      for (final (label, fg, bg) in <(String, Color, Color)>[
        ('the user\'s rule', roles.accent, roles.userMessageBg),
        ('a user image\'s rule', roles.accent, roles.pageBg),
        ('a thinking row\'s rule', roles.dim, roles.pageBg),
        ('a running tool\'s rule', roles.muted, roles.toolPendingBg),
        ('a finished tool\'s rule', roles.success, roles.toolSuccessBg),
        ('a failed tool\'s rule', roles.error, roles.toolErrorBg),
      ]) {
        expect(
          contrast(fg, bg),
          greaterThanOrEqualTo(3),
          reason:
              '$label: ${fg.toARGB32().toRadixString(16)} on '
              '${bg.toARGB32().toRadixString(16)}',
        );
      }
    }
  });

  test('text selection is painted from pi, not Material defaults', () {
    for (final brightness in [Brightness.dark, Brightness.light]) {
      final theme = piTheme(brightness);
      final roles = theme.extension<PiRoles>()!;
      final selection = theme.textSelectionTheme;
      expect(selection.selectionHandleColor, roles.accent);
      expect(selection.cursorColor, roles.accent);
      expect(selection.selectionColor, isNotNull);
      expect(selection.selectionColor!.a, greaterThan(0.0));
      expect(selection.selectionColor!.a, lessThan(1.0),
          reason: 'a fully opaque highlight hides the text it marks');
    }
  });
}
