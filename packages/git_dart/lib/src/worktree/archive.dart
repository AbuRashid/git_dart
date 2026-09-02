/// `git archive` — a tree, written out as a tar or zip file.
///
/// Exporting a commit is not the same as copying the working tree. What comes
/// out is exactly what the tree records, with none of the untracked files,
/// none of the ignored build output and no `.git` — which is what makes it
/// safe to hand to someone. The tree is the source of truth; the disk is not
/// consulted at all, so this works on a bare repository.
///
/// Every entry is stamped with the commit's own time rather than with now, so
/// archiving the same commit twice produces the same bytes. An archive that
/// changed every time it was built could not be checksummed, and checksumming
/// a release tarball is most of the point of making one.
///
/// `export-ignore` in `.gitattributes` drops paths from the result — the
/// mechanism a project uses to keep its CI config and its test fixtures out of
/// a release. The attributes are read from the tree being archived, not from
/// the working tree, for the same reason as everything else here.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Deflate, getCrc32;

import '../object_id.dart';
import '../objects/commit.dart';
import '../objects/tree.dart';
import '../repository.dart';
import 'attributes.dart';

enum ArchiveFormat { tar, zip }

/// One path in an archive.
class ArchiveEntry {
  /// The path as it will appear, including any prefix, with forward slashes.
  final String path;

  final FileMode mode;

  /// The blob, or the tree for a directory.
  final ObjectId id;

  /// The bytes. Empty for a directory; the link target for a symlink.
  final Uint8List content;

  const ArchiveEntry({
    required this.path,
    required this.mode,
    required this.id,
    required this.content,
  });

  bool get isDirectory => mode.isTree;
  bool get isSymlink => mode == FileMode.symlink;

  @override
  String toString() => '${mode.text} ${content.length} $path';
}

/// The entries [treeish] would be archived as, in the order git writes them.
///
/// Exposed because a caller may want to list an archive's contents, or write
/// it somewhere this does not know how to write to, without building the
/// whole thing in memory first.
List<ArchiveEntry> archiveEntries(
  Repository repository, {
  ObjectId? treeish,
  String prefix = '',
}) {
  final from = treeish ?? repository.headId;
  if (from == null) return const [];

  final tree = repository.treeOf(from);
  if (tree == null) return const [];

  // Attributes come out of the tree, so a bare repository archives the same
  // bytes as a checkout of the same commit.
  final attributes = Attributes();

  final root = _normalisePrefix(prefix);

  final out = <ArchiveEntry>[];
  // A prefix is a directory the archive creates, and git writes one entry for
  // the whole of it - `a/b/c/` is one entry, not three.
  if (root.isNotEmpty) {
    out.add(ArchiveEntry(
      path: root,
      mode: FileMode.directory,
      id: tree.id,
      content: Uint8List(0),
    ));
  }
  _collect(repository, tree, root, attributes, out);
  return out;
}

/// Writes [treeish] as an archive.
///
/// [mtime] overrides the timestamp on every entry; without it the commit's
/// own time is used, or the epoch when a bare tree was named and there is no
/// commit to take a time from.
Uint8List writeArchive(
  Repository repository, {
  ObjectId? treeish,
  ArchiveFormat format = ArchiveFormat.tar,
  String prefix = '',
  int? mtime,
  int compressionLevel = 6,
}) {
  final from = treeish ?? repository.headId;
  if (from == null) {
    throw StateError('nothing to archive: the repository has no commits');
  }

  final entries = archiveEntries(repository, treeish: from, prefix: prefix);
  final stamp = mtime ?? _timeOf(repository, from);

  return switch (format) {
    ArchiveFormat.tar => _writeTar(entries, stamp, _commitIdOf(repository, from)),
    ArchiveFormat.zip => _writeZip(entries, stamp, compressionLevel),
  };
}

/// A prefix as git wants it: empty, or ending in a slash.
String _normalisePrefix(String prefix) {
  if (prefix.isEmpty) return '';
  return prefix.endsWith('/') ? prefix : '$prefix/';
}

