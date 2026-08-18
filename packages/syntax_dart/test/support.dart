import 'package:syntax_dart/syntax_dart.dart';

/// One line, as `kind:text` per token — readable enough to write an
/// expectation by hand and specific enough that a wrong colour fails.
List<String> render(List<Token> tokens, String line) =>
    [for (final token in tokens) '${token.kind.name}:${token.textIn(line)}'];

/// [render] for a line scanned from a standing start.
List<String> kinds(Grammar grammar, String line) =>
    render(Scanner(grammar).scan(line), line);

/// The last token of a line, for the many cases where the interesting token
/// is at the end and the lead-in is only there to put it in position.
String last(Grammar grammar, String line) => kinds(grammar, line).last;
