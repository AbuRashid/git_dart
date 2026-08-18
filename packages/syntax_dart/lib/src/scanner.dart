import 'grammar.dart';
import 'token.dart';

/// Where the scanner is: the low bits hold the mode, the high bits the
/// nesting depth within it. One int, so a caller can keep one per line
/// cheaply, or snapshot and restore it — which is what scanning the two
/// sides of a diff needs.
const int _modeBits = 16;
const int _modeMask = (1 << _modeBits) - 1;

/// Reads a source file one line at a time, carrying across lines whatever
/// state the grammar needs.
///
/// The carried state is why this is a scanner and not a function: a line is
/// not independently tokenisable. `*/` means one thing after a `/*` two lines
/// up and another thing inside a string, and a highlighter that scans lines
/// in isolation gets both wrong. Feed lines in order.
class Scanner {
  final Grammar grammar;
  int _state;

  Scanner(this.grammar, {int state = 0}) : _state = state;

  /// The state the next line will start in — equivalently, the state this
  /// line started in, before any [scan].
  ///
  /// Public so callers can do the two things line-at-a-time highlighting
  /// wants. Record it per line and a lazily built list can re-scan any single
  /// line without re-scanning the file. Save and restore it and one grammar
  /// can follow two interleaved sequences, as the old and new sides of a diff
  /// are two interleaved sequences through one set of hunks.
  int get state => _state;
  set state(int value) => _state = value;

  /// Start again as though at the top of a file.
  void reset() => _state = 0;

  /// Tokenise one line, without its terminator, and advance [state].
  ///
  /// The result covers the line exactly: tokens are in order, do not overlap,
  /// leave no gap, and the last ends at `line.length`. Callers rendering the
  /// line can therefore concatenate token texts and get the line back, and
  /// need no separate path for the bits no grammar claimed.
  List<Token> scan(String line) {
    var mode = _state & _modeMask;
    var depth = _state >> _modeBits;
    if (mode >= grammar.modes.length) {
      mode = 0;
      depth = 0;
    }

    final tokens = <Token>[];
    var offset = 0;

    // Text no rule claims accumulates rather than emitting one token per
    // character: a line of prose should be one token, not eighty.
    var pendingStart = -1;
    var pendingKind = TokenKind.plain;

    void emit(int start, int end, TokenKind kind) {
      if (end <= start) return;
      if (tokens.isNotEmpty) {
        final last = tokens.last;
        if (last.end == start && last.kind == kind) {
          tokens[tokens.length - 1] = Token(last.start, end, kind);
          return;
        }
      }
      tokens.add(Token(start, end, kind));
    }

    void flush(int end) {
      if (pendingStart >= 0) emit(pendingStart, end, pendingKind);
      pendingStart = -1;
    }

    while (offset < line.length) {
      final current = grammar.modes[mode];

      Rule? hit;
      Match? match;
      for (final rule in current.rules) {
        final attempt = rule.pattern.matchAsPrefix(line, offset);
        // A rule that matches nothing would not advance, and a scanner that
        // does not advance does not terminate.
        if (attempt != null && attempt.end > offset) {
          hit = rule;
          match = attempt;
          break;
        }
      }

      if (hit == null) {
        if (pendingStart < 0) {
          pendingStart = offset;
          pendingKind = current.fallback;
        } else if (pendingKind != current.fallback) {
          flush(offset);
          pendingStart = offset;
          pendingKind = current.fallback;
        }
        offset += _runeLength(line, offset);
        continue;
      }

      flush(offset);
      emit(offset, match!.end, hit.kind);
      offset = match.end;

      if (hit.nest) {
        depth++;
      } else if (hit.exit) {
        if (depth > 0) {
          depth--;
        } else {
          mode = 0;
        }
      } else if (hit.enter != null) {
        mode = hit.enter!;
        depth = 0;
      }
    }

    flush(line.length);

    if (!grammar.modes[mode].carry) {
      mode = 0;
      depth = 0;
    }
    _state = mode | (depth << _modeBits);
    return tokens;
  }
}

/// How far to step over the character at [offset], so that a surrogate pair
/// is never split — an unclaimed emoji must not become two half tokens with
/// an offset between them that no substring may use.
int _runeLength(String line, int offset) {
  final unit = line.codeUnitAt(offset);
  if (unit >= 0xD800 && unit <= 0xDBFF && offset + 1 < line.length) {
    final next = line.codeUnitAt(offset + 1);
    if (next >= 0xDC00 && next <= 0xDFFF) return 2;
  }
  return 1;
}

/// Tokenise [lines] in order. One entry per line, in the same order.
List<List<Token>> scanLines(Grammar grammar, Iterable<String> lines) {
  final scanner = Scanner(grammar);
  return [for (final line in lines) scanner.scan(line)];
}

/// Tokenise a whole file, splitting it into lines first.
List<List<Token>> scanSource(Grammar grammar, String source) =>
    scanLines(grammar, splitLines(source));

/// Splits [source] into lines, dropping CRLF and LF terminators alike.
///
/// Not `String.split`, because a carriage return left at the end of a line
/// becomes a token nobody can see but every column measurement counts. Not
/// `dart:convert`'s LineSplitter either, which drops the empty last line of a
/// file that ends in a newline - the viewer shows that line, and a numbering
/// that disagrees with the editor's about how many lines a file has is worse
/// than useless.
Iterable<String> splitLines(String source) sync* {
  var start = 0;
  for (var i = 0; i < source.length; i++) {
    if (source.codeUnitAt(i) == 0x0A) {
      final end = (i > start && source.codeUnitAt(i - 1) == 0x0D) ? i - 1 : i;
      yield source.substring(start, end);
      start = i + 1;
    }
  }
  yield source.substring(start);
}
