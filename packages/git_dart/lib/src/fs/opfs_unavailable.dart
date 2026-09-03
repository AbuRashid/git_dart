/// OPFS off the web, where there is none.
///
/// Every call throws rather than doing nothing. A caller that reached here on
/// the desktop has taken a wrong branch, and a store that quietly discarded a
/// repository would be found out much later, by which time the repository is
/// gone.
library;

import 'memory_git_fs.dart';

Never _noOpfs() => throw UnsupportedError(
      'OPFS is a browser filesystem, and this platform has a real one. Use the '
      'default filesystem instead of an OpfsStore.',
    );

Future<bool> isAvailable() async => false;

Future<MemoryGitFs> load(String root, String under) async => _noOpfs();

Future<void> save(String root, String under, MemoryGitFs memory) async =>
    _noOpfs();

Future<void> saveAll(String root, String under, MemoryGitFs memory) async =>
    _noOpfs();

Future<List<String>> list(String root) async => _noOpfs();

Future<void> delete(String root) async => _noOpfs();

Future<({int used, int available})?> usage() async => null;
