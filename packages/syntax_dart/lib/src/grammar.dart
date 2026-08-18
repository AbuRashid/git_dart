import 'token.dart';

/// One thing a grammar recognises at the current position.
///
/// Patterns are matched anchored, at the offset the scanner has reached, so
/// they must not begin with `^` — position within the line is expressed by
/// which [Mode] is current, not by anchors.
class Rule {
  final RegExp pattern;
  final TokenKind kind;

  /// The mode to continue in after this match. Null keeps the current mode.
  final int? enter;

  /// Deepen the current mode rather than entering a new one. This exists for
  /// languages whose block comments nest — Dart's do — where a second `/*`
  /// must be counted rather than ignored.
  final bool nest;

  /// Leave the current mode: back one level of nesting if there is one, and
  /// otherwise back to the base mode.
  final bool exit;

  Rule(String pattern, this.kind, {this.enter, this.nest = false, this.exit = false})
      : pattern = RegExp(pattern, unicode: true),
        assert(
          (enter == null ? 0 : 1) + (nest ? 1 : 0) + (exit ? 1 : 0) <= 1,
          'a rule moves the scanner in at most one direction',
        );
}

/// A state the scanner can be in part-way through a line.
///
/// Modes exist for constructs that outlive the line they start on — a block
/// comment, a triple-quoted string, a fenced code block — and for positional
/// rules such as "a bare word here is a key, and after the first one it is
/// not". A construct that cannot span a line needs no mode: write it as one
/// regex instead.
class Mode {
  /// Tried in order at each position; the first that matches wins. Order is
  /// the whole of the precedence story, so keywords precede identifiers and
  /// timestamps precede numbers.
  final List<Rule> rules;

  /// What text no rule claims is called. Inside a comment mode this is
  /// [TokenKind.comment], so the body of a block comment needs no rule.
  final TokenKind fallback;

  /// Whether this mode continues onto the next line.
  ///
  /// True for constructs that genuinely span lines. False for modes that
  /// only track position within a line — a newline returns those to the base
  /// mode, which is what "a key-value pair ends at a separator" means for a
  /// scanner that sees one line at a time.
  final bool carry;

  const Mode(this.rules, {this.fallback = TokenKind.plain, this.carry = true});
}

/// A language, as a set of modes. `modes.first` is where every line of a
/// fresh file starts.
class Grammar {
  /// The name a user would recognise, for a status line or a picker.
  final String name;

  final List<Mode> modes;

  const Grammar(this.name, this.modes);
}

/// A pattern matching any of [words] as a whole word.
///
/// Longest first, so that alternation cannot settle for a prefix - the
/// trailing lookahead would force a backtrack anyway, but only after the
/// engine had tried and failed, and the ordering is free.
///
/// [alsoWord] names characters that count as part of a word beyond the usual
/// `[A-Za-z0-9_]`, so that `in` does not match inside `in_place`. They are
/// interpolated into a character class unescaped, so pass only characters
/// that are literal there: `$`, `.`, `/`, `+` are; `]`, `^` and `\` are not.
String keywords(Iterable<String> words, {String alsoWord = r'$'}) {
  final sorted = words.toList()..sort((a, b) => b.length.compareTo(a.length));
  return '(?:${sorted.map(RegExp.escape).join('|')})(?![A-Za-z0-9_$alsoWord])';
}
