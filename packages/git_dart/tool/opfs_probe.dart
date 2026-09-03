/// A round trip through OPFS, run in a real browser.
///
/// Compiling proves nothing here: dart2js compiles `dart:io` happily and emits
/// JavaScript that throws on the first call, so the only way to know whether
/// git_dart works in a browser is to run it in one.
///
/// Creates a repository in memory, saves it to OPFS, loads it back into a
/// different filesystem, and reads the history out of that — which exercises
/// every part of the web path at once.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:git_dart/git_dart.dart';
import 'package:git_dart/src/fs/git_fs.dart' show fs;

@JS('document')
external JSObject get _document;

final _lines = <String>[];

void say(String line) {
  _lines.add(line);
  final body = _document.getProperty('body'.toJS) as JSObject?;
  body?.setProperty(
    'innerText'.toJS,
    _lines.join('\n').toJS,
  );
  print(line);
}

const _who = Identity(
  name: 'Web Tester',
  email: 'web@example.com',
  seconds: 1700000000,
  timezone: '+0000',
);

Future<void> main() async {
  try {
    await _run();
    say('');
    say('ALL OK');
  } on Object catch (error, stack) {
    say('FAILED: $error');
    say('$stack');
  }
}

Future<void> _run() async {
  say('OPFS available: ${await OpfsStore.isAvailable}');
  final usage = await OpfsStore.usage;
  say('quota: ${usage == null ? 'unknown' : '${usage.available} bytes free'}');

  const store = OpfsStore('probe/repo-one');

  // Start clean, so re-running the page proves the same thing each time.
  await store.delete();

  // ---- build a repository entirely in memory ----
  final memory = MemoryGitFs();
  useGitFileSystem(memory);

  final repo = Repository.init('/work');
  final root = repo.workTree!;
  say('initialised at $root');

  fs.file('${repo.workTree}/README.md').writeAsStringSync('hello browser\n');
  repo.stage('README.md');
  final first = repo.commitIndex(message: 'first commit', author: _who);
  say('first commit: ${first.hex.substring(0, 8)}');

  fs.file('${repo.workTree}/README.md').writeAsStringSync('second version\n');
  fs.file('${repo.workTree}/other.txt').writeAsStringSync('another file\n');
  repo.stage('README.md');
  repo.stage('other.txt');
  final second = repo.commitIndex(message: 'second commit', author: _who);
  say('second commit: ${second.hex.substring(0, 8)}');
  say('log in memory: ${repo.log().map((c) => c.message.trim()).toList()}');
  repo.close();

  // ---- save it ----
  say('files to save: ${memory.files.length}, ${memory.byteCount} bytes');
  await store.saveAll(memory, under: root);
  say('saved; stored names: ${await const OpfsStore('probe').list()}');

  // ---- load it back into a different filesystem ----
  final restored = await store.load(under: root);
  say('loaded ${restored.files.length} files, ${restored.byteCount} bytes');

  useGitFileSystem(restored);
  final reopened = Repository.open(root);
  final subjects = reopened.log().map((c) => c.message.trim()).toList();
  say('log from OPFS: $subjects');
  say('HEAD: ${reopened.headId!.hex.substring(0, 8)}');
  say('README.md: ${String.fromCharCodes(reopened.readFile('README.md')!)}');
  say('branches: ${reopened.refs.branches.map((r) => r.shortName).toList()}');
  say('status clean: ${reopened.status().entries.isEmpty}');

  if (subjects.join(',') != 'second commit,first commit') {
    throw StateError('the history did not survive the round trip: $subjects');
  }
  if (reopened.headId != second) {
    throw StateError('HEAD moved across the round trip');
  }
  reopened.close();

  // ---- an incremental save ----
  useGitFileSystem(restored);
  final again = Repository.open(root);
  fs.file('$root/third.txt').writeAsStringSync('added after loading\n');
  again.stage('third.txt');
  again.commitIndex(message: 'third commit', author: _who);
  again.close();

  say('changed since load: ${restored.changedPaths.length} paths');
  await store.save(restored, under: root);
  say('incremental save done; still changed: ${restored.hasChanges}');

  final third = await store.load(under: root);
  useGitFileSystem(third);
  final finally_ = Repository.open(root);
  final after = finally_.log().map((c) => c.message.trim()).toList();
  say('log after incremental save: $after');
  if (after.length != 3) {
    throw StateError('the incremental save lost history: $after');
  }
  finally_.close();
}
