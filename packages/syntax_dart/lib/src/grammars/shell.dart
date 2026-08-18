import '../grammar.dart';
import '../token.dart';

const _keywords = [
  'alias', 'break', 'case', 'continue', 'declare', 'do', 'done', 'elif',
  'else', 'esac', 'eval', 'exec', 'exit', 'export', 'fi', 'for', 'function',
  'if', 'in', 'local', 'readonly', 'return', 'select', 'set', 'shift',
  'source', 'then', 'trap', 'unset', 'until', 'while',
];

/// Shell, and by extension the several dotfile formats that borrow its
/// comment character. A `.gitignore` gets comments and nothing else, which
/// is all a `.gitignore` has.
final shellGrammar = Grammar('shell', [
  Mode([
    // The shebang is not a comment: it says what will run the file, which is
    // the most important line in it.
    Rule(r'#!.*', TokenKind.meta),
    Rule(r'#.*', TokenKind.comment),

    Rule(r'"(?:[^"\\]|\\.)*"', TokenKind.string),
    Rule(r"'[^']*'", TokenKind.string),

    // Expansions, in the four spellings that matter.
    Rule(r'\$\{[^}]*\}', TokenKind.meta),
    Rule(r'\$\([^)]*\)', TokenKind.meta),
    Rule(r'\$[A-Za-z_][A-Za-z0-9_]*', TokenKind.meta),
    Rule(r'\$[0-9@*#?$!-]', TokenKind.meta),

    // An assignment names something; a bare word does not.
    Rule(r'[A-Za-z_][A-Za-z0-9_]*(?==[^=])', TokenKind.name),

    Rule(keywords(_keywords, alsoWord: '-'), TokenKind.keyword),

    // A long or short option, which reads as part of the command rather than
    // as an operand.
    Rule(r'(?<=\s)--?[A-Za-z][A-Za-z0-9-]*', TokenKind.meta),

    Rule(r'\d+(?![\w.-])', TokenKind.number),

    Rule(r'[{}()\[\];,|&<>=+*/%!~-]+', TokenKind.punctuation),
  ]),
]);
