import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../fs/git_fs.dart';
import '../object_id.dart';
import '../objects/tree.dart';

/// Thrown when the index cannot be locked because another writer holds it.
class IndexLockedException implements Exception {
  final String path;
  const IndexLockedException(this.path);

  @override
  String toString() => 'cannot lock the index: $path.lock already exists. '
      'Another process is staging, or a previous one left the lock behind.';
}

/// The merge stage held in an entry's flags.
///
/// Zero is the ordinary case. One, two and three hold the base, ours and
/// theirs while a conflict is unresolved, which is how a conflicted file is
/// represented without a file of its own (`index.stages`).
enum MergeStage {
  ordinary(0),
  base(1),
  ours(2),
  theirs(3);

  const MergeStage(this.value);
  final int value;

  static MergeStage byValue(int value) => MergeStage.values[value];
}

/// One staged path.
class IndexEntry {
  final int ctimeSeconds;
  final int ctimeNanoseconds;
  final int mtimeSeconds;
  final int mtimeNanoseconds;
  final int device;
  final int inode;

  /// The mode as a 32-bit value — `0o100644`, not the string a tree stores.
  final int mode;

  final int uid;
  final int gid;
  final int size;
  final ObjectId id;

  /// The path, always with forward slashes, relative to the working tree root.
  final String path;

  final MergeStage stage;
  final bool assumeValid;
  final bool intentToAdd;
  final bool skipWorktree;

  const IndexEntry({
    required this.path,
    required this.id,
    required this.mode,
    this.ctimeSeconds = 0,
    this.ctimeNanoseconds = 0,
    this.mtimeSeconds = 0,
    this.mtimeNanoseconds = 0,
    this.device = 0,
    this.inode = 0,
    this.uid = 0,
    this.gid = 0,
    this.size = 0,
    this.stage = MergeStage.ordinary,
    this.assumeValid = false,
    this.intentToAdd = false,
    this.skipWorktree = false,
  });

  FileMode get fileMode => FileMode.parse(mode.toRadixString(8));

  bool get isConflicted => stage != MergeStage.ordinary;

  /// True when [stat] matches what was recorded, meaning the file need not be
  /// re-hashed.
  ///
  /// A cache, never a fact: a file changed within the same second and to the
  /// same length will match, which is why git also compares size and why
  /// `hazards` names trusting these fields (`index.the-stat-fields-are-a-cache`).
  bool matchesStat(GitFsStat stat) {
    final seconds = stat.modified.millisecondsSinceEpoch ~/ 1000;
    return seconds == mtimeSeconds && stat.size == size;
  }

  @override
  String toString() =>
      '${mode.toRadixString(8)} $id ${stage.value}\t$path';
}

/// The staging area, and a cache of the working tree's state.
class GitIndex {
  static const _signature = 0x44495243; // 'DIRC'

  final int version;

  /// Entries sorted by path, then by stage — the order the file stores them
  /// in and the order git requires.
  final List<IndexEntry> entries;

  /// Extension sections, kept verbatim by name so that reading and writing an
  /// index does not silently discard the cached tree or the untracked cache.
  final Map<String, Uint8List> extensions;

  GitIndex({
    this.version = 2,
    required this.entries,
    this.extensions = const {},
  });

  GitIndex.empty()
      : version = 2,
        entries = [],
        extensions = const {};

  static GitIndex? open(String path) {
    final file = fs.file(path);
    // An index is absent in a bare repository and before the first `add`.
    if (!file.existsSync()) return null;
    return GitIndex.parse(file.readAsBytesSync());
  }

