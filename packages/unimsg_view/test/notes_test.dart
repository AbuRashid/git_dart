import 'package:flutter_test/flutter_test.dart';
import 'package:unimsg_view/unimsg_view.dart';

void main() {
  group('banners', () {
    test('a line fenced by rules is the author heading for what follows', () {
      // The shape every document in this repository uses.
      final note = readNote([
        '===================================================================',
        'THE VIRTUAL ROOT',
        '===================================================================',
      ]);
      expect(note.title, 'THE VIRTUAL ROOT');
      expect(note.paragraphs, isEmpty);
      expect(note.isBannerOnly, isTrue);
    });

    test('a banner with prose under it keeps both', () {
      final note = readNote(['---------', 'Editing', '---------', '', 'Why.']);
      expect(note.title, 'Editing');
      expect(note.paragraphs, ['Why.']);
      expect(note.isBannerOnly, isFalse);
    });

    test('a sentence between rules is not a heading, whatever is drawn '
        'around it', () {
      final long = 'x' * 70;
      final note = readNote(['===', long, '===']);
      expect(note.title, isNull);
      expect(note.paragraphs, [long]);
    });

    test('comments with no rules at all are all prose', () {
      final note = readNote(['a note', 'continued']);
      expect(note.title, isNull);
      expect(note.paragraphs, ['a note continued']);
    });
  });

  group('reflow', () {
    test('hard wraps are undone and blank lines end paragraphs', () {
      final note = readNote([
        'The window is stock Material.',
        'There is no palette here.',
        '',
        'An earlier version carried twelve colours.',
      ]);
      expect(note.paragraphs, [
        'The window is stock Material. There is no palette here.',
        'An earlier version carried twelve colours.',
      ]);
    });

    test('blank lines at either end are dropped', () {
      expect(readNote(['', '', 'body', '', '']).paragraphs, ['body']);
    });

    test('nothing at all is an empty note', () {
      expect(readNote(const []).isEmpty, isTrue);
      expect(readNote(['', '']).isEmpty, isTrue);
    });
  });

  group('summaries', () {
    test('a title is the summary when there is one', () {
      expect(readNote(['===', 'Editing', '===', '', 'why']).summary, 'Editing');
    });

    test('otherwise the first few words, marked as cut short', () {
      final note = readNote([
        'one two three four five six seven eight nine ten eleven',
      ]);
      expect(note.summary, 'one two three four five six seven eight nine…');
    });

    test('a short first paragraph is shown whole', () {
      expect(readNote(['one two three']).summary, 'one two three');
    });
  });

  group('backticks', () {
    test('a closed pair is code and the rest is prose', () {
      final parts = fragments('see `presentation.doc` for why');
      expect([for (final f in parts) f.text], ['see ', 'presentation.doc', ' for why']);
      expect([for (final f in parts) f.isCode], [false, true, false]);
    });

    test('an unpaired backtick stays a backtick', () {
      // Otherwise it opens a run that swallows the rest of the paragraph.
      final parts = fragments('a ` b');
      expect(parts, hasLength(1));
      expect(parts.single.text, 'a ` b');
      expect(parts.single.isCode, isFalse);
    });

    test('text with no backticks is one fragment', () {
      expect(fragments('plain').single.isCode, isFalse);
    });
  });
}
