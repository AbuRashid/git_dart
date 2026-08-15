import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../object_id.dart';
import '../objects/identity.dart';

/// One line of a ref's history: where it was, where it went, who moved it and
/// why (`refs.reflog`).
///
/// Objects never change and a branch moves, so a commit that a branch has been
/// moved off is reachable from nothing and is invisible to every ordinary
/// query. The reflog is the one record that it was ever there, which is what
/// makes a lost commit findable — and it is why an amend or a hard reset is
/// recoverable at all.
class ReflogEntry {
  /// Where the ref pointed before. The zero id for the entry that created it.
  final ObjectId from;
  final ObjectId to;
  final Identity who;

  /// What moved it — `commit`, `checkout: moving from a to b`, `merge x`.
  /// Free text: nothing parses it, and people read it.
  final String message;

  const ReflogEntry({
    required this.from,
    required this.to,
    required this.who,
    required this.message,
  });

  bool get isCreation => from == ObjectId.zero;

  /// `<old> <new> <who>\t<message>` — the identity in the same form a commit
  /// uses, so the seconds and the timezone come along with it.
  String get line => '${from.hex} ${to.hex} $who\t$message\n';

  static ReflogEntry? parse(String line) {
    if (line.trim().isEmpty) return null;
    final tab = line.indexOf('\t');
    final head = tab < 0 ? line : line.substring(0, tab);
    final message = tab < 0 ? '' : line.substring(tab + 1).trimRight();

    // Two names, a space, then the identity — which itself contains spaces, so
    // the split is by position rather than by counting fields.
    if (head.length < ObjectId.hexLength * 2 + 2) return null;
    final from = head.substring(0, ObjectId.hexLength);
    final to = head.substring(ObjectId.hexLength + 1, ObjectId.hexLength * 2 + 1);
    final identity = head.substring(ObjectId.hexLength * 2 + 2).trim();

    try {
      return ReflogEntry(
        from: ObjectId.fromHex(from),
        to: ObjectId.fromHex(to),
        who: Identity.parse(identity),
        message: message,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() => '${to.hex.substring(0, 8)} $message';
}

/// The log of one ref, oldest first — the order the file stores.
///
/// `HEAD@{0}` is the *newest*, so an index into this list counts from the end;
/// [entryAt] does that so callers do not each get it wrong.
class Reflog {
  final String refPath;
  final List<ReflogEntry> entries;

  const Reflog({required this.refPath, required this.entries});

  bool get isEmpty => entries.isEmpty;
  int get length => entries.length;

  /// `<ref>@{n}`: the value the ref held n moves ago, newest first.
  ///
  /// `@{0}` is where it points now — the `to` of the newest entry, which is
  /// the last line of the file. `@{1}` is the `to` of the line before it, so
  /// counting runs backwards from the end. Null when the log does not reach
  /// that far back, which is the honest answer: the log is trimmed over time
  /// and is not a complete history.
  ObjectId? entryAt(int n) {
    if (entries.isEmpty || n < 0) return null;
    final index = entries.length - 1 - n;
    if (index < 0) return null;
    return entries[index].to;
  }

  static Reflog read(String gitDirectory, String refPath) {
    final file = File(pathOf(gitDirectory, refPath));
    if (!file.existsSync()) return Reflog(refPath: refPath, entries: const []);

    final entries = <ReflogEntry>[];
    for (final line in LineSplitter.split(file.readAsStringSync())) {
      final entry = ReflogEntry.parse(line);
      if (entry != null) entries.add(entry);
    }
    return Reflog(refPath: refPath, entries: entries);
  }

  static String pathOf(String gitDirectory, String refPath) =>
      p.join(gitDirectory, 'logs', refPath.replaceAll('/', p.separator));
}
