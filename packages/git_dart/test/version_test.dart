/// The version the library reports matches the one it is published as.
library;

import 'dart:io';

import 'package:git_dart/src/version.dart';
import 'package:test/test.dart';

void main() {
  test('packageVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final declared = RegExp(r'^version:\s*(\S+)', multiLine: true)
        .firstMatch(pubspec)!
        .group(1);
    expect(packageVersion, declared);
    expect(userAgent, 'git/git_dart-$declared');
  });
}
