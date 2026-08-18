import '../grammar.dart';
import '../token.dart';

const _keywords = [
  'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case',
  'catch', 'class', 'const', 'continue', 'covariant', 'default', 'deferred',
  'do', 'dynamic', 'else', 'enum', 'export', 'extends', 'extension',
  'external', 'factory', 'false', 'final', 'finally', 'for', 'get', 'hide',
  'if', 'implements', 'import', 'in', 'interface', 'is', 'late', 'library',
  'mixin', 'new', 'null', 'on', 'operator', 'part', 'required', 'rethrow',
  'return', 'sealed', 'set', 'show', 'static', 'super', 'switch', 'sync',
  'this', 'throw', 'true', 'try', 'typedef', 'var', 'void', 'when', 'while',
  'with', 'yield',
];

const _blockComment = 1;
const _singleQuotedBlock = 2;
const _doubleQuotedBlock = 3;

/// Dart, including the two things a line-blind highlighter gets wrong:
/// nesting block comments and triple-quoted strings.
final dartGrammar = Grammar('dart', [
  Mode([
    // Before the punctuation rule, which would otherwise take the slash.
    Rule(r'///.*', TokenKind.comment),
    Rule(r'//.*', TokenKind.comment),
    Rule(r'/\*', TokenKind.comment, enter: _blockComment),

    // Triple quotes first: `'''` would otherwise lex as an empty string
    // followed by a stray quote.
    Rule(r"r?'''", TokenKind.string, enter: _singleQuotedBlock),
    Rule(r'r?"""', TokenKind.string, enter: _doubleQuotedBlock),
    Rule(r"r?'(?:[^'\\]|\\.)*'", TokenKind.string),
    Rule(r'r?"(?:[^"\\]|\\.)*"', TokenKind.string),

    Rule(r'@[A-Za-z_$][A-Za-z0-9_$]*', TokenKind.meta),

    Rule(r'0[xX][0-9a-fA-F_]+', TokenKind.number),
    Rule(r'\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?', TokenKind.number),

    Rule(keywords(_keywords), TokenKind.keyword),

    // Dart's convention is strong enough to lean on: a capitalised name is a
    // type, and types are the names worth picking out of a page of Dart.
    Rule(r'[A-Z][A-Za-z0-9_$]*', TokenKind.name),
    Rule(r'[A-Za-z_$][A-Za-z0-9_$]*', TokenKind.plain),

    Rule(r'[{}()\[\];,.:?!<>=+*/%&|^~-]+', TokenKind.punctuation),
  ]),

  // Dart's block comments nest, so the close has to be counted rather than
  // taken as the end of the outermost comment.
  Mode(
    [
      Rule(r'/\*', TokenKind.comment, nest: true),
      Rule(r'\*/', TokenKind.comment, exit: true),
    ],
    fallback: TokenKind.comment,
  ),

  Mode(
    [
      Rule(r'\\.', TokenKind.string),
      Rule(r"'''", TokenKind.string, exit: true),
    ],
    fallback: TokenKind.string,
  ),

  Mode(
    [
      Rule(r'\\.', TokenKind.string),
      Rule(r'"""', TokenKind.string, exit: true),
    ],
    fallback: TokenKind.string,
  ),
]);
