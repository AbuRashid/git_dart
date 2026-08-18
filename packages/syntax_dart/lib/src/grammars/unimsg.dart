import '../grammar.dart';
import '../token.dart';

// The rules below follow the lexical section of unimsg-v0.umsg and the
// reference lexer in packages/unimsg. Where a highlighter must guess at
// something the parser knows for certain, the guess is named in a comment
// beside it, so the next reader can tell a simplification from a bug.

/// What may appear in a bare word, key, symbol name or sigil payload:
/// Unicode letters, digits and marks, plus five punctuation marks. Marks are
/// in the set deliberately — without them the affricate d͡ʒ and every
/// pointed Arabic form are unwritable.
const _word = r'[\p{L}\p{N}\p{M}_./+-]';

/// After `#` and `~` the payload additionally admits `:` and `=`, so that
/// `#sha256:9f2a` and `~b64:iVBORw0KGgo=` are each one token.
const _payload = r'[\p{L}\p{N}\p{M}_./+:=-]';

/// Nothing that could continue a word follows. Used to keep `inf` out of
/// `infrastructure` and `null` out of `null-safe`.
const _boundary = r'(?![\p{L}\p{N}\p{M}_./+-])';

/// A string from its opening quote to its closing one, on this line. The
/// body cannot contain a bare quote, so the match cannot run past the close
/// even though the quantifier is greedy.
const _string = r'"(?:[^"\\]|\\.)*"';

/// Tried before numbers, since 2026-08-03 would otherwise lex as 2026
/// followed by an unexpected `-`. At least YYYY-MM is required, so a bare
/// year stays an integer.
const _timestamp =
    r'\d{4}-\d{2}(?:-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?'
    r'(?:Z|[+-]\d{2}:\d{2})?)?)?';

/// A leading `-` begins a number only when a digit follows; otherwise it
/// belongs to a word such as `by-sequence`.
const _number = r'-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?f?';

/// Bare words that are values rather than annotations — a fixed lexical
/// list, so no colouring here is value-dependent.
const _literals = '(?:-inf|false|null|true|nan|inf)$_boundary';

// The modes. A unimsg line is not context-free at the level a highlighter
// works at: whether a bare word is a key, an annotation or a table header
// depends on what came before it on the line. Three positional modes carry
// exactly that much, and no more.

/// Where a pair begins: at the start of a line, after `{`, and after a comma.
/// A bare word here is a key.
const _keyPosition = 0;

/// After the key: annotations, then one value. A bare word here annotates.
const _valuePosition = 1;

/// Inside a table row, after `|`. A bare word here is a header cell, which
/// is a key — data cells are almost never bare words, because the format
/// says a bare word is never a value.
const _rowPosition = 2;

/// Inside a string that has not closed on the line it opened.
const _stringBody = 3;

/// The rules shared by the three positional modes, which differ only in what
/// a bare word and a quoted string mean and in where they go next.
List<Rule> _positional({
  required TokenKind word,
  required TokenKind quoted,
  required int after,
}) =>
    [
      // Before anything else: `-` and `>` are both word runes, so without
      // these two first, `-- a note` and `-> @name` lex as words.
      Rule(r'--.*', TokenKind.comment),
      Rule(r'->[ \t]*@' '$_word+', TokenKind.meta, enter: after),
      Rule(r'->', TokenKind.meta, enter: after),

      // The header is one line and only valid on the first, but a stray `%`
      // is not valid anywhere else either, so one rule covers both.
      Rule(r'%.*', TokenKind.meta),

      Rule(r'\{', TokenKind.punctuation, enter: _keyPosition),
      Rule(r',', TokenKind.punctuation, enter: _keyPosition),
      // A sequence holds values, not pairs.
      Rule(r'\[', TokenKind.punctuation, enter: _valuePosition),
      Rule(r'[}\]]', TokenKind.punctuation, enter: after),
      Rule(r'\|', TokenKind.punctuation, enter: _rowPosition),

      Rule(_string, quoted, enter: after),
      // An unclosed quote: a string may span lines, so this is ordinary.
      Rule(r'"', TokenKind.string, enter: _stringBody),

      Rule(_literals, TokenKind.keyword, enter: after),

      // Symbols sit with the reserved literals rather than with the other
      // sigils: both are atoms drawn from a closed vocabulary, and that is
      // what a reader is picking out when they scan for either.
      Rule(':$_string', TokenKind.keyword, enter: after),
      Rule(':$_word+', TokenKind.keyword, enter: after),

      // The sigils that point outward at something else.
      Rule('@$_word+', TokenKind.meta, enter: after),
      Rule('!$_word+', TokenKind.meta, enter: after),
      Rule('#$_payload+', TokenKind.meta, enter: after),
      Rule('~$_payload+', TokenKind.meta, enter: after),

      Rule(_timestamp, TokenKind.number, enter: after),
      Rule(_number, TokenKind.number, enter: after),
      Rule('$_word+', word, enter: after),
    ];

/// unimsg v0 — the text syntax described by unimsg-v0.umsg.
final unimsgGrammar = Grammar('unimsg', [
  // A fresh line expects a key, so this mode carries.
  Mode(_positional(
    word: TokenKind.name,
    quoted: TokenKind.name,
    after: _valuePosition,
  )),

  // A pair ends at a separator, and a newline is a separator: a value may
  // not begin on the line after its key. So this mode does not carry, and
  // the next line starts expecting a key again.
  Mode(
    _positional(
      word: TokenKind.plain,
      quoted: TokenKind.string,
      after: _valuePosition,
    ),
    carry: false,
  ),

  // A row likewise ends at the newline.
  Mode(
    _positional(
      word: TokenKind.name,
      quoted: TokenKind.string,
      after: _rowPosition,
    ),
    carry: false,
  ),

  // Inside a multi-line string, only the escape and the closing quote
  // matter; everything else is body, which the fallback covers.
  Mode(
    [
      Rule(r'\\.', TokenKind.string),
      Rule(r'"', TokenKind.string, exit: true),
    ],
    fallback: TokenKind.string,
  ),
]);
