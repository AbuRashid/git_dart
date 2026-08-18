import '../grammar.dart';
import '../token.dart';

final yamlGrammar = Grammar('yaml', [
  Mode([
    Rule(r'#.*', TokenKind.comment),

    // Document markers.
    Rule(r'---|\.\.\.', TokenKind.punctuation),

    // A key is a plain scalar whose colon is followed by space or end of
    // line. The second half of that is what keeps `http://example.com` from
    // reading as a key named `http`, which is the mistake every simple YAML
    // highlighter makes.
    Rule(r'[^\s:#][^\s:]*(?=\s*:(?:\s|$))', TokenKind.name),

    Rule(r'"(?:[^"\\]|\\.)*"', TokenKind.string),
    Rule(r"'(?:[^']|'')*'", TokenKind.string),

    // Anchors, aliases and tags: names that point at something else.
    Rule(r'[&*][\w.-]+', TokenKind.meta),
    Rule(r'!{1,2}[\w:/.-]*', TokenKind.meta),

    Rule(
      keywords(
        ['true', 'false', 'null', 'yes', 'no', 'on', 'off',
         'True', 'False', 'Null', 'Yes', 'No', 'On', 'Off'],
        alsoWord: '.-',
      ),
      TokenKind.keyword,
    ),
    Rule(r'~(?![\w.-])', TokenKind.keyword),

    Rule(r'-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?(?![\w.-])', TokenKind.number),

    // A list marker, and the block scalar indicators. The body of a block
    // scalar is left plain: knowing where it ends means tracking indentation,
    // which is more state than this owes a reader.
    Rule(r'-(?=\s|$)', TokenKind.punctuation),
    Rule(r'[|>][+-]?\d*(?=\s*$)', TokenKind.punctuation),
    Rule(r'[{}\[\],:?]+', TokenKind.punctuation),
  ]),
]);
