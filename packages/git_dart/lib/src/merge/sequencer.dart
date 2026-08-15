import 'dart:io';

import 'package:path/path.dart' as p;

import '../object_id.dart';
import '../objects/commit.dart';
import '../objects/identity.dart';
import '../repository.dart';

/// What a repository is in the middle of.
///
/// Git keeps these as files in the git directory rather than as a flag, so the
/// state survives the process that started it — which is the point: a
/// conflicted cherry-pick is finished by a person, possibly tomorrow, possibly
/// with a different tool.
enum SequencerOperation {
  cherryPick,
  revert,
  rebase,
}

/// The commit being applied, and what to do when it lands.
class SequencerState {
  final SequencerOperation operation;

  /// The commit currently being applied.
  final ObjectId current;

  /// What is left to apply after it, oldest first.
  final List<ObjectId> remaining;

  /// Where the operation started, so it can be abandoned.
  final ObjectId originalHead;

  /// The branch that was checked out, so it can be moved at the end. Null
  /// when the operation started on a detached HEAD.
  final String? branch;

  const SequencerState({
    required this.operation,
    required this.current,
    required this.remaining,
    required this.originalHead,
    this.branch,
  });

  String get _name => switch (operation) {
        SequencerOperation.cherryPick => 'cherry-pick',
        SequencerOperation.revert => 'revert',
        SequencerOperation.rebase => 'rebase',
      };

  /// The directory git keeps this in, and which its presence announces.
  static String directoryFor(String gitDirectory, SequencerOperation op) =>
      p.join(
        gitDirectory,
        op == SequencerOperation.rebase ? 'rebase-merge' : 'sequencer',
      );

  void writeTo(String gitDirectory) {
    final directory = Directory(directoryFor(gitDirectory, operation))
      ..createSync(recursive: true);

    File(p.join(directory.path, 'head')).writeAsStringSync(
      '${originalHead.hex}\n',
    );
    File(p.join(directory.path, 'current')).writeAsStringSync(
      '${current.hex}\n',
    );
    File(p.join(directory.path, 'todo')).writeAsStringSync(
      remaining.map((id) => '$_name ${id.hex}').join('\n') +
          (remaining.isEmpty ? '' : '\n'),
    );
    if (branch != null) {
      File(p.join(directory.path, 'head-name')).writeAsStringSync('$branch\n');
    }

    // The name of the commit being applied, where git puts it and where a
    // person looking at a conflicted tree will expect to find it.
    File(p.join(gitDirectory, switch (operation) {
      SequencerOperation.cherryPick => 'CHERRY_PICK_HEAD',
      SequencerOperation.revert => 'REVERT_HEAD',
      SequencerOperation.rebase => 'REBASE_HEAD',
    }))
        .writeAsStringSync('${current.hex}\n');
  }

  static SequencerState? read(String gitDirectory) {
    for (final operation in SequencerOperation.values) {
      final directory = Directory(directoryFor(gitDirectory, operation));
      final current = File(p.join(directory.path, 'current'));
      if (!current.existsSync()) continue;

      final head = File(p.join(directory.path, 'head'));
      final todo = File(p.join(directory.path, 'todo'));
      final headName = File(p.join(directory.path, 'head-name'));

      return SequencerState(
        operation: operation,
        current: ObjectId.fromHex(current.readAsStringSync().trim()),
        originalHead: ObjectId.fromHex(head.readAsStringSync().trim()),
        remaining: [
          if (todo.existsSync())
            for (final line in todo.readAsLinesSync())
              if (line.trim().isNotEmpty)
                ObjectId.fromHex(line.trim().split(' ').last),
        ],
        branch: headName.existsSync()
            ? headName.readAsStringSync().trim()
            : null,
      );
    }
    return null;
  }

  static void clear(String gitDirectory) {
    for (final operation in SequencerOperation.values) {
      final directory = Directory(directoryFor(gitDirectory, operation));
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
    for (final name in const [
      'CHERRY_PICK_HEAD',
      'REVERT_HEAD',
      'REBASE_HEAD',
    ]) {
      final file = File(p.join(gitDirectory, name));
      if (file.existsSync()) file.deleteSync();
    }
  }
}

/// The message git writes for a revert of [commit].
String revertMessage(Commit commit) {
  final summary = commit.message.split('\n').first.trim();
  return 'Revert "$summary"\n\n'
      'This reverts commit ${commit.id.hex}.\n';
}

/// The author to record when replaying [commit].
///
/// A cherry-pick keeps the original author and takes a new committer: the
/// change is still theirs, and the act of putting it here is someone else's.
/// That two-name split is the entire reason a commit has both fields.
Identity authorFor(Repository repository, Commit commit) => commit.author;
