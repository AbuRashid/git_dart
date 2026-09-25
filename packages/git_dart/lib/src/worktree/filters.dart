/// Filter drivers: the `filter` attribute, and the clean and smudge steps it
/// names.
///
/// A path with `filter=<driver>` is passed through a program on its way into
/// the repository ("clean") and on its way back out ("smudge"). What is stored
/// is whatever the clean step produced, so a repository that uses a filter —
/// Git LFS is the one everybody meets — holds objects that a reader without
/// the filter cannot reproduce from the working tree. Ignoring the attribute
/// therefore does not degrade gracefully: staging stores the wrong blob,
/// checkout writes pointer files instead of content, and status reports every
/// filtered file as modified.
///
/// The order is git's (`convert.c`), and it is not symmetric by accident. On
/// the way in the driver sees the file exactly as it is on disk, and line
/// endings are normalised afterwards, in what it produced. On the way out the
/// line endings are converted first and the driver sees the result — so the
/// driver always deals with working-tree bytes, in both directions, and the
/// round trip is the identity whenever the driver's two halves are inverses.
///
/// Two ways to supply a driver:
///
/// * In-process, as a [FilterDriver] registered by name — on a repository
///   ([Repository.filters]) or for the whole program ([FilterDriver.registry]),
///   the repository's winning. This is the only way on the web, and the way a
///   test or an application provides something like LFS without a program on
///   the PATH.
/// * Configured, as `filter.<driver>.clean` and `filter.<driver>.smudge`: shell
///   commands, run exactly as git runs them. Not available on the web, where
///   trying raises [UnsupportedError].
///
/// Not supported: `filter.<driver>.process`, git's long-running filter
/// protocol (used by `git lfs filter-process`). Only the one-shot `clean` and
/// `smudge` commands are run. A driver configured with `process` alone is
/// treated as not configured, which is what git without that protocol would do
/// too — the content passes through.
library;

import 'dart:typed_data';

import '../config/git_config.dart';
import '../platform/filter_command.dart';

/// One direction of a filter: the content in, the filtered content out.
///
/// [path] is the file's path relative to the working tree root, with forward
/// slashes — what git substitutes for `%f`.
typedef FilterFunction = Uint8List Function(String path, Uint8List content);

/// An in-process filter driver, looked up by the name in `filter=<name>`.
///
/// Either half may be null, meaning that direction passes the content through
/// unchanged — git's answer for a driver with no `clean` or no `smudge`
/// configured. Whatever a half throws propagates to the caller: an in-process
/// filter's failure is the caller's own and is not second-guessed.
///
/// ```dart
/// repository.filters['lfs'] = FilterDriver(
///   clean: (path, content) => storeAndPoint(content),
///   smudge: (path, pointer) => fetchContent(pointer),
/// );
/// ```
class FilterDriver {
  /// Working tree to repository: applied when staging, and when status hashes
  /// a working-tree file to compare it with the index.
  final FilterFunction? clean;

  /// Repository to working tree: applied wherever a blob is written out —
  /// checkout, reset, restore, stash, merge.
  final FilterFunction? smudge;

  const FilterDriver({this.clean, this.smudge});

  /// Drivers available to every repository in this program, by name.
  ///
  /// A repository's own [Repository.filters] take precedence, and both take
  /// precedence over a command in the config. Global because some
  /// repositories are opened on the caller's behalf — a clone checks out
  /// before the caller ever holds the [Repository] — and a filter that exists
  /// only after the first checkout is one that checkout did not use.
  static final Map<String, FilterDriver> registry = {};
}

/// A configured filter command failed and `filter.<driver>.required` was set.
///
/// Without `required`, git reports the failure and carries on with the
/// content unfiltered; with it, the operation stops. The same here, except
/// that a library has nowhere to report to, so the unrequired failure is
/// silent.
class FilterException implements Exception {
  final String path;
  final String driver;

  /// `clean` or `smudge`.
  final String direction;

  final int exitCode;
  final String stderr;

  const FilterException({
    required this.path,
    required this.driver,
    required this.direction,
    required this.exitCode,
    required this.stderr,
  });

  @override
  String toString() =>
      'FilterException: $path: $direction filter \'$driver\' failed '
      '(exit $exitCode)${stderr.isEmpty ? '' : ': ${stderr.trim()}'}';
}

/// Applies filter drivers for one repository.
///
/// Holds nothing but where to look, so it is cheap to make; the lookup order
/// is [registered], then [FilterDriver.registry], then [config].
class ContentFilters {
  final GitConfig config;

  /// Where configured commands run: git runs them at the working tree root.
  final String? workTree;

  final Map<String, FilterDriver> registered;

  /// Whether a driver named only by the repository's configuration may be
  /// run. False for a repository opened for inspection: the commands are the
  /// repository's, and whoever wrote them is not necessarily whoever is
  /// reading it.
  final bool runConfiguredCommands;

  /// Paths whose configured driver was not run because of that, in the order
  /// they were met. A caller comparing content has to know that what it
  /// compared was not normalised the way git would have normalised it.
  final List<String> skippedConfiguredDrivers = [];

  ContentFilters({
    required this.config,
    required this.workTree,
    required this.registered,
    this.runConfiguredCommands = true,
  });

  /// The driver name `filter=<name>` gives in [attributes], or null.
  ///
  /// Only a string value names a driver: `filter` set, unset or unspecified
  /// names nothing, as in git.
  static String? driverName(Map<String, Object?> attributes) {
    final value = attributes['filter'];
    return value is String ? value : null;
  }

  /// [content] after the named driver's clean step.
  Uint8List clean(String path, String? driver, Uint8List content) =>
      _apply(path, driver, content, 'clean');

  /// [content] after the named driver's smudge step.
  Uint8List smudge(String path, String? driver, Uint8List content) =>
      _apply(path, driver, content, 'smudge');

  Uint8List _apply(
    String path,
    String? driver,
    Uint8List content,
    String direction,
  ) {
    if (driver == null) return content;

    final inProcess = registered[driver] ?? FilterDriver.registry[driver];
    if (inProcess != null) {
      final function =
          direction == 'clean' ? inProcess.clean : inProcess.smudge;
      return function == null ? content : function(path, content);
    }

    final command = config['filter.$driver.$direction'];
    // No driver configured is not an error: the attribute names a filter
    // this repository does not have, and git passes the content through.
    if (command == null || command.isEmpty) return content;

    if (!runConfiguredCommands) {
      // The content goes through unchanged, and the path is remembered: a
      // comparison made without the filter git would have applied is not the
      // comparison git would have made, and saying nothing would imply it
      // was.
      skippedConfiguredDrivers.add(path);
      return content;
    }

    final result = runFilterCommand(
      command.replaceAll('%f', _shellQuote(path)),
      content,
      workingDirectory: workTree ?? '.',
    );
    if (result.exitCode == 0) return result.stdout;

    if (config.boolean('filter.$driver.required') ?? false) {
      throw FilterException(
        path: path,
        driver: driver,
        direction: direction,
        exitCode: result.exitCode,
        stderr: result.stderr,
      );
    }
    // git prints "external filter ... failed" and uses the content as it was.
    return content;
  }

  /// git's `sq_quote_buf`: single quotes, with each embedded quote closed,
  /// escaped and reopened.
  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", r"'\''")}'";
}
