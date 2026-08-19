import 'package:flutter/material.dart';

/// A colour for each kind of value a document can hold.
///
/// Supplied by the host rather than decided here, so that an application
/// showing the same document twice — once as source, once as a page — can
/// draw a symbol the same colour in both. A reader who has learned that
/// colour once should not have to learn it again one tab away.
///
/// [UnimsgPalette.of] is the fallback for a host with no opinion: Material's
/// own scheme, which at least agrees with the rest of the window.
class UnimsgPalette {
  /// A key, a term, a column heading — a name being given.
  final Color name;

  /// `:symbol` and the reserved literals, which are atoms from a closed
  /// vocabulary.
  final Color atom;

  /// `@identifier`, `-> reference`, `!extension`, `#hash`, `~bytes` — names
  /// that point outward at something else.
  final Color meta;

  /// Quoted text.
  final Color text;

  /// Numbers and timestamps.
  final Color number;

  /// Commentary, and anything else that recedes.
  final Color quiet;

  const UnimsgPalette({
    required this.name,
    required this.atom,
    required this.meta,
    required this.text,
    required this.number,
    required this.quiet,
  });

  factory UnimsgPalette.of(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    Color shade(MaterialColor swatch) =>
        dark ? swatch.shade300 : swatch.shade700;

    return UnimsgPalette(
      name: shade(Colors.teal),
      atom: shade(Colors.purple),
      meta: shade(Colors.blue),
      text: theme.colorScheme.onSurface,
      number: shade(Colors.orange),
      quiet: theme.colorScheme.onSurfaceVariant,
    );
  }
}
