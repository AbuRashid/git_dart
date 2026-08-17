import 'git_fs.dart';
import 'io_git_fs.dart';

/// The filesystem to use where `dart:io` works, which is everywhere but web.
GitFs defaultGitFs() => const IoGitFs();
