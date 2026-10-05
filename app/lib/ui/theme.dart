/// pi's own colours, mapped onto Flutter.
///
/// The palette is pi's built-in dark and light themes, resolved to hex — not
/// chosen here, and not derived from a Material seed. Two namespaces, kept
/// deliberately apart because they are not the same set of ideas:
///
///  * [PiRoles] carries pi's semantic roles (a tool row's pending/success/error
///    background, the user message tint, the markdown roles, the thinking-level
///    ramp). Widgets that draw a *pi* concept read these.
///  * [ColorScheme] is hand-mapped from the same hexes for the framework chrome
///    Material owns — Scaffold, AppBar, buttons, sheets, SnackBars.
///
/// `ColorScheme.fromSeed` is deliberately not used: the roles left unset would
/// be seed-coloured, and the ones that a search of this app cannot see —
/// `surfaceTint`, which defaults to `primary` and washes every elevated surface
/// violet, and `inverseSurface`, which a SnackBar uses — would leak that seed
/// into the UI from under the palette.
///
/// There are no literal-colour assertions anywhere in the test suite and no
/// goldens: this file is the palette's single source of truth, and `spec.md`
/// under `.pi/plans/redesign/` is the design record.
library;

import 'package:flutter/material.dart';

/// pi's thinking levels, in pi's own order, lowest first.
///
/// pi's theme file names a border colour for each of these; the app uses them as
/// the rule and icon colour of a thinking row and of the status spinner, so the
/// phone shows the level the PC is running at. See [thinkingLevelColor].
const List<String> piThinkingLevels = <String>[
  'off',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
];

/// The colour of a thinking row for [level], or [PiRoles.thinkingOff] when the
/// level is unknown or absent.
///
/// Absent is a real case, not an error: a fresh session has no level until pi
/// reports one, and a bridge older than the level it would report sends none.
Color thinkingLevelColor(PiRoles roles, String? level) => switch (level) {
  'minimal' => roles.thinkingMinimal,
  'low' => roles.thinkingLow,
  'medium' => roles.thinkingMedium,
  'high' => roles.thinkingHigh,
  'xhigh' => roles.thinkingXhigh,
  'max' => roles.thinkingMax,
  _ => roles.thinkingOff,
};

/// The machine's own voice.
///
/// Applied to text that is the terminal's material rather than anyone's prose:
/// tool names and arguments, code, filesystem paths, the pairing code, session
/// ids, section labels. Resolves to the platform monospace face, so it costs no
/// asset and no dependency.
const String piMonoFamily = 'monospace';

/// A style in the machine's voice. Prefer this over repeating the family name,
/// so a later switch to a bundled face is one edit.
TextStyle piMono({
  double fontSize = 13,
  FontWeight? fontWeight,
  Color? color,
  double? letterSpacing,
  double? height,
}) => TextStyle(
  fontFamily: piMonoFamily,
  fontSize: fontSize,
  fontWeight: fontWeight,
  color: color,
  letterSpacing: letterSpacing,
  height: height,
);

