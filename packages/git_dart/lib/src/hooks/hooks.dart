/// Client-side hooks: the programs git runs around its own operations.
///
/// A hook is how a repository gets a say in what is done to it — a linter
/// before a commit, a ticket number added to a message, a test run before a
/// push. A library that commits and pushes without running them is not doing
/// what git does in that repository, and the difference only shows up later,
/// as a commit that would never have been allowed. So this library runs them,
/// at the same points git does and with the same arguments.
///
/// Who runs them is a [HookRunner], held by each `Repository` in its `hooks`
/// field and replaceable at any time:
///
/// - [HookRunner.disk], the default, finds hooks where git does and runs them
///   as git does. In a browser there are no processes, so it finds nothing
///   and every operation proceeds as if the repository had no hooks.
/// - [HookRunner.none] runs nothing, for a caller that wants git_dart's own
///   behaviour whatever the repository says.
/// - [HookRunner.inProcess] runs Dart callbacks by hook name — the only kind
///   of hook there is on the web, and the convenient kind in tests.
///
/// Every operation that runs a veto hook (`pre-commit`, `commit-msg`,
/// `pre-merge-commit`, `pre-push`, `pre-rebase`) also takes `noVerify`, which
/// skips exactly the hooks git's `--no-verify` skips for that command.
library;

import 'dart:async';

import 'package:path/path.dart' as p;

import '../fs/git_fs.dart';
import '../platform/host.dart' as host;
import '../repository.dart';
import 'hook_process.dart' as process;

/// An in-process hook. Returning a non-zero [HookResult.exitCode] from a veto
/// hook aborts the operation, exactly as a script's exit status would.
typedef HookCallback = FutureOr<HookResult> Function(HookInvocation invocation);

/// One hook about to run: which, with what, and where.
class HookInvocation {
  /// The hook's name, such as `pre-commit`.
  final String name;

  final Repository repository;

  /// The arguments git passes this hook, in git's order.
  final List<String> arguments;

  /// What git writes to the hook's standard input, or null for none. Only
  /// `pre-push` has any.
  final String? stdin;

  /// The variables git sets for this hook — `GIT_DIR` always, and
  /// `GIT_INDEX_FILE` and `GIT_EDITOR` for the commit hooks. A process hook
  /// gets these on top of this process's own environment.
  final Map<String, String> environment;

  /// Where the hook runs: the working tree's root, or the git directory of a
  /// bare repository. Relative paths in [arguments] are relative to this.
  final String workingDirectory;

  const HookInvocation({
    required this.name,
    required this.repository,
    this.arguments = const [],
    this.stdin,
    this.environment = const {},
    required this.workingDirectory,
  });

  /// Reads a file a hook was handed — the message file of `commit-msg`, say —
  /// through the same filesystem the repository is on, which in a browser is
  /// the only way to reach it.
  String readFile(String path) => fs.file(_resolve(path)).readAsStringSync();

  /// Replaces a file a hook was handed. This is how `commit-msg` and
  /// `prepare-commit-msg` change the message.
  void writeFile(String path, String contents) =>
      fs.file(_resolve(path)).writeAsStringSync(contents);

  String _resolve(String path) =>
      p.isAbsolute(path) ? path : p.join(workingDirectory, path);

  @override
  String toString() => [name, ...arguments].join(' ');
}

/// How a hook ended.
class HookResult {
  final int exitCode;

  /// Everything it printed, standard output and standard error together —
  /// git sends both to the terminal, and a person reading why a commit was
  /// refused needs both.
  final String output;

  const HookResult(this.exitCode, [this.output = '']);

  static const HookResult success = HookResult(0);

  bool get ok => exitCode == 0;
}

/// A hook refused the operation, or could not be run at all.
///
/// Thrown before anything the hook was guarding has happened: no commit is
/// written and no ref is moved.
class HookFailedException implements Exception {
  final String hook;
  final int exitCode;
  final String output;

  const HookFailedException(this.hook, this.exitCode, this.output);

  @override
  String toString() {
    final text = output.trimRight();
    return 'HookFailedException: the $hook hook exited with $exitCode'
        '${text.isEmpty ? '' : ':\n$text'}';
  }
}

/// Decides whether a hook exists and runs it.
abstract class HookRunner {
  const HookRunner();

  /// Hooks from the filesystem, found and run the way git does.
  static const HookRunner disk = DiskHookRunner();

  /// No hooks, whatever the repository has.
  static const HookRunner none = _NoHooks();

