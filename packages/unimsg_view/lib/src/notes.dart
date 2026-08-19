// What an author wrote in the margins, read back as something a reader can
// use. No Flutter here either: this is about text.

/// A line made of nothing but rule glyphs, repeated. Authors draw these to
/// fence a heading, and they carry no words of their own.
final _ruleLine = RegExp(r'^[=\-–—*_~·.]{3,}$');

/// A run of `--` comment lines, read as a note.
class Note {
  /// The author's own heading for what follows, taken from a line they fenced
  /// with rules. Often more human than the key it sits above.
  final String? title;

  /// The prose, reflowed to the reader's column rather than the author's.
  final List<String> paragraphs;

  const Note({this.title, this.paragraphs = const []});

  bool get isEmpty => title == null && paragraphs.isEmpty;

  /// A banner with nothing under it is a heading, not a note: there is
  /// nothing to open, and offering to open it makes a promise the disclosure
  /// cannot keep.
  bool get isBannerOnly => title != null && paragraphs.isEmpty;

  /// The first few words, for a disclosure that has no title to show.
  String get summary {
    if (title != null) return title!;
    if (paragraphs.isEmpty) return '';
    final words = paragraphs.first.split(RegExp(r'\s+'));
    if (words.length <= 9) return paragraphs.first;
    return '${words.take(9).join(' ')}…';
  }
}

/// Reads the comment lines that preceded a pair.
///
/// Two things happen here, and both are about giving the words back to the
/// reader rather than showing them as the author's file happened to hold
/// them. A line fenced by rules is lifted out as a title, because that is
/// what an author drawing a box around a word means by it. And hard wraps are
/// undone — a blank line ends a paragraph, anything else continues one — so
/// the text reflows to the width it is being read at instead of the width it
/// was typed at.
Note readNote(List<String> lines) {
  if (lines.isEmpty) return const Note();

  final kept = <String>[];
  String? title;

  for (final raw in lines) {
    final line = raw.trim();
    if (_ruleLine.hasMatch(line)) {
      if (title == null && kept.isNotEmpty && kept.last.isNotEmpty) {
        // Long enough to be a sentence is not a heading, whatever is drawn
        // around it.
        if (kept.last.length <= 64) title = kept.removeLast();
      }
      continue;
    }
    kept.add(line);
  }

  while (kept.isNotEmpty && kept.first.isEmpty) {
    kept.removeAt(0);
  }
  while (kept.isNotEmpty && kept.last.isEmpty) {
    kept.removeLast();
  }

  final paragraphs = <String>[];
  final current = <String>[];
  for (final line in kept) {
    if (line.isEmpty) {
      if (current.isNotEmpty) paragraphs.add(current.join(' '));
      current.clear();
    } else {
      current.add(line);
    }
  }
  if (current.isNotEmpty) paragraphs.add(current.join(' '));

  return Note(title: title, paragraphs: paragraphs);
}

/// One run of a paragraph: either prose or something written in backticks.
class Fragment {
  final String text;

  /// Whether the author set this apart with backticks. In these documents
  /// that means a name — of a key, a section, a rule — far more often than it
  /// means a snippet of code, which is why it is worth resolving against the
  /// document before drawing it.
  final bool isCode;

  const Fragment(this.text, {this.isCode = false});
}

/// Splits a paragraph on backticks.
///
/// An unpaired backtick is left as itself rather than opening a run that
/// swallows the rest of the paragraph. Authors write `don't` and mean an
/// apostrophe; they also write a lone backtick and mean a backtick.
List<Fragment> fragments(String paragraph) {
  final parts = paragraph.split('`');
  if (parts.length < 3) return [Fragment(paragraph)];

  final result = <Fragment>[];
  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    final closed = i.isOdd && i < parts.length - 1;
    if (closed) {
      if (part.isNotEmpty) result.add(Fragment(part, isCode: true));
    } else if (part.isNotEmpty || i.isOdd) {
      result.add(Fragment(i.isOdd ? '`$part' : part));
    }
  }
  return result;
}
