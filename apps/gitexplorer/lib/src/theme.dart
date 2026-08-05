import 'package:flutter/material.dart';

import 'generated/tokens.dart';

/// Stock Material, light and dark.
///
/// No palette, no metrics, no type scale: Material has all three, and an
/// application that redefines them has to maintain them and stops looking like
/// everything else on the machine (`presentation.doc`).
ThemeData explorerTheme(Brightness brightness) => ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.indigo,
        brightness: brightness,
      ),
      useMaterial3: true,
    );

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
