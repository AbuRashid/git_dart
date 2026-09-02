# unimsg for Notepad++

A User Defined Language for `.umsg` files. Two files, light and dark —
Notepad++ shows whichever matches the mode it is in, so install both.

```bash
cp editors/notepad++/*.udl.xml "$APPDATA/Notepad++/userDefineLangs/"
```

Then restart Notepad++. `.umsg` files are recognised by extension; nothing
else needs setting.

## Dark mode

The UDL does not set the background, and the dark variant does not either. A
UDL style carries a `colorStyle` saying which of its two colours to apply — 0
neither, 1 the foreground, 3 both — and every style in both files is 0 or 1.
The `bgColor` values sit there inert.

The background is Notepad++'s, from **Settings → Preferences → Dark Mode**.
Turn that on and the editor goes dark *and* Notepad++ switches to
`unimsg_DM.udl.xml`, whose foregrounds are the same Material swatches one step
lighter. That is what `darkModeTheme="yes"` in the dark file selects on.

This is deliberate. A language that painted its own background would fight
whatever theme you chose and would be the only file in the editor that did.
The `bgColor` values are kept, as the preinstalled Markdown UDL keeps them, so
there is something sensible to switch on if you ever want one: set
`colorStyle="3"` on the style in question.

## What it colours

| written | UDL slot | drawn |
|---|---|---|
| `-- a note` | line comment | grey, italic |
| `"text"`, across lines | delimiter 1 | green |
| `@ord-88213` | keywords 1, prefix | blue |
| `:dispatched` | keywords 2, prefix | purple |
| `#sha256:9f2a`, `~b64:iVBO` | keywords 3, prefix | blue |
| `!acme/hint` | keywords 4, prefix | blue |
| `true false null nan inf -inf` | keywords 5 | purple |
| `%unimsg` | keywords 6 | teal, bold |
| `-> @cust-4471` | operators 2 | dim |
| `{ } [ ] \| ,` | operators 1 | dim |
| `-42`, `19.99`, `2.5f`, `6.022e23` | numbers | orange |
| `2026-08-03T09:30:00Z` | numbers | orange |

Maps and sequences fold on `{}` and `[]`.

The colours are the Material swatches `syntaxColor` uses in gitexplorer, so a
document reads the same in both — a reader who has learned that purple means
an atom has learned it once.

## What it cannot do

UDL matches keywords, prefixes and delimiters. It has no regular expressions
and no notion of position within a line, and two things follow.

**Keys are not coloured.** In the application a key is the most valuable
colour on the page: it is what makes a document skimmable. Here a bare word is
a key, an annotation or a header label depending only on what preceded it, and
UDL cannot see that. So bare words are left as the default ink — which turns
out to read acceptably, because everything *else* is coloured, so the
uncoloured text is the document's spine.

**A word containing two hyphens opens a comment.** `well--known` would be
read as `well` followed by a comment. The real lexer only looks for a comment
where a token may start, so it reads that as one word. This has not come up in
any document here, and there is no way to express the distinction in UDL.

Neither are reserved sigils (`&$^*?\`) marked as the errors the format says
they are; they simply draw as ordinary text.

For the full treatment — keys, table headers, annotations, and the document
rendered as a page — open the file in gitexplorer.

## Checked in Notepad++

Against a probe holding every construct the format has, and against
`unimsg-v0.umsg` entire. The three doubtful cases all come out right:

- `-inf` stays purple with the other literals rather than turning orange,
  even though `-` is declared a number prefix. No digit follows, so the
  number rule declines and the literal list wins.
- `2026-08`, `2026-08-03` and `2026-08-03T09:30:00Z` are each one orange run.
- A string that opens on one line and closes three lines later is green
  throughout, and `--`, `{`, `:sym` and `42` inside it stay part of the
  string. `\"` does not end it either — the spec's `"\"…\""` cell parses, and
  everything after it in the file is still coloured correctly.

## Folding is approximate

Maps and sequences fold, and it works on real structure — a `{` inside a
single-line string opens nothing. Two things are off, both cosmetic:

- A fold anchors onto a comment block sitting above the `{` rather than onto
  the line with the brace, so the comment collapses along with what it
  introduces. Arguably an improvement; not intended.
- A `{` on a continuation line of a multi-line string does open a fold, unlike
  one in a single-line string. Notepad++ suppresses fold keywords inside a
  delimiter only on the line the delimiter opened.

Neither affects colouring. If they bother you, empty the four `Folders in
code1/code2` lists in both files and folding stops entirely.
