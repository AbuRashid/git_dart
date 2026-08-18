/// What a run of text is, coarsely enough that every grammar can answer.
///
/// The list is deliberately short. A kind exists only if some reader would
/// colour it differently from every other kind, because a palette a reader
/// cannot hold in their head is decoration rather than information. Grammars
/// that distinguish more than this internally are expected to collapse the
/// distinction on the way out.
enum TokenKind {
  /// Ordinary text: identifiers, operands, prose.
  plain,

  /// A comment, in any of the spellings a language offers.
  comment,

  /// A quoted string, including its delimiters and escapes.
  string,

  /// A numeric literal, and anything spelled like one — a timestamp, a
  /// version, a colour.
  number,

  /// A word the language reserves, including the literals `true`, `false`
  /// and `null` that behave like reserved words even where they are values.
  keyword,

  /// A name being *given* rather than used: a declaration, a map key, a
  /// heading, a table header cell. This is the kind that makes a file
  /// skimmable, so grammars should spend effort here before anywhere else.
  name,

  /// A name qualified by a sigil — an annotation, a reference, a tag, a
  /// symbol, a preprocessor directive. Distinct from [name] because it
  /// points outward at something else rather than declaring something here.
  meta,

  /// Brackets, separators and operators. Usually drawn dimmer than [plain]
  /// so structure recedes and content comes forward.
  punctuation,
}

/// One run of [kind], covering `line.substring(start, end)`.
///
/// Offsets are into a single line and are code-unit indices, matching
/// `String.substring` and the offsets a text layout wants. Tokens for a line
/// are emitted in order, never overlap, and together cover the whole line —
/// see `Scanner.scan`, which owes that guarantee to its callers.
class Token {
  final int start;
  final int end;
  final TokenKind kind;

  const Token(this.start, this.end, this.kind);

  int get length => end - start;

  /// The text this token covers, given the line it was scanned from.
  String textIn(String line) => line.substring(start, end);

  @override
  bool operator ==(Object other) =>
      other is Token &&
      other.start == start &&
      other.end == end &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(start, end, kind);

  @override
  String toString() => '${kind.name}($start,$end)';
}
