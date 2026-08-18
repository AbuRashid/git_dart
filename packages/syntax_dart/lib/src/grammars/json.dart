import '../grammar.dart';
import '../token.dart';

const _blockComment = 1;

/// JSON, and the comment-tolerant dialect editors write config in. Strict
/// JSON has no comments, but a file with one in it is far likelier to be
/// jsonc than to be an error worth colouring as one.
final jsonGrammar = Grammar('json', [
  Mode([
    Rule(r'//.*', TokenKind.comment),
    Rule(r'/\*', TokenKind.comment, enter: _blockComment),

    // A string with a colon after it is a key. This is the whole of what
    // makes a JSON file skimmable, so it goes first.
    Rule(r'"(?:[^"\\]|\\.)*"(?=\s*:)', TokenKind.name),
    Rule(r'"(?:[^"\\]|\\.)*"', TokenKind.string),

    Rule(keywords(['true', 'false', 'null'], alsoWord: ''), TokenKind.keyword),
    Rule(r'-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?', TokenKind.number),

    Rule(r'[{}\[\],:]+', TokenKind.punctuation),
  ]),

  Mode(
    [Rule(r'\*/', TokenKind.comment, exit: true)],
    fallback: TokenKind.comment,
  ),
]);