  factory GitIndex.parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(0) != _signature) {
      throw const FormatException('index does not begin with DIRC');
    }
    final version = data.getUint32(4);
    if (version < 2 || version > 4) {
      throw FormatException('unsupported index version $version');
    }
    final count = data.getUint32(8);

    final entries = <IndexEntry>[];
    // Version 4 spells each path as "drop this many bytes from the end of the
    // one before, then these", so the previous entry's bytes are kept to
    // rebuild the next from.
    var previousPath = Uint8List(0);
    var at = 12;
    for (var i = 0; i < count; i++) {
      final start = at;
      final ctimeSeconds = data.getUint32(at);
      final ctimeNanoseconds = data.getUint32(at + 4);
      final mtimeSeconds = data.getUint32(at + 8);
      final mtimeNanoseconds = data.getUint32(at + 12);
      final device = data.getUint32(at + 16);
      final inode = data.getUint32(at + 20);
      final mode = data.getUint32(at + 24);
      final uid = data.getUint32(at + 28);
      final gid = data.getUint32(at + 32);
      final size = data.getUint32(at + 36);
      final id = ObjectId.fromBytes(bytes, at + 40);
      final flags = data.getUint16(at + 60);
      at += 62;

      final assumeValid = flags & 0x8000 != 0;
      final extended = flags & 0x4000 != 0;
      final stage = MergeStage.byValue((flags >> 12) & 0x3);
      var nameLength = flags & 0x0fff;

      var intentToAdd = false;
      var skipWorktree = false;
      if (extended) {
        if (version < 3) {
          throw const FormatException(
            'an index below version 3 may not set the extended flag',
          );
        }
        final extra = data.getUint16(at);
        at += 2;
        intentToAdd = extra & 0x2000 != 0;
        skipWorktree = extra & 0x4000 != 0;
      }

      final Uint8List pathBytes;
      if (version == 4) {
        // How much of the previous path to drop from its end, then the rest
        // of this one. Version 4 pads nothing: the next entry begins right
        // after the terminator.
        final strip = _decodeVarint(bytes, at);
        at = strip.after;
        if (strip.value > previousPath.length) {
          throw FormatException(
            'an index entry drops ${strip.value} bytes from a path of '
            '${previousPath.length}',
          );
        }
        final nul = bytes.indexOf(0, at);
        if (nul < 0) {
          throw const FormatException('index entry path is not NUL-terminated');
        }
        final kept = previousPath.length - strip.value;
        pathBytes = Uint8List(kept + (nul - at))
          ..setRange(0, kept, previousPath)
          ..setRange(kept, kept + (nul - at), bytes, at);
        at = nul + 1;
      } else {
        // 0xfff means "at least 0xfff"; the true length is found by looking
        // for the terminator.
        final nul = bytes.indexOf(0, at);
        if (nul < 0) {
          throw const FormatException('index entry path is not NUL-terminated');
        }
        if (nameLength == 0x0fff) nameLength = nul - at;
        pathBytes = Uint8List.sublistView(bytes, at, at + nameLength);
        at += nameLength;

        // Entries are padded so each begins on an eight-byte boundary, with
        // between one and eight NULs — never zero, so the path is always
        // terminated.
        at = start + ((at - start + 8) & ~7);
      }
      previousPath = pathBytes;
      final path = utf8.decode(pathBytes, allowMalformed: true);

      entries.add(IndexEntry(
        path: path,
        id: id,
        mode: mode,
        ctimeSeconds: ctimeSeconds,
        ctimeNanoseconds: ctimeNanoseconds,
        mtimeSeconds: mtimeSeconds,
        mtimeNanoseconds: mtimeNanoseconds,
        device: device,
        inode: inode,
        uid: uid,
        gid: gid,
        size: size,
        stage: stage,
        assumeValid: assumeValid,
        intentToAdd: intentToAdd,
        skipWorktree: skipWorktree,
      ));
    }

    // Extensions follow the entries, each a four-character name, a 32-bit
    // length and that many bytes; the last 20 bytes of the file are its
    // checksum rather than an extension.
    final extensions = <String, Uint8List>{};
    while (at + 8 <= bytes.length - ObjectId.byteLength) {
      final name = ascii.decode(bytes.sublist(at, at + 4));
      final length = data.getUint32(at + 4);
      extensions[name] = Uint8List.fromList(
        bytes.sublist(at + 8, at + 8 + length),
      );
      at += 8 + length;
    }

    return GitIndex(
      version: version,
      entries: entries,
      extensions: extensions,
    );
  }

  /// Whether any entry carries a flag that only version 3 can express.
  bool get _needsVersion3 =>
      entries.any((entry) => entry.intentToAdd || entry.skipWorktree);

  /// Serialises as version 2, or version 3 when an entry needs it, dropping
  /// extensions.
  ///
  /// Extensions are caches git rebuilds, so dropping them is correct and slow
  /// — the same trade the stat fields offer. Writing them back is possible
  /// only for the ones this implementation understands, and writing a stale
  /// cached tree would be worse than writing none.
  ///
  /// The version is chosen rather than fixed because `intent-to-add` and
  /// `skip-worktree` live in an extended flags field that version 2 has no
  /// room for. Writing v2 regardless would parse cleanly and silently clear
  /// them — a file marked skip-worktree would come back under management the
  /// first time anything staged an unrelated path, which is the sort of loss
  /// nothing reports.
  Uint8List serialise() {
    final sorted = [...entries]..sort(_compare);
    final version = _needsVersion3 ? 3 : 2;
    final builder = BytesBuilder(copy: false);

    final header = ByteData(12)
      ..setUint32(0, _signature)
      ..setUint32(4, version)
      ..setUint32(8, sorted.length);
    builder.add(header.buffer.asUint8List());

    for (final entry in sorted) {
      final pathBytes = utf8.encode(entry.path);
      // An entry needs the extended field only if it has something to say in
      // it; a v3 index may hold plain entries alongside extended ones.
      final extended = entry.intentToAdd || entry.skipWorktree;
      final fixed = extended ? 64 : 62;
      final unpadded = fixed + pathBytes.length;
      final padded = (unpadded + 8) & ~7;
      final record = Uint8List(padded);
      final view = ByteData.sublistView(record);

      view.setUint32(0, entry.ctimeSeconds);
      view.setUint32(4, entry.ctimeNanoseconds);
      view.setUint32(8, entry.mtimeSeconds);
      view.setUint32(12, entry.mtimeNanoseconds);
      view.setUint32(16, entry.device);
      view.setUint32(20, entry.inode);
      view.setUint32(24, entry.mode);
      view.setUint32(28, entry.uid);
      view.setUint32(32, entry.gid);
      view.setUint32(36, entry.size);
      record.setRange(40, 60, entry.id.bytes);

      final nameLength =
          pathBytes.length < 0x0fff ? pathBytes.length : 0x0fff;
      var flags = nameLength | (entry.stage.value << 12);
      if (entry.assumeValid) flags |= 0x8000;
      if (extended) flags |= 0x4000;
      view.setUint16(60, flags);

      if (extended) {
        var extra = 0;
        if (entry.intentToAdd) extra |= 0x2000;
        if (entry.skipWorktree) extra |= 0x4000;
        view.setUint16(62, extra);
      }

      record.setRange(fixed, fixed + pathBytes.length, pathBytes);
      builder.add(record);
    }

    final body = builder.takeBytes();
    final checksum = sha1.convert(body).bytes;
    return Uint8List(body.length + ObjectId.byteLength)
      ..setRange(0, body.length, body)
      ..setRange(body.length, body.length + ObjectId.byteLength, checksum);
  }

  static const lockSuffix = '.lock';

  void writeTo(String path) {
    // The same lock-and-rename as a ref, for the same reason: a half-written
    // index is a lost staging area, and two writers renaming over each other
    // is a staging area that holds neither of their work.
    final file = fs.file(path);
    final lock = fs.file('$path$lockSuffix');
    try {
      lock.createSync(exclusive: true);
    } on GitFsException {
      throw IndexLockedException(path);
    }
    try {
      lock.writeAsBytesSync(serialise());
      lock.renameSync(file.path);
    } catch (_) {
      if (lock.existsSync()) lock.deleteSync();
      rethrow;
    }
  }

  static int _compare(IndexEntry a, IndexEntry b) {
    final byPath = a.path.compareTo(b.path);
    return byPath != 0 ? byPath : a.stage.value - b.stage.value;
  }

  IndexEntry? entryFor(String path,
          [MergeStage stage = MergeStage.ordinary]) =>
      entries
          .cast<IndexEntry?>()
          .firstWhere(
            (e) => e!.path == path && e.stage == stage,
            orElse: () => null,
          );

  bool get hasConflicts => entries.any((entry) => entry.isConflicted);

  /// Paths with more than one stage, each with the stages present.
  Map<String, List<IndexEntry>> get conflicts {
    final grouped = <String, List<IndexEntry>>{};
    for (final entry in entries.where((e) => e.isConflicted)) {
      grouped.putIfAbsent(entry.path, () => []).add(entry);
    }
    return grouped;
  }
}

/// Reads git's own variable-width integer, as `decode_varint` does.
///
/// Not the usual continuation encoding: each byte after the first adds one to
/// what has been read so far before shifting it, so every value has exactly
/// one spelling and no encoding is wasted on leading zeroes.
({int value, int after}) _decodeVarint(Uint8List bytes, int at) {
  var index = at;
  if (index >= bytes.length) {
    throw const FormatException('an index entry ends inside a path length');
  }
  var byte = bytes[index++];
  var value = byte & 0x7f;
  while (byte & 0x80 != 0) {
    if (index >= bytes.length) {
      throw const FormatException('an index entry ends inside a path length');
    }
    value += 1;
    byte = bytes[index++];
    value = (value << 7) + (byte & 0x7f);
  }
  return (value: value, after: index);
}
