import 'dart:convert';
import 'dart:typed_data';

import '../object_id.dart';
import 'git_object.dart';

/// The mode of a tree entry, as it appears in the serialised form: ASCII
/// octal with no leading zero (`objects.modes-in-a-tree`).
class FileMode {
  static const regularFile = FileMode._('100644');
  static const executableFile = FileMode._('100755');
  static const symlink = FileMode._('120000');
  static const directory = FileMode._('40000');
  static const submodule = FileMode._('160000');

  /// The mode as written in a tree entry — `40000`, not `040000`.
  final String text;

  const FileMode._(this.text);

  /// Accepts any mode git might have written, including the `040000` form
  /// that appears in documentation but never in a serialised tree.
  factory FileMode.parse(String text) {
    switch (text) {
      case '100644':
      case '100664':
        return regularFile;
      case '100755':
        return executableFile;
      case '120000':
        return symlink;
      case '40000':
      case '040000':
        return directory;
      case '160000':
        return submodule;
      default:
        throw FormatException('unknown tree entry mode "$text"');
    }
  }

  bool get isTree => this == directory;
  bool get isSubmodule => this == submodule;
  bool get isBlob => this == regularFile || this == executableFile;

  /// The mode as the 32-bit value the index stores it in.
  int get numeric => int.parse(text, radix: 8);

  @override
  String toString() => text;
}

class TreeEntry {
  final FileMode mode;

  /// The name as stored: raw bytes, because git does not require a path to be
  /// valid UTF-8 and re-encoding a repaired name would change the tree's hash.
  final Uint8List rawName;

  final ObjectId id;

  TreeEntry({required this.mode, required this.rawName, required this.id});

  TreeEntry.named({
    required this.mode,
    required String name,
    required this.id,
  }) : rawName = Uint8List.fromList(utf8.encode(name));

  String get name => utf8.decode(rawName, allowMalformed: true);

  /// The sort key of `objects.tree-ordering`: a directory sorts as though its
  /// name ended in a slash.
  Uint8List get _sortKey {
    if (!mode.isTree) return rawName;
    return Uint8List(rawName.length + 1)
      ..setRange(0, rawName.length, rawName)
      ..[rawName.length] = 0x2f; // '/'
  }

  @override
  String toString() => '$mode ${mode.isTree ? 'tree' : 'blob'} $id\t$name';
}

/// One directory listing.
class Tree extends GitObject {
  /// Entries in serialised order — sorted, as [Tree.build] guarantees and as
  /// git writes them.
  final List<TreeEntry> entries;

  Tree(this.entries);

  /// Sorts [entries] into git's order. Use this rather than the constructor
  /// when building a tree, or it will hash differently from git's while
  /// containing the same files.
  factory Tree.build(Iterable<TreeEntry> entries) {
    final sorted = entries.toList()..sort(_compareEntries);
    return Tree(sorted);
  }

  static int _compareEntries(TreeEntry a, TreeEntry b) {
    final x = a._sortKey;
    final y = b._sortKey;
    final n = x.length < y.length ? x.length : y.length;
    for (var i = 0; i < n; i++) {
      final d = x[i] - y[i];
      if (d != 0) return d;
    }
    return x.length - y.length;
  }

  factory Tree.parse(Uint8List content) {
    final entries = <TreeEntry>[];
    var offset = 0;
    while (offset < content.length) {
      final space = content.indexOf(0x20, offset);
      if (space < 0) {
        throw const FormatException('tree entry has no space after its mode');
      }
      final mode = FileMode.parse(ascii.decode(content.sublist(offset, space)));
      final nul = content.indexOf(0, space + 1);
      if (nul < 0) {
        throw const FormatException('tree entry name is not NUL-terminated');
      }
      final rawName = Uint8List.fromList(content.sublist(space + 1, nul));
      if (nul + 1 + ObjectId.byteLength > content.length) {
        throw const FormatException('tree entry is truncated before its name');
      }
      entries.add(TreeEntry(
        mode: mode,
        rawName: rawName,
        id: ObjectId.fromBytes(content, nul + 1),
      ));
      offset = nul + 1 + ObjectId.byteLength;
    }
    return Tree(entries);
  }

  @override
  ObjectKind get kind => ObjectKind.tree;

  @override
  Uint8List get content {
    final builder = BytesBuilder(copy: false);
    for (final entry in entries) {
      builder.add(ascii.encode('${entry.mode.text} '));
      builder.add(entry.rawName);
      builder.addByte(0);
      builder.add(entry.id.bytes);
    }
    return builder.takeBytes();
  }

  TreeEntry? entryNamed(String name) {
    for (final entry in entries) {
      if (entry.name == name) return entry;
    }
    return null;
  }
}
