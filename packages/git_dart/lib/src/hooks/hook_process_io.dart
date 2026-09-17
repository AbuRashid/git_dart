import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'hooks.dart';

/// The hook program for [name] in [directory], or null when there is none git
/// would run.
///
/// A dangling symlink, a directory, and — off Windows — a file without an
/// execute bit are all "no hook". Git for Windows treats every file as
/// executable and also accepts `<name>.exe`, so this does too.
String? findHookProgram(String directory, String name) {
  final path = p.join(directory, name);
  if (_runnable(path)) return path;
  if (Platform.isWindows && _runnable('$path.exe')) return '$path.exe';
  return null;
}

bool _runnable(String path) {
  if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) {
    return false;
  }
  if (Platform.isWindows) return true;
  return FileStat.statSync(path).mode & 0x49 != 0; // any of 0111
}

HookResult runHookSync(String program, HookInvocation invocation) {
  final (executable, arguments) = _commandFor(program, invocation.arguments);
  try {
    final result = Process.runSync(
      executable,
      arguments,
      workingDirectory: invocation.workingDirectory,
      environment: invocation.environment,
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
      stderrEncoding: const Utf8Codec(allowMalformed: true),
    );
    return HookResult(
      result.exitCode,
      '${result.stdout}${result.stderr}',
    );
  } on ProcessException catch (error) {
    return _couldNotStart(invocation, error);
  }
}

Future<HookResult> runHook(String program, HookInvocation invocation) async {
  final (executable, arguments) = _commandFor(program, invocation.arguments);
  final Process started;
  try {
    started = await Process.start(
      executable,
      arguments,
      workingDirectory: invocation.workingDirectory,
      environment: invocation.environment,
    );
  } on ProcessException catch (error) {
    return _couldNotStart(invocation, error);
  }

  // Both streams into one buffer in the order they arrive, which is the order
  // a person at a terminal would have seen them in.
  final output = StringBuffer();
  const decoder = Utf8Decoder(allowMalformed: true);
  final done = Future.wait([
    started.stdout.transform(decoder).forEach(output.write),
    started.stderr.transform(decoder).forEach(output.write),
  ]);

  // A hook is free to ignore its input and exit, which closes the pipe under
  // a write still in progress. That is the hook's choice, not an error here.
  final stdin = invocation.stdin;
  try {
    if (stdin != null) started.stdin.add(utf8.encode(stdin));
    await started.stdin.close();
  } on Object {
    // Broken pipe: see above.
  }
  unawaited(started.stdin.done.then<void>((_) {}, onError: (_) {}));

  final exitCode = await started.exitCode;
  await done;
  return HookResult(exitCode, output.toString());
}

HookResult _couldNotStart(HookInvocation invocation, ProcessException error) =>
    HookResult(
      127,
      'cannot run the ${invocation.name} hook: ${error.message}'
      '${Platform.isWindows ? ' (no sh.exe was found beside git or on PATH)' : ''}',
    );

/// What to start for [program].
///
/// Everywhere but Windows the hook is started directly and the kernel reads
/// its `#!` line. Windows has no such thing, so a script goes through `sh`,
/// as Git for Windows does — and through `sh -c '"$0" "$@"'` rather than
/// `sh <script>`, so that sh execs the file and a `#!/usr/bin/env python`
/// hook is still run by python. A real executable (`MZ`) is started as is.
(String, List<String>) _commandFor(String program, List<String> arguments) {
  if (!Platform.isWindows || _isNativeExecutable(program)) {
    return (program, arguments);
  }
  return (
    _shell(),
    ['-c', r'"$0" "$@"', program.replaceAll(r'\', '/'), ...arguments],
  );
}

bool _isNativeExecutable(String path) {
  RandomAccessFile? file;
  try {
    file = File(path).openSync();
    final head = file.readSync(2);
    return head.length == 2 && head[0] == 0x4d && head[1] == 0x5a;
  } on FileSystemException {
    return false;
  } finally {
    file?.closeSync();
  }
}

String? _foundShell;

/// Git for Windows' `sh.exe`: beside the `git` on PATH first, since that is
/// the shell git itself would use, and then anything called `sh` on PATH.
String _shell() => _foundShell ??= _searchShell();

String _searchShell() {
  final directories =
      (Platform.environment['PATH'] ?? Platform.environment['Path'] ?? '')
          .split(';')
          .where((entry) => entry.isNotEmpty)
          .toList();

  for (final directory in directories) {
    if (!File(p.join(directory, 'git.exe')).existsSync()) continue;
    // git.exe lives in <root>\cmd, <root>\bin or <root>\mingw64\bin.
    final parent = p.dirname(directory);
    for (final root in [parent, p.dirname(parent)]) {
      for (final candidate in [
        p.join(root, 'bin', 'sh.exe'),
        p.join(root, 'usr', 'bin', 'sh.exe'),
      ]) {
        if (File(candidate).existsSync()) return candidate;
      }
    }
  }
  for (final directory in directories) {
    final candidate = p.join(directory, 'sh.exe');
    if (File(candidate).existsSync()) return candidate;
  }
  return 'sh';
}
