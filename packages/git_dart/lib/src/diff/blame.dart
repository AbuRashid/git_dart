/// Who last touched each line of a file, and when.
///
/// Nothing records this. Git stores whole objects and no line-level history at
/// all, so the answer is derived the same way a rename is: by walking the
/// commits backwards and comparing. A line is attributed to the newest commit
/// whose version of the file has it and whose parent's version does not —
/// which means every answer is a claim about a diff, and diffs are not unique.
/// Two commits can produce the same file by different routes and blame will
/// pick one of them.
///
/// The walk follows first parents. A merge that took a side's version wholesale
/// will therefore credit the merge rather than the branch it came from, which
/// is what `git blame --first-parent` reports and is the cheaper half of a
/// question git itself answers several ways.
library;

import '../cancellation.dart';
import '../object_id.dart';
import '../objects/commit.dart';
import '../objects/git_object.dart';
import '../objects/identity.dart';
import '../repository.dart';
import 'text_diff.dart';

/// One line of the file, and the commit it came from.
class BlameLine {
  /// Where the line sits in the file as it is now, counting from one.
  final int number;

  final String text;

  /// The commit that introduced this line.
  final ObjectId commit;

  /// Who wrote it, from that commit.
  final Identity author;

  /// The summary of the commit that introduced it, for a listing that wants
  /// to say why rather than only who.
  final String summary;

  /// Where the line sat in the file when it was introduced, counting from
  /// one. Different from [number] whenever anything above it has changed
  /// since.
  final int originalNumber;

  const BlameLine({
    required this.number,
    required this.text,
    required this.commit,
    required this.author,
    required this.summary,
    required this.originalNumber,
  });

  @override
  String toString() =>
      '${commit.hex.substring(0, 8)} (${author.name} $number) $text';
}

class Blame {
  final String path;

  /// The commit the file was read at.
  final ObjectId at;

  final List<BlameLine> lines;

  const Blame({required this.path, required this.at, required this.lines});

  /// The distinct commits this file's current lines came from, newest first
  /// by the order they were met.
  List<ObjectId> get contributors {
    final seen = <ObjectId>{};
    return [
      for (final line in lines)
        if (seen.add(line.commit)) line.commit,
    ];
  }
}

