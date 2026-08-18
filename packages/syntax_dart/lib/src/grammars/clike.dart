import '../grammar.dart';
import '../token.dart';

// One shape covers this whole family: `//` and `/* */`, quoted strings,
// C-style numbers, a keyword list. What differs between the members is small
// enough to be arguments, so it is arguments — nine near-identical grammars
// written out longhand would drift apart at the first fix.

const _blockComment = 1;
const _template = 2;

Grammar _clike(
  String name,
  List<String> words, {
  /// Rust, Swift and Kotlin count `/*` inside a block comment; C and Java
  /// do not, and treat the first `*/` as the end.
  bool nestingComments = false,

  /// `#include`, `#define`, `#if` — a line, not an expression.
  bool preprocessor = false,

  /// `@Override`, `@Component`.
  bool annotations = false,

  /// Backtick template literals, which may span lines.
  bool templates = false,
}) =>
    Grammar(name, [
      Mode([
        Rule(r'//.*', TokenKind.comment),
        Rule(r'/\*', TokenKind.comment, enter: _blockComment),

        if (preprocessor) Rule(r'#[A-Za-z_]\w*', TokenKind.meta),
        if (annotations) Rule(r'@[A-Za-z_$][A-Za-z0-9_$.]*', TokenKind.meta),

        if (templates) Rule(r'`', TokenKind.string, enter: _template),
        Rule(r'"(?:[^"\\]|\\.)*"', TokenKind.string),
        Rule(r"'(?:[^'\\]|\\.)*'", TokenKind.string),

        Rule(r'0[xXbBoO][0-9a-fA-F_]+', TokenKind.number),
        Rule(r'\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?[a-zA-Z_]*', TokenKind.number),

        Rule(keywords(words), TokenKind.keyword),
        Rule(r'[A-Z][A-Za-z0-9_$]*', TokenKind.name),
        Rule(r'[A-Za-z_$][A-Za-z0-9_$]*', TokenKind.plain),

        Rule(r'[{}()\[\];,.:?!<>=+*/%&|^~@#-]+', TokenKind.punctuation),
      ]),

      Mode(
        [
          if (nestingComments) Rule(r'/\*', TokenKind.comment, nest: true),
          Rule(r'\*/', TokenKind.comment, exit: true),
        ],
        fallback: TokenKind.comment,
      ),

      Mode(
        [
          Rule(r'\\.', TokenKind.string),
          Rule(r'`', TokenKind.string, exit: true),
        ],
        fallback: TokenKind.string,
      ),
    ]);

const _javascript = [
  'as', 'async', 'await', 'break', 'case', 'catch', 'class', 'const',
  'continue', 'debugger', 'default', 'delete', 'do', 'else', 'export',
  'extends', 'false', 'finally', 'for', 'from', 'function', 'get', 'if',
  'import', 'in', 'instanceof', 'let', 'new', 'null', 'of', 'return', 'set',
  'static', 'super', 'switch', 'this', 'throw', 'true', 'try', 'typeof',
  'undefined', 'var', 'void', 'while', 'with', 'yield',
];

const _typescriptOnly = [
  'abstract', 'any', 'asserts', 'boolean', 'declare', 'enum', 'implements',
  'infer', 'interface', 'is', 'keyof', 'namespace', 'never', 'number',
  'object', 'private', 'protected', 'public', 'readonly', 'satisfies',
  'string', 'symbol', 'type', 'unknown',
];

const _go = [
  'break', 'case', 'chan', 'const', 'continue', 'default', 'defer', 'else',
  'fallthrough', 'false', 'for', 'func', 'go', 'goto', 'if', 'import',
  'interface', 'iota', 'map', 'nil', 'package', 'range', 'return', 'select',
  'struct', 'switch', 'true', 'type', 'var',
  'bool', 'byte', 'error', 'float32', 'float64', 'int', 'int8', 'int16',
  'int32', 'int64', 'rune', 'string', 'uint', 'uint8', 'uint16', 'uint32',
  'uint64', 'uintptr',
];

const _rust = [
  'as', 'async', 'await', 'break', 'const', 'continue', 'crate', 'dyn',
  'else', 'enum', 'extern', 'false', 'fn', 'for', 'if', 'impl', 'in', 'let',
  'loop', 'match', 'mod', 'move', 'mut', 'pub', 'ref', 'return', 'self',
  'static', 'struct', 'super', 'trait', 'true', 'type', 'unsafe', 'use',
  'where', 'while',
];

const _java = [
  'abstract', 'assert', 'boolean', 'break', 'byte', 'case', 'catch', 'char',
  'class', 'const', 'continue', 'default', 'do', 'double', 'else', 'enum',
  'extends', 'false', 'final', 'finally', 'float', 'for', 'goto', 'if',
  'implements', 'import', 'instanceof', 'int', 'interface', 'long', 'native',
  'new', 'null', 'package', 'permits', 'private', 'protected', 'public',
  'record', 'return', 'sealed', 'short', 'static', 'strictfp', 'super',
  'switch', 'synchronized', 'this', 'throw', 'throws', 'transient', 'true',
  'try', 'var', 'void', 'volatile', 'while', 'yield',
];

