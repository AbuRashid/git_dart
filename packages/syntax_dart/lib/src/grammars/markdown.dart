import '../grammar.dart';
import '../token.dart';

const _fencedCode = 1;

/// Markdown, restrained on purpose.
///
/// Headings, code and links are what a reader scans a Markdown file for, and
/// they are also the three things that can be recognised without ambiguity.
/// Emphasis is deliberately left alone: `*` is too common in prose for the
/// guess to be worth the colour it would spend.
final markdownGrammar = Grammar('markdown', [
  Mode([
    // A fence opener takes its info string with it, so the language name
    // does not read as prose.
    Rule('(?:```|~~~)[^`]*', TokenKind.meta, enter: _fencedCode),

    // The space is required, so that `#4` and `#tag` stay prose.
    Rule(r'#{1,6}\s.*', TokenKind.name),

    Rule(r'`+[^`]*`+', TokenKind.string),

    // Links and images, inline and reference form, and bare autolinks.
    Rule(r'!?\[[^\]]*\]\([^)]*\)', TokenKind.meta),
    Rule(r'!?\[[^\]]*\]\[[^\]]*\]', TokenKind.meta),
    Rule(r'<[A-Za-z][A-Za-z0-9+.-]*:[^ >]*>', TokenKind.meta),

    // A thematic break, or a setext underline. Same glyphs, and at this
    // altitude the same thing: a rule across the page.
    Rule(r'(?:-{3,}|={3,}|\*{3,})\s*$', TokenKind.punctuation),

    Rule(r'>\s?', TokenKind.punctuation),
    Rule(r'[-*+](?=\s)', TokenKind.punctuation),
    Rule(r'\d+\.(?=\s)', TokenKind.punctuation),

    // Raw HTML, which Markdown permits and which is structure rather than
    // prose.
    Rule(r'</?[A-Za-z][^>]*>', TokenKind.punctuation),
  ]),

  // Inside a fence the content belongs to another language. Highlighting it
  // would mean dispatching on the info string, which is a real feature and
  // not this one; leaving it plain is at least never wrong.
  Mode(
    [Rule('(?:```|~~~)', TokenKind.meta, exit: true)],
    fallback: TokenKind.plain,
  ),
]);