/// pi's semantic colour roles, as one theme extension.
///
/// Every field is a hex value taken from pi's own theme files, with two kinds of
/// measured deviation, both because pi's palette is designed for a terminal and
/// does not clear the bars this app holds itself to:
///
///  * **Contrast.** pi's light palette is broadly sub-AA — `muted` is 4.32:1 on
///    its own page, `mdHeading` 4.37:1, `mdLink` 4.25:1, `dim` 2.81:1 — and
///    `toolOutput` is 4.46:1 on `toolSuccessBg` in *both* themes. Those values
///    are darkened (light) or lightened (dark) toward `text` until they clear
///    4.5:1 as text, or 3:1 as a rule, against the worst surface each is used
///    on. The hue is unchanged; only lightness moves. `theme_test.dart` pins the
///    property.
///  * **The thinking ramp.** pi's light ramp measures 1.57–2.44 against its
///    background — below even 3:1 — so the light palette reuses pi's *dark*
///    ramp (3.17–4.31 there), nudging only [thinkingMax]. A ramp colour is a
///    rule and an icon, never text.
///
/// Recorded in `docs/known-limits.md`.
@immutable
class PiRoles extends ThemeExtension<PiRoles> {
  const PiRoles({
    required this.pageBg,
    required this.cardBg,
    required this.text,
    required this.muted,
    required this.dim,
    required this.accent,
    required this.accentBg,
    required this.ink,
    required this.userMessageBg,
    required this.userMessageText,
    required this.selectedBg,
    required this.toolPendingBg,
    required this.toolSuccessBg,
    required this.toolErrorBg,
    required this.toolTitle,
    required this.toolOutput,
    required this.toolDiffAdded,
    required this.toolDiffRemoved,
    required this.toolDiffContext,
    required this.success,
    required this.error,
    required this.warning,
    required this.border,
    required this.borderMuted,
    required this.mdHeading,
    required this.mdLink,
    required this.mdCode,
    required this.mdCodeBlock,
    required this.mdCodeBlockBorder,
    required this.mdQuote,
    required this.mdListBullet,
    required this.thinkingOff,
    required this.thinkingMinimal,
    required this.thinkingLow,
    required this.thinkingMedium,
    required this.thinkingHigh,
    required this.thinkingXhigh,
    required this.thinkingMax,
  });

  /// The page behind the transcript, and the card the chrome and rows sit on.
  final Color pageBg;
  final Color cardBg;

  /// Default, secondary, and very-dim text. [muted] is the lowest role fit for
  /// text; [dim] is **graphical only** — rules, dividers, handles — and is never
  /// used for a word, on either theme.
  final Color text;
  final Color muted;
  final Color dim;

  /// The violet accent — pi's `accent`. Carries the user's rule, the selected
  /// session, and the primary button.
  final Color accent;

  /// pi's `customMessageBg`: a violet-tinted surface for the app's own
  /// affordances that are neither the user's nor pi's.
  final Color accentBg;

  /// The ink to place on [accent].
  final Color ink;

  final Color userMessageBg;
  final Color userMessageText;

  /// pi's `selectedBg`, for a picked list row.
  final Color selectedBg;

  /// A tool row, by state. The app already knows the state, so the colour is
  /// information rather than decoration.
  final Color toolPendingBg;
  final Color toolSuccessBg;
  final Color toolErrorBg;

  final Color toolTitle;
  final Color toolOutput;

  /// A diff line, on the tool panel's own background — coloured **text**, the way
  /// pi draws a diff, not a filled row. Each of these is pi's `toolDiff*` token
  /// derived to clear 4.5:1 on the worst of the three tool panels.
  final Color toolDiffAdded;
  final Color toolDiffRemoved;
  final Color toolDiffContext;

  final Color success;
  final Color error;
  final Color warning;

  /// pi's `border` (blue) — a focused field, and [borderMuted] an idle one.
  final Color border;
  final Color borderMuted;

  final Color mdHeading;
  final Color mdLink;
  final Color mdCode;
  final Color mdCodeBlock;
  final Color mdCodeBlockBorder;
  final Color mdQuote;
  final Color mdListBullet;

  /// The thinking-level ramp, lowest to highest. `off`'s fallback use is
  /// [thinkingLevelColor].
  final Color thinkingOff;
  final Color thinkingMinimal;
  final Color thinkingLow;
  final Color thinkingMedium;
  final Color thinkingHigh;
  final Color thinkingXhigh;
  final Color thinkingMax;