/// The commit's time, which is what every entry is stamped with.
int _timeOf(Repository repository, ObjectId id) {
  if (repository.objects.readRaw(id) == null) return 0;
  final object = repository.peel(id);
  return object is Commit ? object.committer.seconds : 0;
}

/// The commit being archived, recorded in the tar's global header so the
/// archive says which commit it came from. A tree named directly has none.
ObjectId? _commitIdOf(Repository repository, ObjectId id) {
  if (repository.objects.readRaw(id) == null) return null;
  final object = repository.peel(id);
  return object is Commit ? object.id : null;
}

/// Walks a tree, in tree order, emitting a directory before its contents.
void _collect(
  Repository repository,
  Tree tree,
  String prefix,
  Attributes attributes,
  List<ArchiveEntry> out,
) {
  // A directory's own `.gitattributes` applies to everything below it, so it
  // has to be read before any of it is decided about.
  final rules = tree.entryNamed('.gitattributes');
  if (rules != null && rules.mode.isBlob) {
    final raw = repository.objects.readRaw(rules.id);
    if (raw != null) {
      attributes.addText(
        utf8.decode(raw.content, allowMalformed: true),
        base: prefix.isEmpty
            ? ''
            : prefix.substring(0, prefix.length - 1),
      );
    }
  }

  for (final entry in tree.entries) {
    final path = '$prefix${entry.name}';

    // A gitlink is another repository's commit, and none of it is here to
    // write. git leaves an empty directory in its place.
    if (entry.mode.isSubmodule) continue;

    // A directory is tested under both spellings: a pattern written `ci/`
    // means the directory and only matches with the slash, while a pattern
    // written `docs` matches without one. Both are ordinary in a real
    // `.gitattributes`, and testing one spelling silently exports the tree
    // the project asked to keep out of the release.
    final ignored = attributes.forPath(path)['export-ignore'] == true ||
        (entry.mode.isTree &&
            attributes.forPath('$path/')['export-ignore'] == true);
    if (ignored) continue;

    if (entry.mode.isTree) {
      final subtree = repository.objects.readRaw(entry.id) == null
          ? null
          : repository.objects.readTyped<Tree>(entry.id);
      if (subtree == null) continue;

      out.add(ArchiveEntry(
        path: '$path/',
        mode: entry.mode,
        id: entry.id,
        content: Uint8List(0),
      ));
      _collect(repository, subtree, '$path/', attributes, out);
      continue;
    }

    final raw = repository.objects.readRaw(entry.id);
    if (raw == null) continue;
    out.add(ArchiveEntry(
      path: path,
      mode: entry.mode,
      id: entry.id,
      content: raw.content,
    ));
  }
}

// ---- tar -------------------------------------------------------------------

const int _blockSize = 512;

