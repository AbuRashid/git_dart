# syntax_dart

A syntax tokeniser that reads one line at a time and carries what needs
carrying. Pure Dart, no dependencies, and no opinion about colour.

```dart
final grammar = grammarForPath('lib/main.dart')!;
final scanner = Scanner(grammar);
for (final line in splitLines(source)) {
  for (final token in scanner.scan(line)) {
    paint(token.textIn(line), token.kind);
  }
}
```

## Why line-at-a-time

A file viewer builds lines lazily and holds a gutter beside each one, so it
wants tokens per line. But a line is not independently tokenisable: `*/` means
one thing after a `/*` two lines up and another inside a string, and every
highlighter that scans lines in isolation gets block comments and multi-line
strings wrong.

`Scanner` resolves that by carrying one integer between lines. Feed lines in
order and the state follows. The integer is public, which buys two things a
viewer actually needs:

- **Lazy rendering.** Record the state at the head of each line and any single
  line can be re-scanned on its own later, without re-scanning the file.
- **Interleaved sequences.** Save and restore the state and one grammar can
  follow two sequences through the same file. That is exactly what a diff is —
  the old side and the new side are two interleaved runs through one set of
  hunks — so both sides can be highlighted correctly from one grammar.

A diff also has a limit worth stating: hunks are not contiguous, so a hunk
that begins inside a block comment starts from a clean state and is coloured
as though it did not. Nothing short of the whole file fixes that, and the
whole file is the thing a diff has chosen not to send.

## Kinds

Eight, and no more: `plain`, `comment`, `string`, `number`, `keyword`, `name`,
`meta`, `punctuation`. A kind exists only if a reader would draw it
differently from every other kind. `name` is a name being given — a
declaration, a key, a heading, a table header — and it is the one that makes a
file skimmable. `meta` is a name qualified by a sigil, pointing outward at
something else.

Grammars that distinguish more than this internally collapse the distinction
on the way out, which keeps the palette small enough to learn.

## Languages

unimsg, Dart, JavaScript, TypeScript, Go, Rust, Java, Kotlin, Swift, C#, C and
C++, Python, JSON, YAML, Markdown, and shell.

`grammarForPath` takes a whole path, because the answer sometimes needs the
whole file name: `Makefile` and `.gitignore` have no extension, and
`pubspec.lock` has one that means nothing. It returns null for a type with no
grammar, so a caller can draw the file plain rather than draw it wrong.

## Adding a grammar

A grammar is a list of `Mode`s, each a list of ordered `Rule`s. The first rule
that matches at the current offset wins, so order carries the whole of
precedence: keywords before identifiers, timestamps before numbers, comments
before the punctuation rule that would otherwise take the slash.

A mode exists for constructs that outlive a line — a block comment, a
triple-quoted string, a fenced code block — and for positional rules, where
what a token means depends on what came before it on the line. `Mode.carry`
says which: true for constructs that genuinely span lines, false for modes
that only track position, which a newline resets. unimsg uses three positional
modes to decide whether a bare word is a key, an annotation or a table header.

A construct that cannot span a line needs no mode at all. Write it as one
regular expression instead.

Rules are matched anchored at the current offset, so patterns must not begin
with `^`. `nest` and `exit` handle languages whose block comments count their
opens — Dart's, Rust's, Swift's and Kotlin's do; C's and Java's do not.

## Invariants

The tokens for a line are in order, do not overlap, leave no gap, and end at
`line.length`. Concatenating their texts gives the line back. A caller drawing
a line therefore needs no separate path for the text no rule claimed, and a
gap in a grammar shows up as a dropped character rather than as silence — the
test suite checks this over every file in the repository this package was
written for.