  /// Dart callbacks by hook name. A hook with no callback falls to
  /// [fallback] — pass [HookRunner.disk] to add to a repository's own hooks
  /// rather than replace them.
  factory HookRunner.inProcess(
    Map<String, HookCallback> hooks, {
    HookRunner fallback,
  }) = _CallbackHooks;

  /// Runs the hook, or returns null when there is no such hook.
  ///
  /// For the synchronous operations — everything but push. A hook that needs
  /// [HookInvocation.stdin] or completes asynchronously has to go through
  /// [run].
  HookResult? runSync(HookInvocation invocation);

  /// Runs the hook, or completes with null when there is no such hook.
  Future<HookResult?> run(HookInvocation invocation) async =>
      runSync(invocation);
}

class _NoHooks extends HookRunner {
  const _NoHooks();

  @override
  HookResult? runSync(HookInvocation invocation) => null;
}

class _CallbackHooks extends HookRunner {
  final Map<String, HookCallback> hooks;
  final HookRunner fallback;

  _CallbackHooks(Map<String, HookCallback> hooks,
      {this.fallback = HookRunner.none})
      : hooks = Map.of(hooks);

  @override
  HookResult? runSync(HookInvocation invocation) {
    final callback = hooks[invocation.name];
    if (callback == null) return fallback.runSync(invocation);
    final result = callback(invocation);
    if (result is Future) {
      throw StateError(
        'the ${invocation.name} hook runs inside a synchronous operation and '
        'must return a HookResult, not a Future',
      );
    }
    return result;
  }

  @override
  Future<HookResult?> run(HookInvocation invocation) async {
    final callback = hooks[invocation.name];
    if (callback == null) return fallback.run(invocation);
    return await callback(invocation);
  }
}

/// Hooks as files, where git keeps them.
///
/// The directory is `core.hooksPath` when set — a relative one taken from
/// where hooks run, the working tree's root, as git takes it — and otherwise
/// `hooks` in the repository's shared git directory, so every linked worktree
/// runs the same ones. A hook is the file named exactly for it: the
/// `*.sample` files git installs are never run, because that suffix is what
/// keeps them inert. Off Windows the file must also be executable, as git
/// requires; a hook someone disabled with `chmod -x` stays disabled.
///
/// On Windows there is no executable bit, and a script cannot be started
/// directly. Git for Windows runs hooks through the `sh` it ships with, and so
/// does this: `sh.exe` is looked for beside the `git` on `PATH`, then on
/// `PATH` itself. A native `.exe` hook runs directly, as does `<name>.exe`,
/// which Git for Windows also accepts.
///
/// In a browser nothing can be run, so nothing is found.
class DiskHookRunner extends HookRunner {
  /// Called with the output of every hook that ran, successful or not — git
  /// prints it all, and a failing hook's output also travels in its
  /// [HookFailedException].
  final void Function(String hook, String output)? onOutput;

  const DiskHookRunner({this.onOutput});

  /// Where [repository]'s hooks live.
  static String directoryFor(Repository repository) {
    final configured = repository.config['core.hooksPath'];
    if (configured == null || configured.isEmpty) {
      return p.join(repository.commonDirectory, 'hooks');
    }
    var path = configured;
    if (path == '~' || path.startsWith('~/')) {
      final home = host.homeDirectory;
      if (home != null) {
        path = p.join(home, path.length > 2 ? path.substring(2) : '');
      }
    }
    if (p.isAbsolute(path)) return p.normalize(path);
    return p.normalize(p.join(
      repository.workTree ?? repository.gitDirectory,
      path,
    ));
  }

  String? _find(HookInvocation invocation) => process.findHookProgram(
        directoryFor(invocation.repository),
        invocation.name,
      );

  @override
  HookResult? runSync(HookInvocation invocation) {
    final program = _find(invocation);
    if (program == null) return null;
    if (invocation.stdin != null) {
      throw ArgumentError.value(invocation.name, 'invocation',
          'a hook with input has to be run asynchronously');
    }
    return _report(invocation, process.runHookSync(program, invocation));
  }

  @override
  Future<HookResult?> run(HookInvocation invocation) async {
    final program = _find(invocation);
    if (program == null) return null;
    return _report(invocation, await process.runHook(program, invocation));
  }

  HookResult _report(HookInvocation invocation, HookResult result) {
    if (result.output.isNotEmpty)
      onOutput?.call(invocation.name, result.output);
    return result;
  }
}
