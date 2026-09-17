/// This package's version, as published.
///
/// Kept here rather than read from pubspec.yaml, which a compiled program
/// does not have. `test/version_test.dart` fails when the two disagree, so a
/// release bumps both.
const String packageVersion = '0.2.0';

/// How this library names itself to servers: in the `agent=` capability and
/// the HTTP `User-Agent`. Git servers log it and some vary behaviour on the
/// `git/` prefix, which is why it is kept.
const String userAgent = 'git/git_dart-$packageVersion';
