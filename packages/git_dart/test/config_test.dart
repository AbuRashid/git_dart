/// The config reader, checked against `git config`.
///
/// The rule this file exists to enforce: an answer that differs from what
/// `git config` reports is a defect, whatever the reasoning behind it. That
/// was found the hard way — the system file was skipped on principle, and a
/// repository created through it got a different default branch from the one
/// the user's own git would have created.
library;

import 'dart:convert';
import 'dart:io';

import 'package:git_dart/git_dart.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `git config --get`, or null when it reports nothing.
String? gitConfig(String key, {String? cwd}) {
  final result = Process.runSync(
    'git',
    ['config', '--get', key],
    workingDirectory: cwd,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  final value = (result.stdout as String).trim();
  return value.isEmpty ? null : value;
}

void main() {
  late Directory scratch;

  setUp(() => scratch = Directory.systemTemp.createTempSync('git_dart_config'));
  tearDown(() => scratch.deleteSync(recursive: true));

  test('parses sections, subsections and quoted values', () {
    final config = GitConfig.parse('''
[core]
\trepositoryformatversion = 0
\tbare = false
[remote "origin"]
\turl = https://example.invalid/x.git
\tfetch = +refs/heads/*:refs/remotes/origin/*
[user]
\tname = "A  B"   # a trailing comment
''');

    expect(config['core.repositoryformatversion'], '0');
    expect(config.boolean('core.bare'), isFalse);
    expect(config['remote.origin.url'], 'https://example.invalid/x.git');
    expect(config.subsections('remote'), {'origin'});
    // The subsection keeps its case; the section and key do not.
    expect(GitConfig.parse('[remote "Origin"]\nx = 1\n').subsections('remote'),
        {'Origin'});
    expect(config['user.name'], 'A  B');
  });

  test('a key with no value is true, as git treats it', () {
    final config = GitConfig.parse('[core]\n\tbare\n');
    expect(config.boolean('core.bare'), isTrue);
  });

  test('the last value wins, and every value is available', () {
    final config = GitConfig.parse('[a]\nb = 1\nb = 2\n');
    expect(config['a.b'], '2');
    expect(config.all('a.b'), ['1', '2']);
  });

  test('reads the same init.defaultBranch that git reports', () {
    // Git for Windows ships this in its system config, which is why this test
    // exists at all.
    final repository = p.join(scratch.path, 'r');
    Directory(repository).createSync(recursive: true);

    final ours = GitConfig.forRepository(p.join(repository, '.git'));
    expect(ours['init.defaultbranch'], gitConfig('init.defaultBranch'));
  });

  test('a repository setting overrides the machine and the user', () {
    final repository = p.join(scratch.path, 'r2');
    Process.runSync('git', ['init', '-q', repository]);
    Process.runSync(
      'git',
      ['config', 'init.defaultBranch', 'from-the-repository'],
      workingDirectory: repository,
    );

    final ours = GitConfig.forRepository(p.join(repository, '.git'));
    expect(ours['init.defaultbranch'], 'from-the-repository');
    expect(
      ours['init.defaultbranch'],
      gitConfig('init.defaultBranch', cwd: repository),
    );
  });

  test('agrees with git on a handful of keys in a real repository', () {
    final repository = p.join(scratch.path, 'r3');
    Process.runSync('git', ['init', '-q', repository]);
    Process.runSync(
      'git',
      ['config', 'user.email', 'someone@example.invalid'],
      workingDirectory: repository,
    );

    final ours = GitConfig.forRepository(p.join(repository, '.git'));
    for (final key in const [
      'user.email',
      'core.bare',
      'core.repositoryformatversion',
      'init.defaultBranch',
    ]) {
      expect(
        ours[key.toLowerCase()],
        gitConfig(key, cwd: repository),
        reason: key,
      );
    }
  });
}
