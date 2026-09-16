/// [IoGitFs] in a browser, where `dart:io` has no filesystem to reach.
///
/// Kept under the same name so code that mentions it still compiles for the
/// web; it refuses every operation exactly as the web's default filesystem
/// does, saying to install one with `useGitFileSystem`.
library;

import 'default_fs_web.dart';

class IoGitFs extends UnconfiguredGitFs {
  const IoGitFs();
}
