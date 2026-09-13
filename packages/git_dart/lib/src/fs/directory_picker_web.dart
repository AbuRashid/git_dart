/// `showDirectoryPicker`, through JavaScript interop.
///
/// A smaller surface than OPFS needs: this only ever reads what the user
/// picked, so there is no create, no write, no delete — just enough of the
/// File System Access API to walk a tree and read what is in it.
///
/// The walk honours `.gitignore` as it goes, cascading — a directory's own
/// rules apply to it and everything below, the way git itself reads them
/// (`worktree.gitignore-cascades`) — and an ignored directory is never
/// descended into at all. That is not an optimisation so much as the whole
/// point: the folder a real project sits in is not the same size as the
/// project, `node_modules` and a build's output routinely dwarf the source by
/// orders of magnitude, and reading every file in them only to discard the
/// result is the difference between an import that takes a moment and one
/// that tries to copy two gigabytes to bring in a hundred megabytes of actual
/// history.
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../worktree/ignore.dart';
import 'memory_git_fs.dart';

@JS('window')
external JSObject get _window;

extension type _DirectoryHandle._(JSObject _) implements JSObject {
  external String get name;

  /// An async iterator over the child handles, each carrying its own name and
  /// kind — nothing further has to be asked of the parent to tell them apart.
  external _AsyncIterator values();
}

extension type _Handle._(JSObject _) implements JSObject {
  /// `'file'` or `'directory'`.
  external String get kind;
  external String get name;
}

extension type _FileHandle._(JSObject _) implements JSObject {
  external JSPromise<_File> getFile();
}

extension type _File._(JSObject _) implements JSObject {
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

extension type _AsyncIterator._(JSObject _) implements JSObject {
  external JSPromise<_IterationResult> next();
}

extension type _IterationResult._(JSObject _) implements JSObject {
  external bool get done;
  external JSAny? get value;
}

Future<bool> isAvailable() async {
  try {
    return _window.has('showDirectoryPicker');
  } on Object {
    return false;
  }
}

Future<String?> pickDirectoryInto(
  MemoryGitFs memory,
  String Function(String folderName) placeAt,
) async {
  final _DirectoryHandle picked;
  try {
    // Declared to return a promise unconditionally; on a browser that lacks
    // the method at all, `isAvailable` is what stops this from being called,
    // not this call itself.
    final promise =
        _window.callMethod<JSPromise<_DirectoryHandle>>('showDirectoryPicker'.toJS);
    picked = await promise.toDart;
  } on Object catch (error) {
    // The user closing the dialog is not a failure - it is "no thank you" -
    // and the browser reports it the same way as a real error: a rejected
    // promise, named `AbortError`. Everything else is a genuine problem the
    // caller should hear about.
    if ('$error'.contains('AbortError')) return null;
    rethrow;
  }

  final path = placeAt(picked.name);
  final rules = IgnoreRules();

  // `.git/info/exclude` applies everywhere, the same way it does for a real
  // checkout, and it is read before anything else for the same reason: rules
  // have to be in force before the paths they might exclude are looked at.
  final excludeText = await _readTextAt(picked, const ['.git', 'info', 'exclude']);
  if (excludeText != null) rules.addText(excludeText);

  await _copyInto(picked, memory, path, rules, '', insideGit: false);
  return path;
}

Future<void> _copyInto(
  _DirectoryHandle directory,
  MemoryGitFs memory,
  String path,
  IgnoreRules rules,
  String relative, {
  required bool insideGit,
}) async {
  memory.directory(path).createSync(recursive: true);

  // A directory's own `.gitignore` covers everything at or below it, so it is
  // read before any child is judged against the rules - not consulted at all
  // inside `.git`, where nothing is subject to it in the first place
  // (`worktree.gitignore-does-not-apply-inside-dot-git`).
  if (!insideGit) {
    final text = await _readFileText(directory, '.gitignore');
    if (text != null) rules.addText(text, base: relative);
  }

  final iterator = directory.values();
  while (true) {
    final step = await iterator.next().toDart;
    if (step.done) break;
    final value = step.value;
    if (value == null) break;
    final handle = value as _Handle;

    final childRelative = relative.isEmpty ? handle.name : '$relative/${handle.name}';
    final childPath = '$path/${handle.name}';
    final childInsideGit = insideGit || (relative.isEmpty && handle.name == '.git');

    if (handle.kind == 'directory') {
      if (!childInsideGit && rules.isIgnored(childRelative, isDirectory: true)) {
        // Skipped without a single read inside it - this is what keeps a
        // dependency folder or a build's output from being read at all,
        // rather than merely discarded after copying it.
        continue;
      }
      await _copyInto(
        handle as _DirectoryHandle,
        memory,
        childPath,
        rules,
        childRelative,
        insideGit: childInsideGit,
      );
      continue;
    }

    if (!childInsideGit && rules.isIgnored(childRelative)) continue;

    final file = await (handle as _FileHandle).getFile().toDart;
    final buffer = await file.arrayBuffer().toDart;
    memory.file(childPath).writeAsBytesSync(buffer.toDart.asUint8List());
  }
}

/// The text of `name` inside [directory], or null when there is no such file.
Future<String?> _readFileText(_DirectoryHandle directory, String name) async {
  final iterator = directory.values();
  while (true) {
    final step = await iterator.next().toDart;
    if (step.done) return null;
    final value = step.value;
    if (value == null) return null;
    final handle = value as _Handle;
    if (handle.name != name) continue;
    if (handle.kind != 'file') return null;

    final file = await (handle as _FileHandle).getFile().toDart;
    final buffer = await file.arrayBuffer().toDart;
    // Read leniently: a .gitignore is committed content and nothing
    // guarantees it is valid UTF-8.
    return utf8.decode(buffer.toDart.asUint8List(), allowMalformed: true);
  }
}

/// The text at a path of directory names ending in a file, or null when any
/// segment along the way is missing.
Future<String?> _readTextAt(_DirectoryHandle root, List<String> segments) async {
  var current = root;
  for (var i = 0; i < segments.length - 1; i++) {
    final next = await _childDirectory(current, segments[i]);
    if (next == null) return null;
    current = next;
  }
  return _readFileText(current, segments.last);
}

Future<_DirectoryHandle?> _childDirectory(_DirectoryHandle directory, String name) async {
  final iterator = directory.values();
  while (true) {
    final step = await iterator.next().toDart;
    if (step.done) return null;
    final value = step.value;
    if (value == null) return null;
    final handle = value as _Handle;
    if (handle.name == name && handle.kind == 'directory') {
      return handle as _DirectoryHandle;
    }
  }
}
