/// Writing git config, checked by asking git to read it back.
///
/// Every assertion goes through `git config --get`, because the only useful
/// definition of "written correctly" is that git agrees.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory scratch;
late String repoPath;

String? gitConfig(String key, {List<String> extra = const []}) {
  final result = Process.runSync(
    'git',
    ['config', ...extra, '--get', key],
    workingDirectory: repoPath,
    stdoutEncoding: utf8,
  );
  final value = (result.stdout as String).trim();
  return value.isEmpty ? null : value;
}

void main() {
  late ConfigWriter writer;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('git_dart_configwrite');
    repoPath = p.join(scratch.path, 'repo');
    Process.runSync('git', ['init', '-q', '-b', 'main', repoPath]);
    writer = ConfigWriter(p.join(repoPath, '.git'));
  });

  tearDown(() => scratch.deleteSync(recursive: true));

  test('sets a value git then reads', () {
    writer.set('user.name', 'A Person', ConfigScope.local);
    writer.set('user.email', 'a@example.invalid', ConfigScope.local);

    expect(gitConfig('user.name'), 'A Person');
    expect(gitConfig('user.email'), 'a@example.invalid');
  });

  test('changes a value in place, keeping the rest of the file', () {
    final path = p.join(repoPath, '.git', 'config');
    File(path).writeAsStringSync(
      '# a comment someone wrote\n'
      '[core]\n'
      '\trepositoryformatversion = 0\n'
      '\tbare = false\n'
      '[user]\n'
      '\tname = Before\n',
    );

    writer.set('user.name', 'After', ConfigScope.local);

    final after = File(path).readAsStringSync();
    expect(gitConfig('user.name'), 'After');
    // The comment and the untouched settings survive.
    expect(after, contains('# a comment someone wrote'));
    expect(after, contains('repositoryformatversion = 0'));
    expect(after, isNot(contains('Before')));
  });

  test('adds to an existing section rather than making a second one', () {
    writer.set('core.autocrlf', 'false', ConfigScope.local);
    final text = File(p.join(repoPath, '.git', 'config')).readAsStringSync();

    expect('[core]'.allMatches(text).length, 1);
    expect(gitConfig('core.autocrlf'), 'false');
    expect(gitConfig('core.repositoryformatversion'), '0');
  });

  test('writes a subsection the way git addresses it', () {
    writer.set('branch.main.remote', 'origin', ConfigScope.local);
    writer.set('branch.main.merge', 'refs/heads/main', ConfigScope.local);

    expect(gitConfig('branch.main.remote'), 'origin');
    expect(gitConfig('branch.main.merge'), 'refs/heads/main');
  });

  test('a value with a backslash or a space survives the round trip', () {
    writer.set('core.editor', r'C:\Program Files\Editor\ed.exe --wait',
        ConfigScope.local);
    expect(gitConfig('core.editor'), r'C:\Program Files\Editor\ed.exe --wait');
  });

  test('unsetting brings back whatever the wider scope says', () {
    writer.set('user.name', 'Local Only', ConfigScope.local);
    expect(gitConfig('user.name'), 'Local Only');

    writer.unset('user.name', ConfigScope.local);
    // Whatever the user's own config says now applies — possibly nothing.
    expect(gitConfig('user.name', extra: ['--local']), isNull);
  });

  test('reports which file a value in force came from', () {
    writer.set('user.name', 'From The Repository', ConfigScope.local);

    final origin = writer.origin('user.name');
    expect(origin?.scope, ConfigScope.local);
    expect(origin?.value, 'From The Repository');

    // A key nothing sets has no origin, and git's own default applies.
    expect(writer.origin('nonexistent.key'), isNull);
  });

  test('a key without a section is refused rather than guessed', () {
    expect(
      () => writer.set('nosection', 'x', ConfigScope.local),
      throwsArgumentError,
    );
  });
}
