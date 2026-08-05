import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

enum LineKind { context, inserted, deleted }

class DiffLine {
  final LineKind kind;
  final String text;

  /// Line numbers, one-based, null on the side the line is absent from.
  final int? oldLine;
  final int? newLine;

  const DiffLine(this.kind, this.text, {this.oldLine, this.newLine});

  @override
  String toString() => switch (kind) {
        LineKind.context => ' $text',
        LineKind.inserted => '+$text',
        LineKind.deleted => '-$text',
      };
}

/// A run of changed lines with context around it — what `@@ -a,b +c,d @@`
/// announces.
class DiffHunk {
  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<DiffLine> lines;

  const DiffHunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.lines,
  });

  /// The `@@ -a,b +c,d @@` line.
  ///
  /// A count of one is written without it — `@@ -1 +1,2 @@` — which is what
  /// git prints and therefore what anything reading these headers expects.
  String get header =>
      '@@ -${_range(oldStart, oldCount)} +${_range(newStart, newCount)} @@';

  static String _range(int start, int count) =>
      count == 1 ? '$start' : '$start,$count';

  @override
  String toString() => [header, ...lines].join('\n');
}

class TextDiff {
  final List<DiffHunk> hunks;

  /// True when either side is not text. Git does not diff binary content, and
  /// neither does this — a byte-level diff of a PNG helps nobody.
  final bool isBinary;

  /// True when the two sides were too different to diff within the edit
  /// budget, and the result is the whole file replaced rather than a minimal
  /// script. Reported rather than hidden: a caller showing "the entire file
  /// changed" should be able to say why.
  final bool truncated;

  const TextDiff({
    required this.hunks,
    this.isBinary = false,
    this.truncated = false,
  });

  bool get isEmpty => hunks.isEmpty && !isBinary;

  int get insertions => hunks
      .expand((h) => h.lines)
      .where((l) => l.kind == LineKind.inserted)
      .length;

  int get deletions => hunks
      .expand((h) => h.lines)
      .where((l) => l.kind == LineKind.deleted)
      .length;

  @override
  String toString() =>
      isBinary ? 'Binary files differ' : hunks.join('\n');
}

/// True when [content] looks like something no one wants to see as lines.
///
/// Git's own rule, and the reason it is a rule rather than a judgement: a NUL
/// in the first few thousand bytes.
bool looksBinary(Uint8List content) {
  final limit = math.min(content.length, 8000);
  for (var i = 0; i < limit; i++) {
    if (content[i] == 0) return true;
  }
  return false;
}

List<String> splitLines(Uint8List content) {
  if (content.isEmpty) return const [];
  final text = utf8.decode(content, allowMalformed: true);
  final lines = text.split('\n');
  // A trailing newline ends the last line rather than starting an empty one.
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines.map((line) {
    return line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
  }).toList();
}

/// Diffs two blobs line by line.
///
/// Nothing is stored: git keeps whole objects and computes differences on
/// demand (`algorithms.diff`), so this runs against the two contents and
/// nothing else.
TextDiff diffText(
  Uint8List before,
  Uint8List after, {
  int context = 3,
  int maxEdits = 20000,
}) {
  if (looksBinary(before) || looksBinary(after)) {
    final same = before.length == after.length &&
        List.generate(before.length, (i) => before[i] == after[i])
            .every((equal) => equal);
    return TextDiff(hunks: const [], isBinary: !same);
  }

  final oldLines = splitLines(before);
  final newLines = splitLines(after);

  final script = _myers(oldLines, newLines, maxEdits);
  if (script == null) {
    // Beyond the budget: report the file as replaced, and say so.
    return TextDiff(
      hunks: _toHunks(
        [
          for (var i = 0; i < oldLines.length; i++)
            DiffLine(LineKind.deleted, oldLines[i], oldLine: i + 1),
          for (var i = 0; i < newLines.length; i++)
            DiffLine(LineKind.inserted, newLines[i], newLine: i + 1),
        ],
        context,
      ),
      truncated: true,
    );
  }

  return TextDiff(hunks: _toHunks(script, context));
}