  @override
  PiRoles copyWith({
    Color? pageBg,
    Color? cardBg,
    Color? text,
    Color? muted,
    Color? dim,
    Color? accent,
    Color? accentBg,
    Color? ink,
    Color? userMessageBg,
    Color? userMessageText,
    Color? selectedBg,
    Color? toolPendingBg,
    Color? toolSuccessBg,
    Color? toolErrorBg,
    Color? toolTitle,
    Color? toolOutput,
    Color? toolDiffAdded,
    Color? toolDiffRemoved,
    Color? toolDiffContext,
    Color? success,
    Color? error,
    Color? warning,
    Color? border,
    Color? borderMuted,
    Color? mdHeading,
    Color? mdLink,
    Color? mdCode,
    Color? mdCodeBlock,
    Color? mdCodeBlockBorder,
    Color? mdQuote,
    Color? mdListBullet,
    Color? thinkingOff,
    Color? thinkingMinimal,
    Color? thinkingLow,
    Color? thinkingMedium,
    Color? thinkingHigh,
    Color? thinkingXhigh,
    Color? thinkingMax,
  }) => PiRoles(
    pageBg: pageBg ?? this.pageBg,
    cardBg: cardBg ?? this.cardBg,
    text: text ?? this.text,
    muted: muted ?? this.muted,
    dim: dim ?? this.dim,
    accent: accent ?? this.accent,
    accentBg: accentBg ?? this.accentBg,
    ink: ink ?? this.ink,
    userMessageBg: userMessageBg ?? this.userMessageBg,
    userMessageText: userMessageText ?? this.userMessageText,
    selectedBg: selectedBg ?? this.selectedBg,
    toolPendingBg: toolPendingBg ?? this.toolPendingBg,
    toolSuccessBg: toolSuccessBg ?? this.toolSuccessBg,
    toolErrorBg: toolErrorBg ?? this.toolErrorBg,
    toolTitle: toolTitle ?? this.toolTitle,
    toolOutput: toolOutput ?? this.toolOutput,
    toolDiffAdded: toolDiffAdded ?? this.toolDiffAdded,
    toolDiffRemoved: toolDiffRemoved ?? this.toolDiffRemoved,
    toolDiffContext: toolDiffContext ?? this.toolDiffContext,
    success: success ?? this.success,
    error: error ?? this.error,
    warning: warning ?? this.warning,
    border: border ?? this.border,
    borderMuted: borderMuted ?? this.borderMuted,
    mdHeading: mdHeading ?? this.mdHeading,
    mdLink: mdLink ?? this.mdLink,
    mdCode: mdCode ?? this.mdCode,
    mdCodeBlock: mdCodeBlock ?? this.mdCodeBlock,
    mdCodeBlockBorder: mdCodeBlockBorder ?? this.mdCodeBlockBorder,
    mdQuote: mdQuote ?? this.mdQuote,
    mdListBullet: mdListBullet ?? this.mdListBullet,
    thinkingOff: thinkingOff ?? this.thinkingOff,
    thinkingMinimal: thinkingMinimal ?? this.thinkingMinimal,
    thinkingLow: thinkingLow ?? this.thinkingLow,
    thinkingMedium: thinkingMedium ?? this.thinkingMedium,
    thinkingHigh: thinkingHigh ?? this.thinkingHigh,
    thinkingXhigh: thinkingXhigh ?? this.thinkingXhigh,
    thinkingMax: thinkingMax ?? this.thinkingMax,
  );

