import 'package:syntax_dart/syntax_dart.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('dart', () {
    final grammar = grammars['dart']!;

    test('block comments nest, which is the case a line-blind scanner gets '
        'wrong', () {
      final scanner = Scanner(grammar);
      expect(render(scanner.scan('/* outer'), '/* outer'),
          ['comment:/* outer']);
      expect(scanner.scan('/* inner */').single.kind, TokenKind.comment);
      // The inner close must not end the outer comment.
      expect(scanner.scan('still comment').single.kind, TokenKind.comment);
      final closing = 'still */ const x = 1;';
      final tokens = render(scanner.scan(closing), closing);
      expect(tokens.first, 'comment:still */');
      expect(tokens, contains('keyword:const'));
      expect(scanner.state, 0);
    });

    test('a doc comment is a comment, not a division', () {
      expect(kinds(grammar, '/// The file, editable.'),
          ['comment:/// The file, editable.']);
    });

    test('triple-quoted strings span lines', () {
      final scanner = Scanner(grammar);
      scanner.scan("const sql = '''");
      expect(scanner.scan('  SELECT 1').single.kind, TokenKind.string);
      expect(render(scanner.scan("''';"), "''';"),
          ["string:'''", 'punctuation:;']);
    });

    test('a string on one line does not open a mode', () {
      final scanner = Scanner(grammar);
      scanner.scan(r"final s = 'it\'s fine';");
      expect(scanner.state, 0);
    });

    test('capitalised names are types', () {
      expect(kinds(grammar, 'class TreePane extends StatelessWidget {'), [
        'keyword:class',
        'plain: ',
        'name:TreePane',
        'plain: ',
        'keyword:extends',
        'plain: ',
        'name:StatelessWidget',
        'plain: ',
        'punctuation:{',
      ]);
    });

    test('annotations', () {
      expect(kinds(grammar, '@override'), ['meta:@override']);
    });

    test('numbers, including hex and separators', () {
      expect(last(grammar, 'x = 0xFF'), 'number:0xFF');
      expect(last(grammar, 'x = 1_000_000'), 'number:1_000_000');
      expect(last(grammar, 'x = 6.022e23'), 'number:6.022e23');
    });
  });

  group('json', () {
    final grammar = grammars['json']!;

    test('a string before a colon is a key, and one after it is not', () {
      expect(kinds(grammar, '  "name": "syntax_dart",'), [
        'plain:  ',
        'name:"name"',
        'punctuation::',
        'plain: ',
        'string:"syntax_dart"',
        'punctuation:,',
      ]);
    });

    test('literals and numbers', () {
      expect(last(grammar, '{"a": true'), 'keyword:true');
      expect(last(grammar, '{"a": -1.5e3'), 'number:-1.5e3');
    });
  });

  group('yaml', () {
    final grammar = grammars['yaml']!;

    test('a key is named', () {
      expect(kinds(grammar, 'name: gitexplorer'), [
        'name:name',
        'punctuation::',
        'plain: gitexplorer',
      ]);
    });

    test('a URL in a value is not a key, which is the usual bug here', () {
      final tokens = kinds(grammar, '  url: https://example.com/a');
      expect(tokens, contains('name:url'));
      expect(tokens.where((t) => t.startsWith('name:')), hasLength(1));
    });

    test('comments, anchors and list markers', () {
      expect(last(grammar, 'sdk: ^3.5.0 # required'), 'comment:# required');
      expect(last(grammar, 'base: &anchor'), 'meta:&anchor');
      expect(kinds(grammar, '  - item').first, 'plain:  ');
      expect(kinds(grammar, '  - item'), contains('punctuation:-'));
    });
  });

  group('markdown', () {
    final grammar = grammars['markdown']!;

    test('a heading needs its space, so a hash in prose stays prose', () {
      expect(kinds(grammar, '## Options'), ['name:## Options']);
      expect(kinds(grammar, 'see issue #42'), ['plain:see issue #42']);
    });

    test('inline code and links', () {
      expect(last(grammar, 'call `scan()`'), 'string:`scan()`');
      expect(last(grammar, 'see [the spec](unimsg-v0.umsg)'),
          'meta:[the spec](unimsg-v0.umsg)');
    });

    test('a fence holds until it closes, and its body is left plain', () {
      final scanner = Scanner(grammar);
      expect(scanner.scan('```dart').single.kind, TokenKind.meta);
      expect(scanner.scan('# not a heading in here').single.kind,
          TokenKind.plain);
      expect(scanner.scan('```').single.kind, TokenKind.meta);
      expect(scanner.state, 0);
      expect(kinds(grammar, '# a heading again'), ['name:# a heading again']);
    });
  });

  group('shell', () {
    final grammar = grammars['shell']!;

    test('a shebang is not a comment', () {
      expect(kinds(grammar, '#!/usr/bin/env bash'),
          ['meta:#!/usr/bin/env bash']);
      expect(kinds(grammar, '# a note'), ['comment:# a note']);
    });

    test('expansions and assignments', () {
      expect(kinds(grammar, 'R=/c/repo').first, 'name:R');
      expect(last(grammar, 'echo \$HOME'), 'meta:\$HOME');
      expect(last(grammar, 'echo \${HOME}'), 'meta:\${HOME}');
      expect(last(grammar, 'echo \$(pwd)'), 'meta:\$(pwd)');
    });

    test('keywords', () {
      expect(kinds(grammar, 'if true; then'), contains('keyword:if'));
    });

    test('an option reads as part of the command', () {
      expect(last(grammar, 'ls -la'), 'meta:-la');
      expect(last(grammar, 'git commit --amend'), 'meta:--amend');
    });
  });

  group('python', () {
    final grammar = grammars['python']!;

    test('a docstring spans lines', () {
      final scanner = Scanner(grammar);
      scanner.scan('def f():');
      expect(scanner.state, 0);
      scanner.scan('    """Summary.');
      expect(scanner.scan('    More.').single.kind, TokenKind.string);
      expect(scanner.scan('    """').last.kind, TokenKind.string);
      expect(scanner.state, 0);
    });

    test('string prefixes', () {
      expect(last(grammar, 'x = f"a{b}c"'), 'string:f"a{b}c"');
      expect(last(grammar, r'x = rb"\d+"'), r'string:rb"\d+"');
    });

    test('decorators and keywords', () {
      expect(kinds(grammar, '@dataclass'), ['meta:@dataclass']);
      expect(kinds(grammar, 'class Foo:'), [
        'keyword:class',
        'plain: ',
        'name:Foo',
        'punctuation::',
      ]);
    });
  });

  group('the c family', () {
    test('rust block comments nest and c block comments do not', () {
      final rust = Scanner(grammars['rust']!);
      rust.scan('/* outer /* inner */');
      expect(rust.state, isNot(0), reason: 'rust counts the inner open');

      final c = Scanner(grammars['c']!);
      c.scan('/* outer /* inner */');
      expect(c.state, 0, reason: 'c ends at the first close');
    });

    test('a javascript template literal spans lines', () {
      final scanner = Scanner(grammars['javascript']!);
      scanner.scan('const q = `SELECT');
      expect(scanner.scan('  1').single.kind, TokenKind.string);
      expect(scanner.scan('`;').first.kind, TokenKind.string);
      expect(scanner.state, 0);
    });

    test('typescript knows the words javascript does not', () {
      expect(kinds(grammars['typescript']!, 'interface A {'),
          contains('keyword:interface'));
      expect(kinds(grammars['javascript']!, 'interface A {'),
          isNot(contains('keyword:interface')));
    });

    test('c preprocessor directives', () {
      expect(kinds(grammars['c']!, '#include <stdio.h>').first,
          'meta:#include');
    });
  });
}