/// Attributes every line of [path] to the commit that introduced it.
///
/// Returns null when the path does not name a file at [start] — there is
/// nothing to attribute, which is different from a file whose every line is
/// unattributable.
///
/// [maxCommits] bounds the walk. A line that is never resolved within it is
/// attributed to the oldest commit examined, which is honest about being a
/// floor rather than an answer: blame on a very long history is a question
/// about how much time the caller wants to spend.
Blame? blame(
  Repository repository,
  String path, {
  ObjectId? start,
  int maxCommits = 4096,
  Cancellation? cancel,
}) {
  final from = start ?? repository.headId;
  if (from == null) return null;

  final head = repository.peel(from);
  if (head is! Commit) return null;

  final contentAt = _fileAt(repository, head.id, path);
  if (contentAt == null) return null;

  final finalLines = contentAt.lines;
  if (finalLines.isEmpty) {
    return Blame(path: path, at: head.id, lines: const []);
  }

  // For each still-unattributed line of the final file, where it sits in the
  // version of the file at the commit currently being examined. Lines leave
  // this map as they are attributed.
  var pending = <int, int>{
    for (var i = 0; i < finalLines.length; i++) i: i,
  };

  final blamed = <int, ({ObjectId commit, int line})>{};
  final commits = <ObjectId, Commit>{head.id: head};

  var current = head;
  var currentContent = contentAt;
  var examined = 0;

  while (pending.isNotEmpty && examined < maxCommits) {
    // One commit examined is the unit.
    checkCancelled(cancel, 'the blame walk');
    examined += 1;

    final parent = current.parents.isEmpty ? null : current.parents.first;
    final parentContent =
        parent == null ? null : _fileAt(repository, parent, path);

    if (parentContent == null) {
      // The file starts here: everything still unattributed came from this
      // commit, whether that is the root of the history or the commit that
      // added the file.
      for (final entry in pending.entries) {
        blamed[entry.key] = (commit: current.id, line: entry.value);
      }
      pending = {};
      break;
    }

    if (parentContent.id == currentContent.id) {
      // The file did not change here, so nothing can be attributed to this
      // commit and there is no diff worth computing.
      final next = repository.objects.readRaw(parent!);
      if (next == null) break;
      final parentCommit = repository.objects.readTyped<Commit>(parent);
      commits[parent] = parentCommit;
      current = parentCommit;
      currentContent = parentContent;
      continue;
    }

    final script = editScript(parentContent.lines, currentContent.lines);
    if (script == null) {
      // Too far apart to diff within the cap. Rewritten, as far as anyone can
      // tell, so this commit is the answer for what is left.
      for (final entry in pending.entries) {
        blamed[entry.key] = (commit: current.id, line: entry.value);
      }
      pending = {};
      break;
    }

    // Where each line of the current version came from in the parent's, or
    // absent when this commit introduced it.
    final carried = <int, int>{};
    for (final line in script) {
      if (line.kind != LineKind.context) continue;
      carried[line.newLine! - 1] = line.oldLine! - 1;
    }

    final stillPending = <int, int>{};
    for (final entry in pending.entries) {
      final inParent = carried[entry.value];
      if (inParent == null) {
        // Present here and not in the parent: this commit wrote it.
        blamed[entry.key] = (commit: current.id, line: entry.value);
      } else {
        stillPending[entry.key] = inParent;
      }
    }
    pending = stillPending;

    if (pending.isEmpty) break;

    final parentCommit = repository.objects.readRaw(parent!) == null
        ? null
        : repository.objects.readTyped<Commit>(parent);
    if (parentCommit == null) break;
    commits[parent] = parentCommit;
    current = parentCommit;
    currentContent = parentContent;
  }

  // Anything left ran out of history or of budget; the oldest commit reached
  // is the floor.
  for (final entry in pending.entries) {
    blamed[entry.key] = (commit: current.id, line: entry.value);
  }

  Commit commitFor(ObjectId id) =>
      commits[id] ??= repository.objects.readTyped<Commit>(id);

  // Read once for the whole file: git shows blame under mailmapped names by
  // default, and a listing that did not would disagree with `git blame` beside
  // it about who wrote the line.
  final mailmap = repository.mailmap;

  return Blame(
    path: path,
    at: head.id,
    lines: [
      for (var i = 0; i < finalLines.length; i++)
        () {
          final source = blamed[i]!;
          final commit = commitFor(source.commit);
          return BlameLine(
            number: i + 1,
            text: finalLines[i],
            commit: source.commit,
            author: mailmap.resolve(commit.author),
            summary: commit.message.split('\n').first.trim(),
            originalNumber: source.line + 1,
          );
        }(),
    ],
  );
}

/// The file's blob and lines at [commit], or null when it is not there.
({ObjectId id, List<String> lines})? _fileAt(
  Repository repository,
  ObjectId commit,
  String path,
) {
  final tree = repository.treeOf(commit);
  if (tree == null) return null;
  final entry = repository.lookup(tree, path);
  if (entry == null || entry.mode.isTree || entry.mode.isSubmodule) return null;

  final raw = repository.objects.readRaw(entry.id);
  if (raw == null) return null; // promised, or beyond a shallow boundary
  if (looksBinary(raw.content)) return null;

  return (id: entry.id, lines: splitLines(raw.content));
}

/// The blob a path had at a commit, for a caller that wants the content
/// rather than the attribution.
Blob? fileAt(Repository repository, ObjectId commit, String path) {
  final tree = repository.treeOf(commit);
  if (tree == null) return null;
  final entry = repository.lookup(tree, path);
  if (entry == null || entry.mode.isTree) return null;
  final raw = repository.objects.readRaw(entry.id);
  return raw == null ? null : Blob(raw.content);
}
