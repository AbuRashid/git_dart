import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unimsg/unimsg.dart' as u;
import 'package:unimsg_view/unimsg_view.dart';

/// The specifications in this repository.
List<File> _documents() => [
      for (final name in const [
        'explorer.umsg',
        'unimsg-v0.umsg',
        'git.umsg',
        '17-spec-based-design.umsg',
      ])
        File('../../specs/$name'),
    ].where((file) => file.existsSync()).toList();

Future<void> pumpDocument(
  WidgetTester tester,
  u.UnimsgDocument document,
  String title, {
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = const Size(1100, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness, useMaterial3: true),
      home: Scaffold(
        body: UnimsgDocumentView(document: document, title: title),
      ),
    ),
  );
}

u.UnimsgDocument doc(String body) => u.parse('%unimsg 0\n$body\n');

/// The document's own scroll view, as opposed to the contents list beside it.
final pageScroll = find.descendant(
  of: find.byType(SelectionArea),
  matching: find.byType(Scrollable),
);

void main() {
  group('over real documents', () {
    final documents = _documents();

    testWidgets('every one renders, in both brightnesses', (tester) async {
      if (documents.isEmpty) {
        markTestSkipped('run from within the repository');
        return;
      }
      for (final file in documents) {
        final name = file.uri.pathSegments.last;
        final source = DocumentSource.read(file.readAsStringSync());
        // A document this cannot parse is the parser's business, not the
        // renderer's; what matters here is that nothing it CAN parse throws.
        if (!source.isDocument) continue;
        for (final brightness in Brightness.values) {
          await pumpDocument(tester, source.document!, name,
              brightness: brightness);
          expect(tester.takeException(), isNull,
              reason: '$name at $brightness');
          expect(find.text(name), findsOneWidget);
        }
      }
    });

    testWidgets('scrolling one to the bottom lays every section out',
        (tester) async {
      // Laying out a section is where an overflow or a bad constraint
      // surfaces, and most sections are below the fold when the file opens.
      final file = File('../../specs/explorer.umsg');
      if (!file.existsSync()) {
        markTestSkipped('explorer.umsg not found');
        return;
      }
      final source = DocumentSource.read(file.readAsStringSync());
      await pumpDocument(tester, source.document!, 'explorer.umsg');

      final scroller = pageScroll.first;
      for (var i = 0; i < 40; i++) {
        await tester.drag(scroller, const Offset(0, -800));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'after ${i + 1} drags');
      }
    });
  });

  group('the page', () {
    testWidgets('opens the envelope and makes sections of what is inside',
        (tester) async {
      await pumpDocument(
        tester,
        doc('gitexplorer @v0 { presentation { doc "why" }, editing { what "x" } }'),
        'explorer.umsg',
      );

      expect(find.text('explorer.umsg'), findsOneWidget);
      expect(find.text('gitexplorer'), findsOneWidget);
      expect(find.text('@v0'), findsOneWidget);
      expect(find.text('%unimsg 0'), findsOneWidget);
      // The envelope is not itself a section; what it wrapped is.
      // Twice each: once in the contents, once as the heading it leads to.
      expect(find.text('presentation'), findsNWidgets(2));
      expect(find.text('editing'), findsNWidgets(2));
    });

    testWidgets('a file that does not parse says where', (tester) async {
      final source = DocumentSource.read('%unimsg 0\na {\n');
      expect(source.isDocument, isFalse);
      expect(source.says, contains('line'));
    });
  });

  group('treatments on the page', () {
    testWidgets('a table becomes a table with its columns as headings',
        (tester) async {
      await pumpDocument(
        tester,
        doc('spec { types [\n  | name code\n  | :bool 7\n  | :text 3\n] }'),
        't.umsg',
      );
      expect(find.byType(Table), findsOneWidget);
      expect(find.text('name'), findsOneWidget);
      expect(find.text('code'), findsOneWidget);
      expect(find.text(':bool'), findsOneWidget);
      // The sigil is kept: `:bool` and `bool` are different things.
      expect(find.text('bool'), findsNothing);
    });

    testWidgets('magnitudes become bars, drawn against the largest',
        (tester) async {
      await pumpDocument(
        tester, doc('spec { counts { a 5, b 10, c 0 } }'), 'b.umsg');
      final bars = tester
          .widgetList<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator))
          .toList();
      expect(bars, hasLength(3));
      expect(bars[0].value, 0.5);
      expect(bars[1].value, 1.0);
      expect(bars[2].value, 0.0);
    });

    testWidgets('a set of small values becomes chips', (tester) async {
      await pumpDocument(
        tester, doc('spec { forms [ :newline, :comma ] }'), 'c.umsg');
      expect(find.byType(Chip), findsNWidgets(2));
      expect(find.text(':newline'), findsOneWidget);
    });

    testWidgets('a keyed collection becomes cards', (tester) async {
      await pumpDocument(
        tester,
        doc('spec { pieces { bishop { moves 4 }, rook { moves 2 } } }'),
        'e.umsg',
      );
      expect(find.byType(Card), findsNWidgets(2));
      expect(find.text('bishop'), findsOneWidget);
    });
  });

  group('notes', () {
    testWidgets('a banner sits under the heading rather than in place of it',
        (tester) async {
      await pumpDocument(
        tester,
        doc('spec {\n'
            '  -- ===========\n'
            '  -- THE VIRTUAL ROOT\n'
            '  -- ===========\n'
            '  virtual-root { what "x" }\n'
            '}'),
        'n.umsg',
      );
      expect(find.text('virtual-root'), findsOneWidget);
      expect(find.text('the virtual root'), findsOneWidget);
      // Nothing to open: a disclosure over an empty body makes a promise it
      // cannot keep.
      expect(find.byType(ExpansionTile), findsNothing);
    });

    testWidgets('a note with prose is offered, closed, and opens', (tester) async {
      await pumpDocument(
        tester,
        doc('spec {\n'
            '  -- Editing a file changes something git has not recorded and\n'
            '  -- makes no claim about, which is why it reports a change\n'
            '  -- rather than damage.\n'
            '  editing { what "x" }\n'
            '}'),
        'n.umsg',
      );
      // The summary is the first few words; the rest is behind the
      // disclosure.
      final closed = find.textContaining('Editing a file changes');
      final body = find.textContaining('rather than damage');
      expect(find.byType(ExpansionTile), findsOneWidget);
      expect(closed, findsOneWidget);
      expect(body, findsNothing);

      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      expect(body, findsOneWidget);
    });
  });

  group('the preamble', () {
    // What the author wrote at the top of the file, which in every document
    // here is the paragraph saying what the document is.
    const source = '%unimsg 0 apps/gitexplorer/v0\n'
        '\n'
        '-- The git explorer, described as an application you could build.\n'
        '--\n'
        '-- Written before the application, which is the only arrangement in\n'
        '-- which the method is testable at all.\n'
        '\n'
        'gitexplorer @v0 {\n'
        '  title "A folder explorer"\n'
        '}\n';

    testWidgets('is shown, open, under the head', (tester) async {
      final reading = DocumentSource.read(source);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: UnimsgDocumentView(
            document: reading.document!,
            title: 'explorer.umsg',
            source: reading.text,
          ),
        ),
      ));

      // Reflowed off the author's hard wraps, and both paragraphs kept.
      expect(
        find.textContaining('described as an application you could build'),
        findsOneWidget,
      );
      expect(
        find.textContaining('the only arrangement in which the method'),
        findsOneWidget,
      );
      // Not behind a disclosure: there is one of these and it says what the
      // reader is looking at.
      expect(find.byType(ExpansionTile), findsNothing);
    });

    test('is read from the text while the parser drops it', () {
      // The tree has nothing: `_separators()` counts a comment as a separator,
      // so the skip past the header eats the block. Until that is fixed the
      // text is the only place it survives.
      final document = u.parse(source);
      final root = document.value as u.UMap;
      expect(root.entries.single.comments, isEmpty,
          reason: 'if this fails the parser was fixed, which is the point');

      final shape = DocumentShape.of(document, source: source);
      expect(shape.envelope, 'gitexplorer');
      expect(shape.preamble.first,
          'The git explorer, described as an application you could build.');
      expect(shape.preamble, contains(''), reason: 'the paragraph break');
    });

    test('prefers what the tree carries, when it carries anything', () {
      // Written as the fixed parser would produce it, so this keeps working
      // rather than doubling the preamble up the day it lands.
      final document = u.UnimsgDocument(
        const u.UnimsgHeader(0, null),
        u.UMap([
          u.MapEntry(
            'spec',
            const u.UMap([u.MapEntry('a', u.UText('x'))]),
            const ['from the tree'],
          ),
        ]),
      );
      final shape = DocumentShape.of(document, source: '-- from the text\n');
      expect(shape.preamble, ['from the tree']);
    });

    test('reads nothing when there is nothing to read', () {
      expect(leadingComments('%unimsg 0\na { x 1 }\n'), isEmpty);
      expect(leadingComments('a { x 1 }\n-- trailing\n'), isEmpty);
    });
  });

  group('the contents', () {
    u.UnimsgDocument many() => doc(
          'spec {\n${List.generate(
            12,
            (i) => '  section$i { text "padding" }',
          ).join('\n')}\n}',
        );

    testWidgets('sits beside the document when there is room', (tester) async {
      await pumpDocument(tester, many(), 'm.umsg');
      expect(find.text('Contents'), findsOneWidget);
      // A list to jump from, not a second copy of the document.
      expect(find.byType(ListTile), findsNWidgets(12));
      // Open, not something to open.
      expect(find.byType(ExpansionTile), findsNothing);
    });

    testWidgets('follows the reader down the page', (tester) async {
      await pumpDocument(tester, many(), 'm.umsg');

      ListTile tileFor(String name) => tester.widget<ListTile>(
            find.ancestor(
              of: find.descendant(
                of: find.byType(ListTile),
                matching: find.text(name),
              ),
              matching: find.byType(ListTile),
            ),
          );

      expect(tileFor('section0').selected, isTrue);
      expect(tileFor('section9').selected, isFalse);

      await tester.drag(pageScroll.first, const Offset(0, -1200));
      await tester.pumpAndSettle();

      expect(tileFor('section0').selected, isFalse);
    });

    testWidgets('jumping to a section scrolls the page', (tester) async {
      await pumpDocument(tester, many(), 'm.umsg');
      double where() =>
          tester.state<ScrollableState>(pageScroll.first).position.pixels;
      expect(where(), 0);

      await tester.tap(find.descendant(
        of: find.byType(ListTile),
        matching: find.text('section9'),
      ));
      await tester.pumpAndSettle();
      expect(where(), greaterThan(0));
    });

    testWidgets('folds into something to open when the pane is narrow',
        (tester) async {
      tester.view.physicalSize = const Size(520, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: UnimsgDocumentView(document: many(), title: 'm.umsg'),
        ),
      ));

      expect(find.text('Contents'), findsOneWidget);
      expect(find.text('12 sections'), findsOneWidget);
      // Closed, so it costs one line until it is wanted. Asserted on the
      // entries rather than on ListTile, since the expander is built from one.
      expect(find.text('section0'), findsOneWidget, reason: 'the heading only');

      await tester.tap(find.text('Contents'));
      await tester.pumpAndSettle();
      expect(find.text('section0'), findsNWidgets(2));
    });

    testWidgets('a document with one section is offered no contents',
        (tester) async {
      await pumpDocument(tester, doc('spec { only { a 1 } }'), 'one.umsg');
      expect(find.text('Contents'), findsNothing);
    });
  });

  group('references', () {
    testWidgets('one that resolves is a link, and following it scrolls',
        (tester) async {
      String filler(String tag) => List.generate(
            20,
            (i) => '  $tag$i { text "padding" }',
          ).join('\n');
      // Padding on both sides, so the scroll lands where it was aimed rather
      // than stopping at the end of the document.
      await pumpDocument(
        tester,
        doc('spec {\n  first { see -> @target }\n${filler("above")}\n'
            '  middle @target { what "found" }\n${filler("below")}\n}'),
        'r.umsg',
      );

      final link = find.text('-> @target');
      expect(link, findsOneWidget);

      // The whole page is built, so what the link does is move the viewport,
      // not conjure a widget. That is the thing to measure.
      double where() =>
          tester.state<ScrollableState>(pageScroll.first).position.pixels;
      expect(where(), 0);

      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(where(), greaterThan(0));

      // And it landed on the target rather than somewhere below it.
      // The heading on the page, not the entry in the contents beside it.
      final target = tester.getTopLeft(find.descendant(
        of: find.byType(SelectionArea),
        matching: find.text('middle'),
      ));
      expect(target.dy, greaterThanOrEqualTo(0));
      expect(target.dy, lessThan(300));
    });

    testWidgets('one that resolves to nothing stays inert', (tester) async {
      await pumpDocument(
        tester, doc('spec { a { see -> @nowhere } }'), 'r.umsg');
      expect(find.text('-> @nowhere'), findsOneWidget);
      expect(find.byType(InkWell), findsNothing);
      await tester.tap(find.text('-> @nowhere'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
