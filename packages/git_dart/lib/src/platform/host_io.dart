import 'dart:io';

Map<String, String> get environment => Platform.environment;

bool get isWindows => Platform.isWindows;

int get processId => pid;

/// Clears the read-only attribute from everything under [directory].
///
/// A no-op off Windows, where the attribute does not exist and the call would
/// only fail looking for a program that is not there.
void clearReadOnlyUnder(String directory) {
  if (!Platform.isWindows) return;
  Process.runSync('attrib', ['-R', '$directory\\*', '/S']);
}