const _kotlin = [
  'as', 'break', 'by', 'catch', 'class', 'companion', 'const', 'constructor',
  'continue', 'crossinline', 'data', 'do', 'else', 'enum', 'external',
  'false', 'final', 'finally', 'for', 'fun', 'get', 'if', 'import', 'in',
  'infix', 'init', 'inline', 'interface', 'internal', 'is', 'lateinit',
  'null', 'object', 'open', 'operator', 'out', 'override', 'package',
  'private', 'protected', 'public', 'reified', 'return', 'sealed', 'set',
  'super', 'suspend', 'this', 'throw', 'true', 'try', 'typealias', 'val',
  'var', 'vararg', 'when', 'where', 'while',
];

const _swift = [
  'any', 'as', 'associatedtype', 'async', 'await', 'break', 'case', 'catch',
  'class', 'continue', 'default', 'defer', 'deinit', 'do', 'else', 'enum',
  'extension', 'fallthrough', 'false', 'fileprivate', 'final', 'for', 'func',
  'guard', 'if', 'import', 'in', 'init', 'inout', 'internal', 'is', 'lazy',
  'let', 'mutating', 'nil', 'open', 'operator', 'private', 'protocol',
  'public', 'repeat', 'return', 'self', 'static', 'struct', 'subscript',
  'super', 'switch', 'throw', 'throws', 'true', 'try', 'typealias', 'var',
  'weak', 'where', 'while',
];

const _csharp = [
  'abstract', 'as', 'async', 'await', 'base', 'bool', 'break', 'byte', 'case',
  'catch', 'char', 'checked', 'class', 'const', 'continue', 'decimal',
  'default', 'delegate', 'do', 'double', 'else', 'enum', 'event', 'explicit',
  'extern', 'false', 'finally', 'fixed', 'float', 'for', 'foreach', 'get',
  'goto', 'if', 'implicit', 'in', 'int', 'interface', 'internal', 'is',
  'lock', 'long', 'namespace', 'new', 'null', 'object', 'operator', 'out',
  'override', 'params', 'private', 'protected', 'public', 'readonly',
  'record', 'ref', 'return', 'sbyte', 'sealed', 'set', 'short', 'sizeof',
  'stackalloc', 'static', 'string', 'struct', 'switch', 'this', 'throw',
  'true', 'try', 'typeof', 'uint', 'ulong', 'unchecked', 'unsafe', 'ushort',
  'using', 'var', 'virtual', 'void', 'volatile', 'while', 'yield',
];

const _c = [
  'alignas', 'alignof', 'auto', 'bool', 'break', 'case', 'catch', 'char',
  'class', 'const', 'const_cast', 'constexpr', 'continue', 'decltype',
  'default', 'delete', 'do', 'double', 'dynamic_cast', 'else', 'enum',
  'explicit', 'extern', 'false', 'float', 'for', 'friend', 'goto', 'if',
  'inline', 'int', 'long', 'mutable', 'namespace', 'new', 'noexcept',
  'nullptr', 'operator', 'override', 'private', 'protected', 'public',
  'register', 'reinterpret_cast', 'restrict', 'return', 'short', 'signed',
  'sizeof', 'static', 'static_cast', 'struct', 'switch', 'template', 'this',
  'throw', 'true', 'try', 'typedef', 'typename', 'union', 'unsigned',
  'using', 'virtual', 'void', 'volatile', 'while',
];

final clikeGrammars = <Grammar>[
  _clike('javascript', _javascript, templates: true),
  _clike('typescript', [..._javascript, ..._typescriptOnly],
      templates: true, annotations: true),
  _clike('go', _go),
  _clike('rust', _rust, nestingComments: true, annotations: true),
  _clike('java', _java, annotations: true),
  _clike('kotlin', _kotlin, nestingComments: true, annotations: true),
  _clike('swift', _swift, nestingComments: true, annotations: true),
  _clike('csharp', _csharp, preprocessor: true, annotations: true),
  _clike('c', _c, preprocessor: true),
];

/// The file extensions each of the above claims. C and C++ share a grammar:
/// the keyword list is the union, which mislabels nothing a reader of either
/// language would notice, and `.h` is genuinely ambiguous anyway.
const clikeExtensions = <String, List<String>>{
  'javascript': ['js', 'jsx', 'mjs', 'cjs'],
  'typescript': ['ts', 'tsx', 'mts', 'cts'],
  'go': ['go'],
  'rust': ['rs'],
  'java': ['java'],
  'kotlin': ['kt', 'kts'],
  'swift': ['swift'],
  'csharp': ['cs'],
  'c': ['c', 'h', 'cc', 'cpp', 'cxx', 'hpp', 'hh', 'hxx', 'm', 'mm'],
};
