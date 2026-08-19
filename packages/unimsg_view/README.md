# unimsg_view

Renders a unimsg document as a Material page.

```dart
final source = DocumentSource.read(text);
if (source.isDocument) {
  return UnimsgDocumentView(document: source.document!, title: 'spec.umsg');
}
```

## Nothing here knows what any document means

Every treatment is chosen from structure, type or arithmetic. A map whose
values are all maps is a keyed collection whatever it holds. A sequence of
maps with the same keys is a table whether it was written as `| rows` or
longhand — the format says the two are the same value, so a reader that drew
them differently would be disagreeing with the format about what it had just
read. A map of non-negative numbers is a set of magnitudes.

A treatment chosen from what a key is *called* works on the document in front
of you and fails silently on the next one. There is always a next one.

| treatment | confirmed by |
|---|---|
| `table` | a sequence of two or more maps with identical key sets |
| `entries` | a map whose values are all non-empty maps — drawn as cards |
| `outline` | the same, three deep and no more than four wide at any level |
| `glossary` | a map whose values are all text, at least one of them long |
| `settings` | a map whose values all fit on a line |
| `breakdown` | three or more values, all numbers, none negative, one non-zero |
| `chips` | a sequence holding no collections |
| `prose` | text of 80 characters or more |
| `fields` | everything else, claiming nothing |

## Two treatments the corpus vetoed

Both were designed, built far enough to measure, and dropped:

**Linking backticked names.** These documents write `` `presentation.doc` ``,
so resolving those against the document looked obviously right. Across
eighteen documents there are 81 backticked names and 15 of them name something
the document declares. The rest are `main`, `author`, `user.email` — code, not
cross-references. A link that is wrong four times in five teaches a reader to
stop trying them.

**Reading `(dotted.name)` as a reference.** Fired zero times. That is a
convention of one repository's *Dart comments*, not of its documents.

What did survive: `-> @name` references, 82 of them, 69 resolving. Those are
links; the rest render inert, which is what the format says an unresolved
reference is.

## The preamble

The comment block above the first pair says what the document is, and it is
shown open under the title — a section's note is shown closed, but there is one
preamble and there are dozens of notes.

The Dart parser currently drops it. `_separators()` counts a comment as a
separator, so the call in `document()` that skips past the header consumes the
whole block before the pair loop can collect it; the JavaScript implementation
keeps it, attached to the first pair. Until that is settled, `leadingComments`
reads it from the file's text and produces exactly what the fixed parser would
have. `DocumentShape` asks the tree first, so the day the parser keeps it this
stops being reached rather than doubling up with it.

Pass `source:` to `UnimsgDocumentView` for this and nothing else.

## The contents

Beside the page above 840 logical pixels, folded into an expander below it —
under that width the choice is between a column of contents and a column of
document, and the document wins.

It names section keys, not the banners drawn over them: a contents whose
entries do not match the headings they lead to is a second vocabulary to learn.
It marks the section being read, measured from where the headings actually are
rather than from offsets taken once, because opening a note moves everything
below it and a contents that lags the page is confidently wrong rather than
merely quiet.

## Material, not a stylesheet

A table is a `Table`, a magnitude is a `LinearProgressIndicator`, a note is an
`ExpansionTile`, a small value is a `Chip`, a collection entry is a `Card`.
Drawing those out of boxes and borders would produce something that looked
right and behaved like nothing else on the machine — no keyboard handling, no
density, no ink, no screen-reader announcement.

The one deliberate exception is the table, which uses Flutter's `Table` rather
than `DataTable`: a data table lays its columns out at a fixed width and clips
what will not fit, and half the cells in these documents are sentences. The
Material treatment is in the header row, the dividers and the numeric
alignment, not in which widget measures the grid.

## Colour

`UnimsgPalette` is supplied by the host, so an application showing the same
file twice — once as source, once as a page — can draw a symbol the same
colour in both. `UnimsgPalette.of` falls back to Material's scheme for a host
with no other view to agree with.

## The page is built eagerly

Not a lazy list. A reference has to be able to reach a heading twenty sections
down, and a list that has not built that section has nowhere to scroll to.
These are documents: the largest in the test corpus is a few thousand widgets,
built once when the file is opened.

## Tests

`shape_test.dart` and `notes_test.dart` cover the decisions. `render_test.dart`
renders every `.umsg` file in this repository *and* in the ribosome corpus
beside it, in both brightnesses, and fails on any exception — the second group
is the point, since a renderer tested only on the documents its author had
open agrees with whatever its author was already thinking.