  /// Interpolated, because `MaterialApp` animates a theme change over
  /// `kThemeAnimationDuration` and returns the *other* roles only at the ends.
  /// A hard swap here would crossfade the `ColorScheme` smoothly while the roles
  /// jumped, briefly pairing one palette's text with the other's background.
  @override
  PiRoles lerp(covariant PiRoles? other, double t) {
    if (other == null) return this;
    Color m(Color a, Color b) => Color.lerp(a, b, t)!;
    return PiRoles(
      pageBg: m(pageBg, other.pageBg),
      cardBg: m(cardBg, other.cardBg),
      text: m(text, other.text),
      muted: m(muted, other.muted),
      dim: m(dim, other.dim),
      accent: m(accent, other.accent),
      accentBg: m(accentBg, other.accentBg),
      ink: m(ink, other.ink),
      userMessageBg: m(userMessageBg, other.userMessageBg),
      userMessageText: m(userMessageText, other.userMessageText),
      selectedBg: m(selectedBg, other.selectedBg),
      toolPendingBg: m(toolPendingBg, other.toolPendingBg),
      toolSuccessBg: m(toolSuccessBg, other.toolSuccessBg),
      toolErrorBg: m(toolErrorBg, other.toolErrorBg),
      toolTitle: m(toolTitle, other.toolTitle),
      toolOutput: m(toolOutput, other.toolOutput),
      toolDiffAdded: m(toolDiffAdded, other.toolDiffAdded),
      toolDiffRemoved: m(toolDiffRemoved, other.toolDiffRemoved),
      toolDiffContext: m(toolDiffContext, other.toolDiffContext),
      success: m(success, other.success),
      error: m(error, other.error),
      warning: m(warning, other.warning),
      border: m(border, other.border),
      borderMuted: m(borderMuted, other.borderMuted),
      mdHeading: m(mdHeading, other.mdHeading),
      mdLink: m(mdLink, other.mdLink),
      mdCode: m(mdCode, other.mdCode),
      mdCodeBlock: m(mdCodeBlock, other.mdCodeBlock),
      mdCodeBlockBorder: m(mdCodeBlockBorder, other.mdCodeBlockBorder),
      mdQuote: m(mdQuote, other.mdQuote),
      mdListBullet: m(mdListBullet, other.mdListBullet),
      thinkingOff: m(thinkingOff, other.thinkingOff),
      thinkingMinimal: m(thinkingMinimal, other.thinkingMinimal),
      thinkingLow: m(thinkingLow, other.thinkingLow),
      thinkingMedium: m(thinkingMedium, other.thinkingMedium),
      thinkingHigh: m(thinkingHigh, other.thinkingHigh),
      thinkingXhigh: m(thinkingXhigh, other.thinkingXhigh),
      thinkingMax: m(thinkingMax, other.thinkingMax),
    );
  }
}

/// pi's dark palette (`theme/dark.json`, resolved to hex).
const PiRoles piDarkRoles = PiRoles(
  pageBg: Color(0xFF12141A),
  cardBg: Color(0xFF191C22),
  text: Color(0xFFDEE0E1),
  muted: Color(0xFF9DA5A9),
  dim: Color(0xFF7E888E),
  accent: Color(0xFFA798D7),
  accentBg: Color(0xFF3A3055),
  ink: Color(0xFF241F38),
  userMessageBg: Color(0xFF213B49),
  userMessageText: Color(0xFFDEE0E1),
  selectedBg: Color(0xFF213B49),
  toolPendingBg: Color(0xFF34383A),
  toolSuccessBg: Color(0xFF254131),
  toolErrorBg: Color(0xFF5B282A),
  toolTitle: Color(0xFFDEE0E1),
  toolOutput: Color(0xFF9EA6AA),
  toolDiffAdded: Color(0xFF68B78D),
  toolDiffRemoved: Color(0xFFE98A8C),
  toolDiffContext: Color(0xFF9EA6AA),
  success: Color(0xFF68B78D),
  error: Color(0xFFEA7F81),
  warning: Color(0xFFCD9A22),
  border: Color(0xFF5FA8CC),
  borderMuted: Color(0xFF768186),
  mdHeading: Color(0xFFCD9A22),
  mdLink: Color(0xFF69ADD0),
  mdCode: Color(0xFFA798D7),
  mdCodeBlock: Color(0xFF68B78D),
  mdCodeBlockBorder: Color(0xFF9DA5A9),
  mdQuote: Color(0xFF9DA5A9),
  mdListBullet: Color(0xFFA798D7),
  thinkingOff: Color(0xFF6C767B),
  thinkingMinimal: Color(0xFF68808D),
  thinkingLow: Color(0xFF5489A4),
  thinkingMedium: Color(0xFF6185CC),
  thinkingHigh: Color(0xFF9776E5),
  thinkingXhigh: Color(0xFFDE54C1),
  thinkingMax: Color(0xFFFE5462),
);

