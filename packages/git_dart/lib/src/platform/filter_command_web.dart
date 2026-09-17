import 'dart:typed_data';

/// A browser has no shell to run a filter command in.
///
/// Registering the driver in-process (`FilterDriver`) is the way to filter
/// content on the web, and the message says so.
({int exitCode, Uint8List stdout, String stderr}) runFilterCommand(
  String command,
  Uint8List input, {
  required String workingDirectory,
}) {
  throw UnsupportedError(
    'cannot run the filter command "$command": there are no processes on '
    'the web. Register an in-process FilterDriver for this driver name '
    'instead (Repository.filters or FilterDriver.registry).',
  );
}
