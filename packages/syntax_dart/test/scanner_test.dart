import 'dart:io';

import 'package:syntax_dart/syntax_dart.dart';
import 'package:test/test.dart';

void main() {
  group('splitLines', () {
    test('keeps the empty last line of a file ending in a newline', () {
      expect(splitLines('a\nb\n').toList(), ['a', 'b', '']);
    });

    test('drops carriage returns', () {
      expect(splitLines('a\r\nb\r\n').toList(), ['a', 'b', '']);
    });

    test('a file with no newline at all is one line', () {
      expect(splitLines('a').toList(), ['a']);
      expect(splitLines('').toList(), ['']);
    });
  });

  group('scan', () {
    test('tokens tile the line exactly', () {
      // The viewer concatenates token texts to draw a line, so a gap is a
      // dropped character and an overlap is a doubled one.
      for (final grammar in grammars.values) {
        for (final line in _awkwardLines) {
          final tokens = Scanner(grammar).scan(line);
          var at = 0;
          for (final token in tokens) {
            expect(token.start, at,
                reason: '${grammar.name} left a gap in ${line.trim()}');
            expect(token.end, greaterThan(token.start));
            at = token.end;
          }
          expect(at, line.length,
              reason: '${grammar.name} stopped short of the end of $line');
          expect(tokens.map((t) => t.textIn(line)).join(), line);
        }
      }
    });

    test('an empty line yields no tokens and does not move the state', () {
      final scanner = Scanner(dartGrammarForTest);
      scanner.scan('/*');
      final inComment = scanner.state;
      expect(scanner.scan(''), isEmpty);
      expect(scanner.state, inComment);
    });

    test('a surrogate pair is never split', () {
      final line = 'x 🙂 y';
      final tokens = Scanner(grammars['markdown']!).scan(line);
      for (final token in tokens) {
        // substring throws on a boundary inside a pair, which is the point.
        expect(() => token.textIn(line), returnsNormally);
      }
    });

    test('a bogus state falls back to the base mode rather than crashing', () {
      final scanner = Scanner(grammars['dart']!, state: 9999);
      expect(() => scanner.scan('const x = 1;'), returnsNormally);
      expect(scanner.state, 0);
    });
  });

  group('state', () {
    // What the diff viewer needs: one grammar following two interleaved
    // sequences of lines through the same hunks.
    test('save and restore lets one grammar follow two sequences', () {
      final grammar = grammars['dart']!;
      final oldSide = Scanner(grammar);
      final newSide = Scanner(grammar);

      oldSide.scan('/* removed comment opens');
      newSide.scan('const x = 1;');

      expect(oldSide.state, isNot(0), reason: 'the old side is in a comment');
      expect(newSide.state, 0, reason: 'the new side is not');

      final kinds = newSide.scan('const y = 2;').map((t) => t.kind);
      expect(kinds, contains(TokenKind.keyword));
      expect(kinds, isNot(contains(TokenKind.comment)));

      expect(oldSide.scan('still comment').single.kind, TokenKind.comment);
    });
  });

  group('grammarForPath', () {
    test('picks by extension, case-insensitively', () {
      expect(grammarForPath('lib/src/main.dart')?.name, 'dart');
      expect(grammarForPath(r'C:\repo\App.TS')?.name, 'typescript');
      expect(grammarForPath('explorer.umsg')?.name, 'unimsg');
    });

    test('picks by whole name where there is no useful extension', () {
      expect(grammarForPath('.gitignore')?.name, 'shell');
      expect(grammarForPath('a/b/Makefile')?.name, 'shell');
      expect(grammarForPath('pubspec.lock')?.name, 'yaml');
    });

    test('is null for a type with no grammar', () {
      expect(grammarForPath('logo.png'), isNull);
      expect(grammarForPath('LICENCE.txt'), isNull);
      expect(grammarForPath('noextension'), isNull);
    });
  });

  group('over this repository', () {
    // The sample lines above are invented, and invented input agrees with
    // whatever the author was already thinking. These files were not written
    // for the tokeniser.
    test('every real file tiles exactly, on every line', () {
      final files = _repositoryFiles();
      if (files.isEmpty) {
        markTestSkipped('run from within the repository to exercise this');
        return;
      }
      for (final file in files) {
        final grammar = grammarForPath(file.path);
        if (grammar == null) continue;
        final source = file.readAsStringSync();
        final scanner = Scanner(grammar);
        for (final line in splitLines(source)) {
          final tokens = scanner.scan(line);
          expect(tokens.map((t) => t.textIn(line)).join(), line,
              reason: '${grammar.name} lost text in ${file.path}');
        }
      }
    });
  });
}

/// Lines chosen to sit on the edges: unterminated quotes, lone sigils, text
/// no rule claims, and characters outside the basic plane.
const _awkwardLines = [
  '',
  ' ',
  '\t\t',
  '"unterminated',
  "'",
  '`',
  '/*',
  '*/',
  '--',
  '->',
  '@',
  '#',
  '~',
  '%',
  '|',
  '\\',
  '{[(<>)]}',
  '2026-08-18T09:30:00Z',
  '-42 19.99 2.5f 6.022e23 0xFF',
  'd͡ʒ kitāb 🙂',
  'key value -- trailing',
  '### heading',
  r'$VAR ${BRACED} $(command)',
  'a:b:c',
  '...',
];

/// Reachable only because the test lives beside the package it tests.
Grammar get dartGrammarForTest => grammars['dart']!;

/// Named directories rather than a walk from the root: build output holds
/// paths long enough that listing them fails on Windows, and none of it is
/// source anyway.
const _sourceDirectories = [
  '../../specs',
  '../../packages/unimsg/lib',
  '../../packages/git_dart/lib',
  '../../apps/gitexplorer/lib',
  '../../apps/gitexplorer/test',
];

List<File> _repositoryFiles() {
  final files = <File>[];
  for (final path in _sourceDirectories) {
    final directory = Directory(path);
    if (!directory.existsSync()) continue;
    // The specs directory is listed shallowly, for the .umsg files in it;
    // the source directories are walked.
    final recursive = path != '../../specs';
    files.addAll(directory
        .listSync(recursive: recursive, followLinks: false)
        .whereType<File>());
  }
  return files;
}
