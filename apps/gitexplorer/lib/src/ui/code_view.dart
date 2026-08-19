import 'package:flutter/material.dart';
import 'package:syntax_dart/syntax_dart.dart';
import 'package:unimsg_view/unimsg_view.dart';

import '../models.dart';
import '../theme.dart';

/// The colours for one brightness, resolved once rather than per token
/// (`presentation.syntax-colour`).
///
/// A line of code is thirty tokens and a pane is fifty lines, so asking the
/// theme for a colour at each of them is fifteen hundred lookups a frame for
/// eight distinct answers.
class SyntaxPalette {
  final Map<TokenKind, TextStyle?> _styles;

  const SyntaxPalette._(this._styles);

  factory SyntaxPalette.of(BuildContext context) => SyntaxPalette._({
        for (final kind in TokenKind.values)
          kind: switch (syntaxColor(kind, context)) {
            null => null,
            final color => TextStyle(color: color),
          },
      });

  /// Null for a kind with no colour of its own, which a [TextSpan] reads as
  /// "inherit", and which is what plain code should do.
  TextStyle? operator [](TokenKind kind) => _styles[kind];
}

/// One line, as a span tree.
///
/// The tokens tile the line, so this needs no separate path for text no rule
/// claimed; an empty [tokens] means the file has no grammar, and the line is
/// drawn plain.
TextSpan codeSpan(
  String line,
  List<Token> tokens,
  TextStyle base,
  SyntaxPalette palette,
) {
  if (tokens.isEmpty) return TextSpan(text: line, style: base);
  return TextSpan(
    style: base,
    children: [
      for (final token in tokens)
        TextSpan(text: token.textIn(line), style: palette[token.kind]),
    ],
  );
}

/// Highlighting for one file, held so that a lazily built list can colour any
/// line without scanning the ones above it again.
///
/// The state at the head of every line is worked out once, when the file is
/// opened; after that a single line can be re-scanned on its own. That costs
/// one integer per line rather than a token list per line, which for a file
/// long enough to matter is the difference that matters.
class CodeHighlighter {
  final Grammar? grammar;

  /// The scanner state each line begins in. Empty when there is no grammar.
  final List<int> _entryStates;

  final Scanner? _scanner;

  CodeHighlighter._(this.grammar, this._entryStates, this._scanner);

  factory CodeHighlighter(String path, List<String> lines) {
    final grammar = grammarForPath(path);
    // A file of an unknown type is drawn plain rather than drawn wrong.
    if (grammar == null) return CodeHighlighter._(null, const [], null);

    final scanner = Scanner(grammar);
    final states = List<int>.filled(lines.length, 0);
    for (var i = 0; i < lines.length; i++) {
      states[i] = scanner.state;
      scanner.scan(lines[i]);
    }
    return CodeHighlighter._(grammar, states, Scanner(grammar));
  }

  /// Whether anything is known about this file's type.
  bool get isHighlighting => grammar != null;

  /// The tokens for line [index], which must be the same text the highlighter
  /// was built from.
  List<Token> tokensFor(int index, String line) {
    final scanner = _scanner;
    if (scanner == null || index >= _entryStates.length) return const [];
    scanner.state = _entryStates[index];
    return scanner.scan(line);
  }
}

/// Highlighting for a diff, which is two sequences of lines interleaved.
///
/// A removed line continues the old side of the file and a added line the
/// new; a context line belongs to both and advances both. One scanner per
/// side keeps a block comment that only exists on one side from colouring the
/// other.
///
/// Each hunk starts from a clean state, since the lines between hunks were
/// not sent and there is nothing to carry across them. A hunk that begins
/// inside a block comment is therefore coloured as though it did not — the
/// only fix is the whole file, which is what a diff has chosen not to be.
class DiffHighlighter {
  final Grammar? grammar;
  Scanner? _oldSide;
  Scanner? _newSide;

  DiffHighlighter(String path) : grammar = grammarForPath(path) {
    startHunk();
  }

  void startHunk() {
    final grammar = this.grammar;
    if (grammar == null) return;
    _oldSide = Scanner(grammar);
    _newSide = Scanner(grammar);
  }

  List<Token> tokensFor(DiffLineData line) {
    final oldSide = _oldSide;
    final newSide = _newSide;
    if (oldSide == null || newSide == null) return const [];
    return switch (line.marker) {
      '-' => oldSide.scan(line.text),
      '+' => newSide.scan(line.text),
      // Context: both sides move on, and either answer will do.
      _ => [oldSide.scan(line.text), newSide.scan(line.text)].last,
    };
  }
}

/// A controller that colours what it holds
/// (`editing.the-editor-is-coloured-like-the-viewer`).
class HighlightingEditingController extends TextEditingController {
  /// The grammar for whatever file is open, or null for a type with no
  /// grammar. Set when the editor is filled, since one controller outlives
  /// many files.
  Grammar? grammar;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final grammar = this.grammar;
    // While an input method is composing, the base class draws the composing
    // region underlined, and that mark says more about what is happening than
    // the colours do. It lasts as long as the composition does.
    if (grammar == null || (withComposing && value.isComposingRangeValid)) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    final palette = SyntaxPalette.of(context);
    final scanner = Scanner(grammar);
    final children = <TextSpan>[];

    // Split on the newline alone and keep everything else, including a
    // carriage return before it: the spans have to add up to exactly the text
    // the field holds, or every caret position past the first difference is
    // wrong.
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) children.add(const TextSpan(text: '\n'));
      final line = lines[i];
      for (final token in scanner.scan(line)) {
        children.add(
          TextSpan(text: token.textIn(line), style: palette[token.kind]),
        );
      }
    }

    return TextSpan(style: style, children: children);
  }
}

/// The document view's colours, taken from the source view's
/// (`presentation.syntax-colour`).
///
/// The same file can be open as source or as a page, and a symbol should not
/// change colour between the two. A reader who has learned that purple means
/// an atom has learned it once.
UnimsgPalette documentPalette(BuildContext context) => UnimsgPalette(
      name: syntaxColor(TokenKind.name, context)!,
      atom: syntaxColor(TokenKind.keyword, context)!,
      meta: syntaxColor(TokenKind.meta, context)!,
      text: syntaxColor(TokenKind.string, context)!,
      number: syntaxColor(TokenKind.number, context)!,
      quiet: Theme.of(context).colorScheme.onSurfaceVariant,
    );
