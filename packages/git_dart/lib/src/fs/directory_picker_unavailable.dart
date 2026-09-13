/// No picker off the web — there is nothing to pick from that a real
/// filesystem does not already offer directly.
library;

import 'memory_git_fs.dart';

Future<bool> isAvailable() async => false;

Future<String?> pickDirectoryInto(
  MemoryGitFs memory,
  String Function(String folderName) placeAt,
) async =>
    throw UnsupportedError(
      'the directory picker is a browser feature; open the folder directly '
      'on this platform instead',
    );
