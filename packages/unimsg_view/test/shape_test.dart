import 'package:flutter_test/flutter_test.dart';
import 'package:unimsg/unimsg.dart' as u;
import 'package:unimsg_view/unimsg_view.dart';

/// Parses a document body, so a test can be written as the text an author
/// would type rather than as a tree.
u.UnimsgDocument doc(String body) => u.parse('%unimsg 0\n$body\n');

/// The treatment the value under [key] earns.
Treatment of(String body, String key) {
  final root = (doc(body).value) as u.UMap;
  return treatmentOf(root.entries.firstWhere((e) => e.key == key).value);
}

void main() {
  group('treatments', () {
    test('a sequence of maps with the same keys is a table', () {
      // A row ends at a separator, so the rows are on lines of their own.
      expect(of('t [\n  | sku qty\n  | :a 1\n  | :b 2\n]', 't'),
          Treatment.table);
      // Written longhand, it is the same value and so the same table — the
      // format says the row form is exactly sugar for this.
      expect(of('t [ { sku :a, qty 1 }, { sku :b, qty 2 } ]', 't'),
          Treatment.table);
    });

    test('maps with different keys are not a table', () {
      expect(of('t [ { a 1 }, { b 2 } ]', 't'), isNot(Treatment.table));
      // One row is a map, not a table: there is no column to read down.
      expect(of('t [ { a 1, b 2 } ]', 't'), isNot(Treatment.table));
    });

    test('a map whose values are all maps is a keyed collection', () {
      expect(of('m { a { x 1 }, b { x 2 } }', 'm'), Treatment.entries);
    });

    test('deep and narrow is an outline rather than a stack of cards', () {
      expect(
        of('m { a { b { c { d 1 } } }, e { f { g { h 2 } } } }', 'm'),
        Treatment.outline,
      );
    });

    test('long text values are a glossary, short ones are settings', () {
      final long = 'x' * 90;
      expect(of('m { a "$long", b "short" }', 'm'), Treatment.glossary);
      expect(of('m { a "short", b "also short" }', 'm'), Treatment.settings);
    });

    test('non-negative numbers are magnitudes, and three is the fewest', () {
      expect(of('m { a 1, b 2, c 3 }', 'm'), Treatment.breakdown);
      expect(of('m { a 1, b 2 }', 'm'), Treatment.settings);
      // A bar drawn for a negative number would be a lie about its size.
      expect(of('m { a -1, b 2, c 3 }', 'm'), Treatment.settings);
      // Nothing to compare.
      expect(of('m { a 0, b 0, c 0 }', 'm'), Treatment.settings);
    });

    test('a sequence with no collections in it is a set of small values', () {
      expect(of('s [ :a, :b, :c ]', 's'), Treatment.chips);
      expect(of('s [ :a, { b 1 } ]', 's'), Treatment.fields);
    });

    test('text is prose once it is read rather than glanced at', () {
      expect(of('a "${'x' * longText}"', 'a'), Treatment.prose);
      expect(of('a "${'x' * (longText - 1)}"', 'a'), Treatment.scalar);
    });

    test('a mixed map falls back to fields, claiming nothing', () {
      expect(of('m { a 1, b "x", c { d 2 } }', 'm'), Treatment.fields);
    });

    test('annotations do not change what a value is', () {
      expect(of('m en { a 1, b 2, c 3 }', 'm'), Treatment.breakdown);
    });
  });

  group('the envelope', () {
    test('a root holding one map is opened, and its key is kept', () {
      final shape = DocumentShape.of(doc('spec @v0 { a 1, b 2 }'));
      expect(shape.envelope, 'spec');
      expect(shape.envelopeAnnotations.single.name, 'v0');
      expect([for (final s in shape.sections) s.key], ['a', 'b']);
      expect(shape.header, '%unimsg 0');
    });

    test('a root holding several pairs is the document itself', () {
      final shape = DocumentShape.of(doc('a { x 1 }, b { y 2 }'));
      expect(shape.envelope, isNull);
      expect([for (final s in shape.sections) s.key], ['a', 'b']);
    });

    test('a root holding one scalar is not an envelope', () {
      final shape = DocumentShape.of(doc('a 1'));
      expect(shape.envelope, isNull);
      expect(shape.sections, hasLength(1));
    });
  });

  group('anchors', () {
    test('a path, its last segment, and any identifier all lead there', () {
      final shape = DocumentShape.of(
        doc('spec { presentation { syntax-colour @sc { a 1 } } }'),
      );
      final anchors = anchorsOf(shape);
      expect(anchors.resolve('presentation.syntax-colour'),
          'presentation.syntax-colour');
      expect(anchors.resolve('syntax-colour'), 'presentation.syntax-colour');
      expect(anchors.resolve('@sc'), isNull, reason: 'the sigil is not the name');
      expect(anchors.resolve('sc'), 'presentation.syntax-colour');
      expect(anchors.isTarget('presentation.syntax-colour'), isTrue);
      expect(anchors.isTarget('presentation.nothing'), isFalse);
    });

    test('the first claim on a name wins', () {
      // Sending a reader to the second place a name appears rather than to
      // its definition is worse than sending them nowhere.
      final shape = DocumentShape.of(doc('spec { a { dup { x 1 } }, b { dup { y 2 } } }'));
      expect(anchorsOf(shape).resolve('dup'), 'a.dup');
    });

    test('a name nothing declares resolves to nothing, and stays inert', () {
      expect(anchorsOf(DocumentShape.of(doc('spec { a 1 }'))).resolve('b'),
          isNull);
    });
  });
}