/// The tar writer.
///
/// Written out here rather than taken from a library because of the two
/// details a generic writer does not have: the pax global header naming the
/// commit, and the extended header a path longer than 100 bytes needs. Both
/// are what make the result the same archive git would have produced.
Uint8List _writeTar(
  List<ArchiveEntry> entries,
  int mtime,
  ObjectId? commit,
) {
  final out = BytesBuilder();

  // git records the commit in a pax *global* header, so an archive that has
  // been unpacked and forgotten about can still say where it came from.
  if (commit != null) {
    final record = _paxRecord('comment', commit.hex);
    out.add(_tarHeader(
      name: 'pax_global_header',
      mode: 0x1B6, // 0666
      size: record.length,
      mtime: mtime,
      typeFlag: 'g',
    ));
    out.add(_padded(record));
  }

  for (final entry in entries) {
    final name = entry.path;
    final content = entry.isSymlink || entry.isDirectory
        ? Uint8List(0)
        : entry.content;

    // ustar holds 100 bytes of name plus 155 more in a separate prefix field,
    // and a long path is split between them at a slash. Only a path that will
    // not split - one over 256 bytes, or with a single component over 100 -
    // needs a pax extended header, and git reaches for one just as rarely.
    final split = _splitName(name);
    if (split == null) {
      final record = _paxRecord('path', name);
      out.add(_tarHeader(
        name: _truncate(name),
        mode: 0x1B6, // 0666
        size: record.length,
        mtime: mtime,
        typeFlag: 'x',
      ));
      out.add(_padded(record));
    }

    final linkTarget = entry.isSymlink
        ? utf8.decode(entry.content, allowMalformed: true)
        : '';

    out.add(_tarHeader(
      name: split?.name ?? _truncate(name),
      namePrefix: split?.prefix ?? '',
      // git's own choices, which are group-writable rather than the 0644 and
      // 0755 a tree records: an exported tarball is meant to be unpacked and
      // worked on, not installed. Read off `git archive` rather than guessed.
      mode: switch (entry.mode) {
        FileMode.directory => 0x1FD, // 0775
        FileMode.executableFile => 0x1FD, // 0775
        FileMode.symlink => 0x1FF, // 0777
        _ => 0x1B4, // 0664
      },
      size: content.length,
      mtime: mtime,
      typeFlag: entry.isDirectory
          ? '5'
          : entry.isSymlink
              ? '2'
              : '0',
      linkName: linkTarget,
    ));
    if (content.isNotEmpty) out.add(_padded(content));
  }

  // Two zero blocks end the archive, and the whole is padded to the blocking
  // factor of 20 that every tar defaults to.
  out.add(Uint8List(_blockSize * 2));
  final written = out.length;
  final blocking = _blockSize * 20;
  final remainder = written % blocking;
  if (remainder != 0) out.add(Uint8List(blocking - remainder));

  return out.takeBytes();
}

/// One pax record: `<length> <key>=<value>\n`, where the length counts itself.
///
/// Self-describing, which means solving for a length that includes the digits
/// of the length — hence the loop rather than one calculation.
Uint8List _paxRecord(String key, String value) {
  final body = utf8.encode('$key=$value\n');
  var length = body.length + 3; // a one-digit length, plus a space
  while (utf8.encode('$length ').length + body.length != length) {
    length = utf8.encode('$length ').length + body.length;
  }
  return Uint8List.fromList(utf8.encode('$length ') + body);
}

/// Splits a path across ustar's 100-byte name and 155-byte prefix fields.
///
/// Returns null when it will not go: the two fields join at a slash, so a
/// single component longer than 100 bytes has nowhere to break. The last
/// usable slash is chosen, which puts as much as possible in the prefix and
/// is what every tar writer does.
({String name, String prefix})? _splitName(String path) {
  final bytes = utf8.encode(path);
  if (bytes.length <= 100) return (name: path, prefix: '');
  if (bytes.length > 256) return null;

  ({String name, String prefix})? best;
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] != 0x2F) continue; // '/'
    final headLength = i;
    final tailLength = bytes.length - i - 1;
    if (headLength == 0 || headLength > 155) continue;
    if (tailLength == 0 || tailLength > 100) continue;
    best = (
      name: utf8.decode(bytes.sublist(i + 1), allowMalformed: true),
      prefix: utf8.decode(bytes.sublist(0, i), allowMalformed: true),
    );
  }
  return best;
}

/// The first 100 bytes of a name, for the header of an entry whose real path
/// is carried in a pax record.
String _truncate(String name) {
  final bytes = utf8.encode(name);
  if (bytes.length <= 100) return name;
  return utf8.decode(bytes.sublist(0, 100), allowMalformed: true);
}