/// pi's light palette (`theme/light.json`, resolved to hex).
///
/// The ramp is pi's *dark* one, with [thinkingMax] nudged, for the reason given
/// on [PiRoles].
const PiRoles piLightRoles = PiRoles(
  pageBg: Color(0xFFEFEEEE),
  cardBg: Color(0xFFF7F6F6),
  text: Color(0xFF3B3F41),
  muted: Color(0xFF646E73),
  dim: Color(0xFF828A8F),
  accent: Color(0xFF7459B4),
  accentBg: Color(0xFFE6E4EE),
  ink: Color(0xFFFFFFFF),
  userMessageBg: Color(0xFFDFE7EC),
  userMessageText: Color(0xFF3B3F41),
  selectedBg: Color(0xFFDFE7EC),
  toolPendingBg: Color(0xFFE4E5E6),
  toolSuccessBg: Color(0xFFDEE9E1),
  toolErrorBg: Color(0xFFEEE2E1),
  toolTitle: Color(0xFF3B3F41),
  toolOutput: Color(0xFF5F686D),
  toolDiffAdded: Color(0xFF347254),
  toolDiffRemoved: Color(0xFFC3263D),
  toolDiffContext: Color(0xFF5F686D),
  success: Color(0xFF337E58),
  error: Color(0xFFC8253D),
  warning: Color(0xFF8F6802),
  border: Color(0xFF3D8EB3),
  borderMuted: Color(0xFF9AA2A7),
  mdHeading: Color(0xFF8C6605),
  mdLink: Color(0xFF307392),
  mdCode: Color(0xFF7459B4),
  mdCodeBlock: Color(0xFF337E58),
  mdCodeBlockBorder: Color(0xFF677176),
  mdQuote: Color(0xFF646E73),
  mdListBullet: Color(0xFF7459B4),
  thinkingOff: Color(0xFF6C767B),
  thinkingMinimal: Color(0xFF68808D),
  thinkingLow: Color(0xFF5489A4),
  thinkingMedium: Color(0xFF6185CC),
  thinkingHigh: Color(0xFF9776E5),
  thinkingXhigh: Color(0xFFDE54C1),
  thinkingMax: Color(0xFFF65361),
);

/// Material's chrome roles, mapped from the same pi hexes.
///
/// The list is longer than the handful of roles the app reads directly because
/// Material reads the rest on the app's behalf — a `FilledButton`, a `SnackBar`,
/// a sheet, a scrolled-under app bar — and an unset role would fall back to a
/// default derived from `primary`.
ColorScheme _scheme(PiRoles r, Brightness brightness) => ColorScheme(
  brightness: brightness,
  primary: r.accent,
  onPrimary: r.ink,
  primaryContainer: r.userMessageBg,
  onPrimaryContainer: r.userMessageText,
  secondary: r.muted,
  onSecondary: r.pageBg,
  secondaryContainer: r.selectedBg,
  onSecondaryContainer: r.text,
  tertiary: r.border,
  onTertiary: r.pageBg,
  tertiaryContainer: r.accentBg,
  onTertiaryContainer: r.text,
  error: r.error,
  onError: r.ink,
  errorContainer: r.toolErrorBg,
  onErrorContainer: r.text,
  surface: r.pageBg,
  onSurface: r.text,
  surfaceDim: r.pageBg,
  surfaceBright: r.cardBg,
  surfaceContainerLowest: r.pageBg,
  surfaceContainerLow: r.pageBg,
  surfaceContainer: r.cardBg,
  surfaceContainerHigh: r.cardBg,
  surfaceContainerHighest: r.cardBg,
  onSurfaceVariant: r.muted,
  outline: r.borderMuted,
  outlineVariant: r.dim,
  shadow: const Color(0xFF000000),
  scrim: const Color(0xFF000000),
  inverseSurface: r.text,
  onInverseSurface: r.pageBg,
  inversePrimary: r.accent,
  // pi has no elevation tint, and this one defaults to `primary`; left alone it
  // would wash every elevated surface violet.
  surfaceTint: r.pageBg,
);

