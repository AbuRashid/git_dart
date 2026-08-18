import '../grammar.dart';
import '../token.dart';

const _keywords = [
  'False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await', 'break',
  'case', 'class', 'continue', 'def', 'del', 'elif', 'else', 'except',
  'finally', 'for', 'from', 'global', 'if', 'import', 'in', 'is', 'lambda',
  'match', 'nonlocal', 'not', 'or', 'pass', 'raise', 'return', 'self', 'try',
  'while', 'with', 'yield',
];

/// The prefixes a string literal may carry: raw, bytes, unicode, formatted,
/// in any order and any case.
const _prefix = '[rRbBuUfF]*';

const _singleQuotedBlock = 1;
const _doubleQuotedBlock = 2;

final pythonGrammar = Grammar('python', [
  Mode([
    Rule(r'#.*', TokenKind.comment),

    // Triple quotes before single, or a docstring lexes as an empty string.
    Rule("$_prefix'''", TokenKind.string, enter: _singleQuotedBlock),
    Rule('$_prefix"""', TokenKind.string, enter: _doubleQuotedBlock),
    Rule("$_prefix'(?:[^'\\\\]|\\\\.)*'", TokenKind.string),
    Rule('$_prefix"(?:[^"\\\\]|\\\\.)*"', TokenKind.string),

    Rule(r'@[A-Za-z_][A-Za-z0-9_.]*', TokenKind.meta),

    Rule(r'0[xXbBoO][0-9a-fA-F_]+', TokenKind.number),
    Rule(r'\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?j?', TokenKind.number),

    Rule(keywords(_keywords, alsoWord: ''), TokenKind.keyword),

    // Classes and exceptions are capitalised by convention firm enough to
    // colour by; function names are not, and are left alone rather than
    // guessed at.
    Rule(r'[A-Z][A-Za-z0-9_]*', TokenKind.name),
    Rule(r'[A-Za-z_][A-Za-z0-9_]*', TokenKind.plain),

    Rule(r'[{}()\[\];,.:=+*/%&|^~<>!-]+', TokenKind.punctuation),
  ]),

  Mode(
    [
      Rule(r'\\.', TokenKind.string),
      Rule("'''", TokenKind.string, exit: true),
    ],
    fallback: TokenKind.string,
  ),

  Mode(
    [
      Rule(r'\\.', TokenKind.string),
      Rule('"""', TokenKind.string, exit: true),
    ],
    fallback: TokenKind.string,
  ),
]);
