/// Settings in a file, on a platform that has somewhere to put one.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<File> _file(String key) async {
  final directory = await getApplicationSupportDirectory();
  return File(p.join(directory.path, key));
}

Future<String?> readAppSetting(String key) async {
  final file = await _file(key);
  if (!file.existsSync()) return null;
  return file.readAsStringSync();
}

Future<void> writeAppSetting(String key, String value) async {
  final file = await _file(key);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(value);
}
