/// A line-at-a-time syntax tokeniser.
///
/// Pick a grammar with [grammarForPath], then feed lines to a [Scanner] in
/// order. The scanner carries whatever state spans lines, so a block comment
/// or a string that opens on one line and closes on another is coloured
/// correctly without the caller holding a whole file in mind:
///
/// ```dart
/// final scanner = Scanner(grammarForPath('lib/main.dart')!);
/// for (final line in splitLines(source)) {
///   for (final token in scanner.scan(line)) {
///     paint(token.textIn(line), token.kind);
///   }
/// }
/// ```
///
/// Nothing here knows about colour. A [TokenKind] is a claim about what a run
/// of text *is*; what that should look like belongs to whatever is drawing,
/// which is the only thing that knows whether the background is dark.
library;

export 'src/grammar.dart' show Grammar, Mode, Rule, keywords;
export 'src/languages.dart';
export 'src/scanner.dart';
export 'src/token.dart';