/// Myers' difference algorithm: walk the edit graph one edit-distance at a
/// time and keep each step, then trace the path back.
///
/// Returns null when the two sides are more than [maxEdits] apart. The cap is
/// not an approximation of the answer — it is a refusal to spend unbounded
/// time on a file that has been rewritten, where a minimal script would not be
/// read anyway.
List<DiffLine>? _myers(List<String> a, List<String> b, int maxEdits) {
  final n = a.length;
  final m = b.length;
  final maxD = math.min(maxEdits, n + m);
  final offset = maxD + 1;

  var v = List<int>.filled(2 * maxD + 3, 0);
  final trace = <List<int>>[];

  for (var d = 0; d <= maxD; d++) {
    trace.add(List<int>.of(v));
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset])) {
        x = v[k + 1 + offset]; // came down: an insertion
      } else {
        x = v[k - 1 + offset] + 1; // came right: a deletion
      }
      var y = x - k;
      // A snake: run along the diagonal while the lines match, which is where
      // the algorithm gets its speed on files that mostly agree.
      while (x < n && y < m && a[x] == b[y]) {
        x += 1;
        y += 1;
      }
      v[k + offset] = x;
      if (x >= n && y >= m) return _backtrack(a, b, trace, offset);
    }
  }
  return null;
}

List<DiffLine> _backtrack(
  List<String> a,
  List<String> b,
  List<List<int>> trace,
  int offset,
) {
  final reversed = <DiffLine>[];
  var x = a.length;
  var y = b.length;

  for (var d = trace.length - 1; d >= 0; d--) {
    final v = trace[d];
    final k = x - y;

    final int previousK;
    if (k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset])) {
      previousK = k + 1;
    } else {
      previousK = k - 1;
    }
    final previousX = v[previousK + offset];
    final previousY = previousX - previousK;

    while (x > previousX && y > previousY) {
      x -= 1;
      y -= 1;
      reversed.add(
        DiffLine(LineKind.context, a[x], oldLine: x + 1, newLine: y + 1),
      );
    }

    if (d == 0) break;

    if (x == previousX) {
      y -= 1;
      reversed.add(DiffLine(LineKind.inserted, b[y], newLine: y + 1));
    } else {
      x -= 1;
      reversed.add(DiffLine(LineKind.deleted, a[x], oldLine: x + 1));
    }
  }

  return reversed.reversed.toList();
}

/// Gathers changed lines into hunks, keeping [context] unchanged lines either
/// side and dropping the long stretches between them.
List<DiffHunk> _toHunks(List<DiffLine> script, int context) {
  final changed = <int>[
    for (var i = 0; i < script.length; i++)
      if (script[i].kind != LineKind.context) i,
  ];
  if (changed.isEmpty) return const [];

  final hunks = <DiffHunk>[];
  var index = 0;

  while (index < changed.length) {
    final start = math.max(0, changed[index] - context);
    var last = changed[index];

    // Absorb the next change when its context would touch this hunk's.
    while (index + 1 < changed.length &&
        changed[index + 1] - last <= context * 2) {
      index += 1;
      last = changed[index];
    }
    index += 1;

    final end = math.min(script.length, last + context + 1);
    final lines = script.sublist(start, end);

    final oldNumbers = lines.map((l) => l.oldLine).whereType<int>();
    final newNumbers = lines.map((l) => l.newLine).whereType<int>();

    hunks.add(DiffHunk(
      oldStart: oldNumbers.isEmpty ? 0 : oldNumbers.first,
      oldCount: oldNumbers.length,
      newStart: newNumbers.isEmpty ? 0 : newNumbers.first,
      newCount: newNumbers.length,
      lines: lines,
    ));
  }

  return hunks;
}
