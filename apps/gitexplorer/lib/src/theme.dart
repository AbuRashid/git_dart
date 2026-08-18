import 'package:flutter/material.dart';
import 'package:syntax_dart/syntax_dart.dart';

import 'generated/tokens.dart';

/// The seed the whole scheme is generated from.
///
/// git's orange, which is also what the application's icon is drawn in. One
/// colour rather than a palette: Material derives the roles, and the window
/// ends up recognisably this application's without anything here deciding what
/// "a surface" or "a container" should look like (`presentation.doc`).
const _seed = Color(0xFFF05133);

/// Stock Material, light and dark.
///
/// No palette, no metrics, no type scale: Material has all three, and an
/// application that redefines them has to maintain them and stops looking like
/// everything else on the machine (`presentation.doc`).
///
/// What is configured below is Material's own components, not new values. The
/// defaults leave every surface the same colour and every row square, which
/// reads as unfinished rather than as restraint; Material already has the
/// container roles and the shapes for this, and this asks for them
/// (`presentation.material-used-rather-than-defaulted`).
ThemeData explorerTheme(Brightness brightness) {
  final colors = ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: brightness,
    // Material's default mapping spreads the seed's hue across the surfaces
    // too, which from a red-orange comes out pink and makes the window look
    // like it belongs to something else entirely. This variant is the one that
    // keeps a coloured primary over neutral surfaces, which is what a tool
    // wants: grey to read on, the accent where something is being pointed at.
    dynamicSchemeVariant: DynamicSchemeVariant.rainbow,
  );

  return ThemeData(
    colorScheme: colors,
    useMaterial3: true,
    scaffoldBackgroundColor: colors.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: colors.surfaceContainer,
      // Says "the list scrolled under this" instead of drawing a line for it.
      scrolledUnderElevation: 3,
    ),
    dividerTheme: DividerThemeData(
      space: 1,
      thickness: 1,
      color: colors.outlineVariant,
    ),
    listTileTheme: ListTileThemeData(
      // A selected row reads as one object when its highlight has an edge; the
      // full-bleed default bar makes the tree look like a table instead.
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(9)),
      ),
      // The primary container, not the secondary one: this scheme keeps its
      // colour in the primary roles and leaves the rest near-neutral, so a
      // secondary highlight is invisible against a neutral sidebar.
      selectedTileColor: colors.primaryContainer,
      selectedColor: colors.onPrimaryContainer,
    ),
    tabBarTheme: const TabBarThemeData(
      // Otherwise the indicator spans the whole tab and reads as a border.
      indicatorSize: TabBarIndicatorSize.label,
      dividerHeight: 0,
    ),
  );
}

/// The colour of a status letter.
///
/// The one thing Material's scheme does not decide, since it has no opinion on
/// how "modified" should differ from "added". Taken from Material's own
/// swatches for the current brightness rather than from values invented here
/// (`presentation.status-colour`).
Color? statusColor(FileState state, BuildContext context) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;

  Color shade(MaterialColor swatch) => dark ? swatch.shade300 : swatch.shade700;

  return switch (state) {
    FileState.modified => shade(Colors.orange),
    FileState.added => shade(Colors.green),
    FileState.deleted => theme.colorScheme.error,
    FileState.renamed => shade(Colors.purple),
    FileState.typechange => shade(Colors.teal),
    FileState.conflicted => shade(Colors.pink),
    FileState.untracked => theme.colorScheme.onSurfaceVariant,
    FileState.clean || FileState.ignored => null,
  };
}

/// The fill behind a "that worked" message.
///
/// A solid tint from Material's green swatch rather than the status colour at
/// low opacity: a 14% wash over a surface that already carries Material 3's
/// own tint comes out grey-green and reads as disabled, which is the opposite
/// of what a success notice is for.
Color successBackground(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? Colors.green.shade800
        : Colors.green.shade100;

/// The green a success mark is drawn in — strong enough to carry white.
Color successMark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? Colors.green.shade500
        : Colors.green.shade600;

Color onSuccessBackground(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? Colors.green.shade50
        : Colors.green.shade900;

/// File contents, diffs and object names — the three things whose alignment
/// carries meaning.
TextStyle monospaceStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodyMedium!.copyWith(
          fontFamily: 'monospace',
          fontFamilyFallback: const [
            'Cascadia Mono',
            'Consolas',
            'Menlo',
            'DejaVu Sans Mono',
          ],
          height: 1.4,
        );

/// The colour a run of code is drawn in (`presentation.syntax-colour`).
///
/// Taken from Material's swatches for the current brightness, as the status
/// letters are: the scheme has semantic roles for surfaces and for emphasis,
/// and no opinion at all about how a string should differ from a comment.
///
/// Null means "no colour of its own" — ordinary code, which reads in the same
/// ink as the rest of the pane. Returning null rather than `onSurface` keeps
/// the caller from having to know that they are the same thing.
Color? syntaxColor(TokenKind kind, BuildContext context) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;

  Color shade(MaterialColor swatch) => dark ? swatch.shade300 : swatch.shade700;

  return switch (kind) {
    TokenKind.plain => null,
    TokenKind.comment => theme.colorScheme.onSurfaceVariant,
    TokenKind.string => shade(Colors.green),
    TokenKind.number => shade(Colors.orange),
    TokenKind.keyword => shade(Colors.purple),
    TokenKind.name => shade(Colors.teal),
    TokenKind.meta => shade(Colors.blue),
    // Structure should recede so that content comes forward, which means
    // dimmer than plain code rather than a colour of its own.
    TokenKind.punctuation => theme.colorScheme.onSurfaceVariant.withValues(
        alpha: 0.7,
      ),
  };
}
