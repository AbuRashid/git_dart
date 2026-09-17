import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Runs [command] with `sh -c`, feeding it [input] on standard input.
///
/// `Process.runSync` has no way to write to the child's standard input, and
/// the library's API is synchronous, so the content goes into a temporary file
/// and the shell redirects from it. The command is passed as a positional
/// argument and `eval`ed rather than spliced into the script, so nothing in it
/// — quotes, pipes, a `%f` that became a quoted path — is parsed twice.
({int exitCode, Uint8List stdout, String stderr}) runFilterCommand(
  String command,
  Uint8List input, {
  required String workingDirectory,
}) {
  final scratch = Directory.systemTemp.createTempSync('git_dart_filter');
  try {
    final inputFile = File(p.join(scratch.path, 'input'))
      ..writeAsBytesSync(input);
    final result = Process.runSync(
      _shell(),
      [
        '-c',
        r'f=$1; shift; eval "$1" < "$f"',
        'sh',
        // The shell may be MSYS's, which understands forward slashes on any
        // drive and does not always understand backslashes.
        inputFile.path.replaceAll(r'\', '/'),
        command,
      ],
      workingDirectory: workingDirectory,
      stdoutEncoding: null,
      stderrEncoding: systemEncoding,
    );
    final out = result.stdout as List<int>;
    return (
      exitCode: result.exitCode,
      stdout: out is Uint8List ? out : Uint8List.fromList(out),
      stderr: result.stderr as String,
    );
  } finally {
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // A temporary file left behind is not worth failing a checkout over.
    }
  }
}

String? _cachedShell;

/// The shell git would use.
///
/// Everywhere but Windows that is `sh` on the PATH. On Windows git uses the
/// `sh.exe` it ships with, which is on the PATH inside Git Bash and usually
/// not in a plain console — so when it is not found there, it is looked for
/// beside `git.exe` itself.
String _shell() {
  final cached = _cachedShell;
  if (cached != null) return cached;
  if (!Platform.isWindows) return _cachedShell = 'sh';

  if (_runs('sh')) return _cachedShell = 'sh';
  try {
    final where = Process.runSync('where', ['git']);
    if (where.exitCode == 0) {
      for (final line in (where.stdout as String).split(RegExp(r'\r?\n'))) {
        if (line.trim().isEmpty) continue;
        // git.exe lives in <root>\cmd, <root>\bin or <root>\mingw64\bin.
        var directory = p.dirname(line.trim());
        for (var i = 0; i < 3; i++) {
          for (final candidate in [
            p.join(directory, 'usr', 'bin', 'sh.exe'),
            p.join(directory, 'bin', 'sh.exe'),
          ]) {
            if (File(candidate).existsSync()) return _cachedShell = candidate;
          }
          directory = p.dirname(directory);
        }
      }
    }
  } on ProcessException {
    // No `where`, or no git: fall through to the plain name and let running
    // it report what is missing.
  }
  return _cachedShell = 'sh';
}

bool _runs(String executable) {
  try {
    return Process.runSync(executable, ['-c', 'exit 0']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