/// A ustar header block.
Uint8List _tarHeader({
  required String name,
  required int mode,
  required int size,
  required int mtime,
  required String typeFlag,
  String linkName = '',
  String namePrefix = '',
}) {
  final block = Uint8List(_blockSize);

  void put(int at, int limit, List<int> bytes) {
    for (var i = 0; i < bytes.length && i < limit; i++) {
      block[at + i] = bytes[i];
    }
  }

  /// An octal field: digits, then a NUL, right-aligned in [limit] bytes.
  void octal(int at, int limit, int value) {
    final text = value.toRadixString(8).padLeft(limit - 1, '0');
    put(at, limit, utf8.encode('$text\x00'));
  }

  put(0, 100, utf8.encode(name));
  octal(100, 8, mode);
  octal(108, 8, 0); // uid: git archives are owned by nobody in particular
  octal(116, 8, 0); // gid
  octal(124, 12, size);
  octal(136, 12, mtime);
  // The checksum is computed with its own field full of spaces, then written
  // into it — the one field that cannot include itself.
  put(148, 8, utf8.encode('        '));
  put(156, 1, utf8.encode(typeFlag));
  put(157, 100, utf8.encode(linkName));
  put(257, 6, utf8.encode('ustar'));
  put(263, 2, utf8.encode('00'));
  // Written as octal zeros rather than left NUL: they are numeric fields,
  // and an empty one changes the checksum every reader verifies.
  octal(329, 8, 0); // devmajor
  octal(337, 8, 0); // devminor
  put(345, 155, utf8.encode(namePrefix));
  // git names an owner so that unpacking as root does not produce files owned
  // by whoever happened to build the archive.
  put(265, 32, utf8.encode('root'));
  put(297, 32, utf8.encode('root'));

  var sum = 0;
  for (final byte in block) {
    sum += byte;
  }
  // Seven octal digits and a NUL - the same shape as every other numeric
  // field here, and the form git writes.
  octal(148, 8, sum);

  return block;
}

/// Content padded up to a whole number of blocks.
Uint8List _padded(List<int> content) {
  final remainder = content.length % _blockSize;
  if (remainder == 0) return Uint8List.fromList(content);
  final out = Uint8List(content.length + (_blockSize - remainder));
  out.setRange(0, content.length, content);
  return out;
}

// ---- zip -------------------------------------------------------------------

Uint8List _writeZip(
  List<ArchiveEntry> entries,
  int mtime,
  int compressionLevel,
) {
  // Zip records permissions in the top half of the external attributes, but
  // only makes sense of them when the entry says it came from a Unix system.
  // git sets both together and only where it matters - an executable and a
  // symlink - and leaves an ordinary file at zero, so an archive unpacked on
  // Windows gets that platform's defaults instead of somebody else's umask.
  // A directory is marked with the MS-DOS directory bit, which is the one
  // attribute every unpacker reads.
  const int madeByUnix = 3;
  const int madeByDos = 0;
  const int dosDirectory = 0x10;
  const int executableMode = 0x81ED; // 0100755
  const int symlinkMode = 0xA1FF; // 0120777

  final local = BytesBuilder();
  final central = BytesBuilder();
  var count = 0;

  final dosTime = _dosTime(mtime);

  for (final entry in entries) {
    final name = utf8.encode(entry.path);
    final content = entry.isDirectory ? Uint8List(0) : entry.content;

    final int madeBy;
    final int externalAttributes;
    if (entry.isDirectory) {
      madeBy = madeByDos;
      externalAttributes = dosDirectory;
    } else if (entry.isSymlink) {
      madeBy = madeByUnix;
      externalAttributes = symlinkMode << 16;
    } else if (entry.mode == FileMode.executableFile) {
      madeBy = madeByUnix;
      externalAttributes = executableMode << 16;
    } else {
      madeBy = madeByDos;
      externalAttributes = 0;
    }

    // Deflated unless that would make it bigger, which for very short files
    // it does: the compressed form carries a header the content cannot pay
    // for. Storing those is what git does and what every zip writer does.
    List<int> stored = content;
    var method = 0;
    if (content.isNotEmpty && compressionLevel > 0) {
      final deflated = Deflate(content, level: compressionLevel).getBytes();
      if (deflated.length < content.length) {
        stored = deflated;
        method = 8;
      }
    }

    final crc = content.isEmpty ? 0 : getCrc32(content);
    final offset = local.length;

    local.add(_zipLocalHeader(
      name: name,
      method: method,
      dosTime: dosTime,
      crc: crc,
      compressedSize: stored.length,
      size: content.length,
    ));
    local.add(stored);

    central.add(_zipCentralEntry(
      name: name,
      method: method,
      dosTime: dosTime,
      crc: crc,
      compressedSize: stored.length,
      size: content.length,
      offset: offset,
      madeBy: madeBy,
      externalAttributes: externalAttributes,
    ));
    count += 1;
  }

  final out = BytesBuilder();
  final centralOffset = local.length;
  out.add(local.takeBytes());
  final directory = central.takeBytes();
  out.add(directory);

  // End of central directory: the only fixed point in the file, which is why
  // a reader finds it by searching backwards from the end.
  final end = ByteData(22);
  end.setUint32(0, 0x06054B50, Endian.little);
  end.setUint16(4, 0, Endian.little); // this disk
  end.setUint16(6, 0, Endian.little); // the disk the directory starts on
  end.setUint16(8, count, Endian.little);
  end.setUint16(10, count, Endian.little);
  end.setUint32(12, directory.length, Endian.little);
  end.setUint32(16, centralOffset, Endian.little);
  end.setUint16(20, 0, Endian.little); // no comment
  out.add(end.buffer.asUint8List());

  return out.takeBytes();
}

