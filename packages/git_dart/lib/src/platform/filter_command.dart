/// Running a filter driver's configured command.
///
/// `filter.<driver>.clean` and `filter.<driver>.smudge` are shell commands, and
/// running one needs a subprocess: `dart:io`, which a browser does not have.
/// The choice is made here, once, so that nothing reachable from the library's
/// entry point imports `dart:io` unconditionally. In a browser the stand-in
/// refuses with an [UnsupportedError] that names the command — a filter that
/// silently did nothing would store a different object than git does, and that
/// is a far worse failure than an exception.
library;

import 'dart:typed_data';

import 'filter_command_io.dart'
    if (dart.library.js_interop) 'filter_command_web.dart' as impl;

/// What a filter command did: its exit status, what it wrote to standard
/// output (the filtered content), and what it wrote to standard error.
typedef FilterCommandResult = ({
  int exitCode,
  Uint8List stdout,
  String stderr,
});

/// Runs [command] through the shell, as git does, with [input] on standard
/// input and [workingDirectory] — the working tree root — as the current
/// directory.
///
/// Throws [UnsupportedError] where there are no processes to run.
FilterCommandResult runFilterCommand(
  String command,
  Uint8List input, {
  required String workingDirectory,
}) =>
    impl.runFilterCommand(command, input, workingDirectory: workingDirectory);