/// The app's theme for [brightness], built from pi's palette.
ThemeData piTheme(Brightness brightness) {
  final roles = brightness == Brightness.dark ? piDarkRoles : piLightRoles;
  final scheme = _scheme(roles, brightness);
  return ThemeData(
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: roles.pageBg,
    canvasColor: roles.pageBg,
    extensions: <ThemeExtension<dynamic>>[roles],
    // pi draws no chrome above its content, so the header is the page itself,
    // not a band above it — one continuous surface, with a hairline so scrolled
    // content does not collide with the title.
    appBarTheme: AppBarTheme(
      backgroundColor: roles.pageBg,
      foregroundColor: roles.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      shape: Border(bottom: BorderSide(color: roles.dim)),
    ),
    // One filled action per screen, in the accent — the violet that means "a
    // thing you can act on". No elevation: pi has no shadows.
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: roles.accent,
      foregroundColor: roles.ink,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
    ),
    // Floating on the card surface rather than Material's `inverseSurface`,
    // which would be a light slab in the dark theme and reads as an alien
    // element in a palette pi has no inverted surface for.
    snackBarTheme: SnackBarThemeData(
      backgroundColor: roles.cardBg,
      contentTextStyle: TextStyle(color: roles.text),
      actionTextColor: roles.accent,
      behavior: SnackBarBehavior.floating,
      elevation: 0,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: roles.cardBg,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: roles.cardBg,
      dragHandleColor: roles.dim,
      elevation: 0,
      modalElevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: roles.cardBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    dividerTheme: DividerThemeData(color: roles.dim, space: 1, thickness: 1),
    textSelectionTheme: TextSelectionThemeData(
      selectionColor: roles.accent.withValues(alpha: 0.35),
      selectionHandleColor: roles.accent,
      cursorColor: roles.accent,
    ),
  );
}

/// The app's row geometry, in one place so no two rows can drift apart: the page
/// padding, then the role rule, then the gap to the content. Every row that uses
/// [DocumentRow] starts its text at the same x, ruled or not.
const double _pagePadding = 12;
const double _ruleWidth = 3;
const double _ruleGap = 10;
const double _rowPadding = 8;

/// One row of a document — the app's shared row shape.
///
/// A full-bleed surface, a rule in the gutter, and content that starts at the
/// same x as every other row. Used by the transcript and by the session list, so
/// the two screens share one left edge.
///
/// [rule] and [background] are null when a row has no role to carry — assistant
/// prose — which keeps the text edge aligned without drawing anything.
class DocumentRow extends StatelessWidget {
  const DocumentRow({
    super.key,
    this.rule,
    this.background,
    this.onTap,
    required this.child,
  });

  /// The role rule's colour, or null for no rule.
  final Color? rule;

  /// The row's full-bleed surface, or null for the page itself.
  final Color? background;

  /// Makes the whole row a tap target. The surface is carried by a [Material]
  /// rather than a plain box so the ink response is painted *above* it — an
  /// `InkWell` under a coloured box is an invisible tap.
  final VoidCallback? onTap;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    Widget row = Padding(
      padding: const EdgeInsets.only(left: _pagePadding),
      child: Container(
        decoration: BoxDecoration(
          // Always drawn, transparent when the row has no role, so that every
          // row's text starts at the same x. A rule cannot be a stretched child
          // of the row: a list item's height is unbounded, and stretching under
          // unbounded constraints is an invalid constraint.
          border: Border(
            left: BorderSide(color: rule ?? Colors.transparent, width: _ruleWidth),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(
          _ruleGap,
          _rowPadding,
          _pagePadding,
          _rowPadding,
        ),
        child: child,
      ),
    );
    if (onTap != null) row = InkWell(onTap: onTap, child: row);
    return Material(color: background ?? Colors.transparent, child: row);
  }
}