/// A zip local file header, immediately followed by the content.
Uint8List _zipLocalHeader({
  required List<int> name,
  required int method,
  required int dosTime,
  required int crc,
  required int compressedSize,
  required int size,
}) {
  final header = ByteData(30);
  header.setUint32(0, 0x04034B50, Endian.little);
  header.setUint16(4, 20, Endian.little); // the version needed to extract
  header.setUint16(6, 0, Endian.little); // no flags: sizes are known up front
  header.setUint16(8, method, Endian.little);
  header.setUint32(10, dosTime, Endian.little);
  header.setUint32(14, crc, Endian.little);
  header.setUint32(18, compressedSize, Endian.little);
  header.setUint32(22, size, Endian.little);
  header.setUint16(26, name.length, Endian.little);
  header.setUint16(28, 0, Endian.little); // no extra field

  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(name))
      .takeBytes();
}

/// One entry in the central directory, which is what a reader actually reads.
Uint8List _zipCentralEntry({
  required List<int> name,
  required int method,
  required int dosTime,
  required int crc,
  required int compressedSize,
  required int size,
  required int offset,
  required int madeBy,
  required int externalAttributes,
}) {
  final header = ByteData(46);
  header.setUint32(0, 0x02014B50, Endian.little);
  // The high byte says which system wrote it, and so how to read the
  // attributes; the low byte is the zip version.
  header.setUint16(4, (madeBy << 8) | 20, Endian.little);
  header.setUint16(6, 20, Endian.little);
  header.setUint16(8, 0, Endian.little);
  header.setUint16(10, method, Endian.little);
  header.setUint32(12, dosTime, Endian.little);
  header.setUint32(16, crc, Endian.little);
  header.setUint32(20, compressedSize, Endian.little);
  header.setUint32(24, size, Endian.little);
  header.setUint16(28, name.length, Endian.little);
  header.setUint16(30, 0, Endian.little); // no extra field
  header.setUint16(32, 0, Endian.little); // no comment
  header.setUint16(34, 0, Endian.little); // disk number
  header.setUint16(36, 0, Endian.little); // internal attributes
  header.setUint32(38, externalAttributes, Endian.little);
  header.setUint32(42, offset, Endian.little);

  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(name))
      .takeBytes();
}

/// Seconds since the epoch as the MS-DOS date and time zip records.
///
/// Local time by definition, with no zone anywhere in the format, and a
/// two-second resolution because the seconds field holds half-seconds. Dates
/// begin in 1980, so anything earlier is clamped rather than written as a
/// negative year that no reader would accept.
int _dosTime(int seconds) {
  final at = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  if (at.year < 1980) return (1 << 21) | (1 << 16);
  final date = ((at.year - 1980) << 9) | (at.month << 5) | at.day;
  final time = (at.hour << 11) | (at.minute << 5) | (at.second ~/ 2);
  return (date << 16) | time;
}
