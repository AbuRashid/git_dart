/// The steps each operation takes to run its hooks, shared so that a commit,
/// a merge and a push all build an invocation the same way.
///
/// Not exported: callers choose hooks through `Repository.hooks`, and these
/// are only the plumbing behind it.
library;

import 'package:path/path.dart' as p;

import '../fs/git_fs.dart';
import '../repository.dart';
import 'hooks.dart';

/// Where hooks run: the top of the working tree, or the git directory of a
/// bare repository — git changes to exactly these before running one.
String hookWorkingDirectory(Repository repository) =>
    repository.workTree ?? repository.gitDirectory;

HookInvocation hookInvocation(
  Repository repository,
  String name, {
  List<String> arguments = const [],
  String? stdin,
  bool commitEnvironment = false,
}) =>
    HookInvocation(
      name: name,
      repository: repository,
      arguments: arguments,
      stdin: stdin,
      workingDirectory: hookWorkingDirectory(repository),
      environment: {
        'GIT_DIR': p.absolute(repository.gitDirectory),
        // The commit hooks are told which index is being committed, so a
        // pre-commit that runs `git diff --cached` sees what is about to be
        // written; and that no editor is coming, so none of them opens one.
        if (commitEnvironment) ...{
          'GIT_INDEX_FILE': p.absolute(repository.gitDirectory, 'index'),
          'GIT_EDITOR': ':',
        },
      },
    );

/// Runs [name] and, when [veto], throws if it failed. The exit status of a
/// hook that runs after the fact — `post-commit`, `post-checkout` — decides
/// nothing, in git or here.
HookResult? runHook(
  Repository repository,
  String name, {
  List<String> arguments = const [],
  bool commitEnvironment = false,
  bool veto = true,
}) {
  final result = repository.hooks.runSync(hookInvocation(
    repository,
    name,
    arguments: arguments,
    commitEnvironment: commitEnvironment,
  ));
  if (veto && result != null && !result.ok) {
    throw HookFailedException(name, result.exitCode, result.output);
  }
  return result;
}

/// [runHook] for an asynchronous operation, with input.
Future<HookResult?> runHookAsync(
  Repository repository,
  String name, {
  List<String> arguments = const [],
  String? stdin,
  bool veto = true,
}) async {
  final result = await repository.hooks.run(hookInvocation(
    repository,
    name,
    arguments: arguments,
    stdin: stdin,
  ));
  if (veto && result != null && !result.ok) {
    throw HookFailedException(name, result.exitCode, result.output);
  }
  return result;
}

/// Passes a commit message through `prepare-commit-msg` and, unless
/// [noVerify], `commit-msg`, and returns the message they left.
///
/// The message is written to [file] first — `COMMIT_EDITMSG` for a commit,
/// `MERGE_MSG` for a merge — since a file is the only thing a hook can edit.
/// A message no hook touched comes back exactly as given. One a hook changed
/// is cleaned the way git cleans a message that did not come through an
/// editor: trailing whitespace and surplus blank lines go.
String messageThroughHooks(
  Repository repository, {
  required String message,
  required String file,
  required String source,
  required bool noVerify,
}) {
  final handle = fs.file(file);
  handle.writeAsStringSync(message);

  final argument = hookPathArgument(repository, file);
  runHook(
    repository,
    'prepare-commit-msg',
    arguments: [argument, source],
    commitEnvironment: true,
  );
  if (!noVerify) {
    runHook(
      repository,
      'commit-msg',
      arguments: [argument],
      commitEnvironment: true,
    );
  }

  final edited = handle.existsSync() ? handle.readAsStringSync() : '';
  if (edited == message) return message;
  return cleanMessage(edited);
}

/// [path] as a hook should be handed it: relative to where the hook runs,
/// with forward slashes, which is how git names `.git/COMMIT_EDITMSG` and the
/// only form every shell on every platform reads the same way.
String hookPathArgument(Repository repository, String path) {
  final base = p.absolute(hookWorkingDirectory(repository));
  final absolute = p.absolute(path);
  if (!p.isWithin(base, absolute)) return absolute;
  return p.relative(absolute, from: base).replaceAll(r'\', '/');
}

/// git's `--cleanup=whitespace`: trailing whitespace off every line, runs of
/// blank lines collapsed to one, none at either end, and a final newline.
/// Empty when nothing is left, which the caller refuses as a commit message.
String cleanMessage(String message) {
  final lines = <String>[];
  var pendingBlank = false;
  for (final raw in message.replaceAll('\r\n', '\n').split('\n')) {
    final line = raw.trimRight();
    if (line.isEmpty) {
      pendingBlank = lines.isNotEmpty;
      continue;
    }
    if (pendingBlank) lines.add('');
    pendingBlank = false;
    lines.add(line);
  }
  return lines.isEmpty ? '' : '${lines.join('\n')}\n';
}
