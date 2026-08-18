import 'dart:io';

import 'package:syntax_dart/syntax_dart.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  final grammar = grammars['unimsg']!;

  test('the header line', () {
    expect(kinds(grammar, '%unimsg 0 spec/unimsg/v0'), [
      'meta:%unimsg 0 spec/unimsg/v0',
    ]);
  });

  test('a comment runs to the end of the line', () {
    // `-` is a word rune, so without the comment rule first this is a word.
    expect(kinds(grammar, '-- a note'), ['comment:-- a note']);
    expect(kinds(grammar, 'status :draft -- why'), [
      'name:status',
      'plain: ',
      'keyword::draft',
      'plain: ',
      'comment:-- why',
    ]);
  });

  test('the first bare word of a pair is the key, the rest annotate', () {
    // The annotation is plain, and so is the space beside it, so the two
    // arrive as one token — adjacent runs of a kind are merged, since a
    // reader cannot see a boundary between two things drawn identically.
    expect(kinds(grammar, 'gloss en "student"'), [
      'name:gloss',
      'plain: en ',
      'string:"student"',
    ]);
  });

  test('a key is a key again after a comma or a brace', () {
    expect(kinds(grammar, 'spec @unimsg/v0 { title "x", status :provisional }'),
        [
          'name:spec',
          'plain: ',
          'meta:@unimsg/v0',
          'plain: ',
          'punctuation:{',
          'plain: ',
          'name:title',
          'plain: ',
          'string:"x"',
          'punctuation:,',
          'plain: ',
          'name:status',
          'plain: ',
          'keyword::provisional',
          'plain: ',
          'punctuation:}',
        ]);
  });

  test('a new line expects a key again, since a pair ends at a separator', () {
    final scanner = Scanner(grammar);
    scanner.scan('  title   "unimsg v0"');
    expect(render(scanner.scan('  status  :provisional'), '  status  :provisional'),
        contains('name:status'));
  });

  test('every sigil', () {
    expect(last(grammar, 'a @ord-88213'), 'meta:@ord-88213');
    expect(last(grammar, 'a -> @cust-4471'), 'meta:-> @cust-4471');
    expect(last(grammar, 'a #sha256:deadbeef'), 'meta:#sha256:deadbeef');
    expect(last(grammar, 'a ~b64:iVBORw0KGgo='), 'meta:~b64:iVBORw0KGgo=');
    expect(last(grammar, 'a !acme/hint'), 'meta:!acme/hint');
    expect(last(grammar, 'a :dispatched'), 'keyword::dispatched');
    expect(last(grammar, 'a :"null"'), 'keyword::"null"');
  });

  test('reserved literals are not words, and words containing them are', () {
    expect(last(grammar, 'a true'), 'keyword:true');
    expect(last(grammar, 'a -inf'), 'keyword:-inf');
    expect(last(grammar, 'a infrastructure'), 'plain: infrastructure');
    expect(last(grammar, 'a null-safe'), 'plain: null-safe');
  });

  test('a timestamp is tried before a number, and a year is not one', () {
    expect(last(grammar, 'a 2026-08-03'), 'number:2026-08-03');
    expect(last(grammar, 'a 2026-08-03T09:30:00Z'), 'number:2026-08-03T09:30:00Z');
    expect(last(grammar, 'a 2026'), 'number:2026');
    expect(last(grammar, 'a -42'), 'number:-42');
    expect(last(grammar, 'a 19.99'), 'number:19.99');
    expect(last(grammar, 'a 2.5f'), 'number:2.5f');
    // A leading `-` begins a number only when a digit follows.
    expect(last(grammar, 'a by-sequence'), 'plain: by-sequence');
  });

  test('a table header names keys, and its rows carry values', () {
    expect(kinds(grammar, '| sku qty'), [
      'punctuation:|',
      'plain: ',
      'name:sku',
      'plain: ',
      'name:qty',
    ]);
    expect(kinds(grammar, '| :"null"    7    "simple value 22"'), [
      'punctuation:|',
      'plain: ',
      'keyword::"null"',
      'plain:    ',
      'number:7',
      'plain:    ',
      'string:"simple value 22"',
    ]);
  });

  test('a string spans lines, and nothing inside it is anything else', () {
    final scanner = Scanner(grammar);
    const first = '  doc "A human text syntax for CBOR. The text';
    const second = '        form is a lossless projection: text -> CBOR ->';
    const third = '        text is byte-identical." }';

    expect(render(scanner.scan(first), first), [
      'plain:  ',
      'name:doc',
      'plain: ',
      'string:"A human text syntax for CBOR. The text',
    ]);
    // `->` inside the string must not become a reference.
    expect(render(scanner.scan(second), second), ['string:$second']);
    expect(render(scanner.scan(third), third), [
      'string:        text is byte-identical."',
      'plain: ',
      'punctuation:}',
    ]);
  });

  test('an escaped quote does not close the string', () {
    expect(last(grammar, r'a "he said \"no\" twice"'),
        r'string:"he said \"no\" twice"');
  });

  group('over the specification itself', () {
    final file = File('../../unimsg-v0.umsg');

    test('is tokenised without losing text', () {
      if (!file.existsSync()) {
        markTestSkipped('unimsg-v0.umsg not found');
        return;
      }
      final scanner = Scanner(grammar);
      for (final line in splitLines(file.readAsStringSync())) {
        expect(scanner.scan(line).map((t) => t.textIn(line)).join(), line);
      }
    });

    test('ends outside every mode, as a well-formed document should', () {
      if (!file.existsSync()) {
        markTestSkipped('unimsg-v0.umsg not found');
        return;
      }
      // A document that leaves the scanner inside a string or a comment has
      // an unclosed one, or the grammar has a hole. Neither is true here.
      final scanner = Scanner(grammar);
      for (final line in splitLines(file.readAsStringSync())) {
        scanner.scan(line);
      }
      expect(scanner.state, 0);
    });
  });
}
