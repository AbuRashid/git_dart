/// Bundles — a fetch in a file.
///
/// A bundle is a list of refs and a packfile, in one file that can be copied
/// on a memory stick. It exists because the thing a clone actually transfers
/// is objects, and nothing about that requires a network: a repository behind
/// an air gap, or on a link too slow to clone over, can be brought up to date
/// by handing it a bundle.
///
/// What makes it more than a tarball of `.git` is the *prerequisite* list. A
/// bundle need not carry whole history; it can carry "everything since commit
/// X", which is a small file instead of a large one. The prerequisites are the
/// commits it assumes the receiver already has, named explicitly so that
/// unbundling into a repository that does not have them fails cleanly instead
/// of installing a pack whose objects point at nothing
/// (`objects.connectivity`).
///
/// The format is plain text up to a blank line, then a packfile:
///
/// ```
/// # v2 git bundle
/// -<oid> <subject>        the prerequisites, if any
/// <oid> refs/heads/main   the refs it carries
///                         a blank line
/// PACK…
/// ```
///
/// Version 3 adds `@key=value` capability lines before the rest. Both are read
/// here; version 2 is written, because nothing needed for a sha-1 repository
/// requires the newer one.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../fs/git_fs.dart';
import '../object_id.dart';
import '../objects/commit.dart';
import '../objects/git_object.dart';
import '../objects/tag.dart';
import '../objects/tree.dart';
import '../platform/host.dart';
import '../repository.dart';
import '../storage/pack_indexer.dart';
import '../storage/pack_parser.dart';
import '../storage/pack_writer.dart';
import 'package:path/path.dart' as p;

/// A commit the bundle expects the receiving repository to already have.
class BundlePrerequisite {
  final ObjectId id;

  /// The subject of the commit, written for a person reading the header. It
  /// is decoration: nothing depends on it and it may be empty.
  final String comment;

  const BundlePrerequisite(this.id, [this.comment = '']);

  @override
  String toString() => comment.isEmpty ? id.hex : '${id.hex} $comment';
}

/// Everything a bundle says about itself before the packfile begins.
class BundleHeader {
  /// 2 or 3.
  final int version;

  /// The `@key=value` lines, which only version 3 has.
  final Map<String, String> capabilities;

  final List<BundlePrerequisite> prerequisites;

  /// What the bundle carries, by ref path.
  final Map<String, ObjectId> refs;

  /// Where `PACK` begins.
  final int packOffset;

  const BundleHeader({
    required this.version,
    required this.capabilities,
    required this.prerequisites,
    required this.refs,
    required this.packOffset,
  });

  /// Whether it carries whole history, needing nothing already present.
  bool get isComplete => prerequisites.isEmpty;
}

class BundleFormatException implements Exception {
  final String message;
  const BundleFormatException(this.message);
  @override
  String toString() => 'BundleFormatException: $message';
}

/// What a bundle brought in.
class UnbundleResult {
  /// The refs it carried, by ref path.
  final Map<String, ObjectId> refs;

  /// How many objects its packfile held.
  final int objects;

  /// The refs actually written into the repository, when asked for.
  final Map<String, ObjectId> written;

  const UnbundleResult({
    required this.refs,
    required this.objects,
    this.written = const {},
  });
}

const String _v2Signature = '# v2 git bundle';
const String _v3Signature = '# v3 git bundle';

/// Reads a bundle's header without touching its packfile.
///
/// Cheap by design: deciding whether a bundle is any use — whether its
/// prerequisites are present, whether its refs are wanted — should not cost
/// unpacking it.
BundleHeader readBundleHeader(Uint8List bytes) {
  final newline = bytes.indexOf(0x0A);
  if (newline < 0) throw const BundleFormatException('not a bundle: no header');

  final signature = utf8.decode(bytes.sublist(0, newline), allowMalformed: true);
  final int version;
  if (signature == _v2Signature) {
    version = 2;
  } else if (signature == _v3Signature) {
    version = 3;
  } else {
    throw BundleFormatException('not a bundle: "$signature"');
  }

  final capabilities = <String, String>{};
  final prerequisites = <BundlePrerequisite>[];
  final refs = <String, ObjectId>{};

  var at = newline + 1;
  while (true) {
    final end = bytes.indexOf(0x0A, at);
    if (end < 0) {
      throw const BundleFormatException('the header is not terminated');
    }
    // A blank line ends the header; the packfile starts on the next byte.
    if (end == at) {
      at = end + 1;
      break;
    }

    final line = utf8.decode(bytes.sublist(at, end), allowMalformed: true);
    at = end + 1;

    if (line.startsWith('@')) {
      if (version < 3) {
        throw BundleFormatException(
          'a version $version bundle carries a capability line: $line',
        );
      }
      final equals = line.indexOf('=');
      if (equals < 0) {
        capabilities[line.substring(1)] = '';
      } else {
        capabilities[line.substring(1, equals)] = line.substring(equals + 1);
      }
      continue;
    }

    final prerequisite = line.startsWith('-');
    final body = prerequisite ? line.substring(1) : line;
    final space = body.indexOf(' ');
    // A prerequisite's comment is optional; a ref's name is not.
    final hex = space < 0 ? body : body.substring(0, space);
    final rest = space < 0 ? '' : body.substring(space + 1);

    final ObjectId id;
    try {
      id = ObjectId.fromHex(hex);
    } on FormatException {
      throw BundleFormatException('not an object name in the header: "$hex"');
    }

    if (prerequisite) {
      prerequisites.add(BundlePrerequisite(id, rest));
    } else {
      if (rest.isEmpty) {
        throw BundleFormatException('a ref line with no name: "$line"');
      }
      refs[rest] = id;
    }
  }

  return BundleHeader(
    version: version,
    capabilities: capabilities,
    prerequisites: prerequisites,
    refs: refs,
    packOffset: at,
  );
}

/// The prerequisites [repository] does not have.
///
/// Empty means the bundle can be unbundled here. This is the check that makes
/// a partial bundle safe: without it, a bundle built against history the
/// receiver lacks installs objects whose parents are missing, and the
/// repository is broken in a way nothing points at.
List<ObjectId> missingPrerequisites(
  Repository repository,
  BundleHeader header,
) =>
    [
      for (final prerequisite in header.prerequisites)
        if (!repository.objects.contains(prerequisite.id)) prerequisite.id,
    ];

/// Reads a bundle into [repository].
///
/// [writeRefs] writes the bundle's refs as it names them, which is what
/// cloning from a bundle wants. A caller fetching from one usually wants them
/// somewhere else and can write them itself from [UnbundleResult.refs].
///
/// Refuses when a prerequisite is absent, unless [verifyPrerequisites] is
/// off — an escape hatch for a caller that means to collect several bundles
/// before checking any of them.
UnbundleResult unbundle(
  Repository repository,
  Uint8List bytes, {
  bool writeRefs = false,
  bool verifyPrerequisites = true,
}) {
  final header = readBundleHeader(bytes);

  // A filtered bundle is missing objects on purpose, and installing one
  // without the promisor machinery that explains the absences would look
  // exactly like corruption.
  if (header.capabilities.containsKey('filter')) {
    throw const BundleFormatException(
      'this bundle was filtered, and a filtered bundle needs a promisor '
      'remote to explain what it left out',
    );
  }

  if (verifyPrerequisites) {
    final missing = missingPrerequisites(repository, header);
    if (missing.isNotEmpty) {
      throw BundleFormatException(
        'this bundle continues history this repository does not have: '
        '${missing.map((id) => id.hex.substring(0, 8)).join(', ')}',
      );
    }
  }

  final pack = Uint8List.sublistView(bytes, header.packOffset);
  final count = _installPack(repository, pack);

  final written = <String, ObjectId>{};
  if (writeRefs) {
    header.refs.forEach((ref, id) {
      // HEAD is a symbolic ref in every repository that has one, and writing
      // it as a direct name would detach the receiver's HEAD.
      if (ref == 'HEAD') return;
      repository.refs.write(ref, id, reflogMessage: 'unbundle');
      written[ref] = id;
    });
  }

  return UnbundleResult(refs: header.refs, objects: count, written: written);
}

/// Writes the pack half of a bundle into the repository's object store.
int _installPack(Repository repository, Uint8List pack) {
  if (pack.length < 12) return 0;

  final temporary = fs.file(p.join(
    repository.commonDirectory,
    'objects',
    'pack',
    'unbundle-$processId.pack',
  ))
    ..parent.createSync(recursive: true);

  temporary.writeAsBytesSync(pack, flush: true);
  try {
    final indexed = PackIndexer(temporary.path).run();
    if (indexed.count == 0) return 0;

    // A handful of objects are cheaper to read loose than through an index,
    // the same trade a small fetch makes.
    if (indexed.count <= 100) {
      final objects = PackParser(temporary.readAsBytesSync()).parse();
      objects.forEach((id, object) {
        repository.objects.write(GitObject.parse(object.kind, object.content));
      });
    } else {
      repository.objects.writePackFile(
        packPath: temporary.path,
        objects: indexed.objects,
        packChecksum: indexed.checksum,
      );
    }
    return indexed.count;
  } finally {
    if (temporary.existsSync()) temporary.deleteSync();
  }
}

/// Writes a bundle carrying [refs].
///
/// [refs] defaults to every branch and tag. [since] names history the receiver
/// is assumed to have: everything reachable from it is left out of the pack
/// and its boundary is recorded as the prerequisites, which is what turns a
/// whole-history bundle into an incremental one.
///
/// Throws when a ref would carry no history at all — a bundle whose every
/// commit was excluded is a file that can never be unbundled anywhere useful,
/// and producing one silently is worse than refusing.
Uint8List writeBundle(
  Repository repository, {
  Map<String, ObjectId>? refs,
  Iterable<ObjectId> since = const [],
  bool includeHead = false,
}) {
  final carried = refs ?? _allRefs(repository);
  if (carried.isEmpty) {
    throw StateError('there is nothing to bundle: no refs were named');
  }

  if (includeHead && !carried.containsKey('HEAD')) {
    final head = repository.headId;
    if (head != null) carried['HEAD'] = head;
  }

  // Everything reachable from the refs, less everything reachable from the
  // history the receiver is assumed to have.
  final excluded = _reachable(repository, since);
  final included = <ObjectId>{};
  final walk = <ObjectId>[
    for (final id in carried.values)
      if (repository.objects.contains(id)) id,
  ];
  while (walk.isNotEmpty) {
    final id = walk.removeLast();
    if (excluded.contains(id) || !included.add(id)) continue;
    final raw = repository.objects.readRaw(id);
    if (raw == null) continue;
    _children(GitObject.parse(raw.kind, raw.content), walk);
  }

  if (included.isEmpty) {
    throw StateError(
      'there is nothing to bundle: everything named is already covered by '
      'the history it was told to assume',
    );
  }

  // The boundary: a parent that was left out is a commit the receiver must
  // already have, and saying so is the whole of what makes a partial bundle
  // safe to hand over.
  final prerequisites = <ObjectId, String>{};
  for (final id in included) {
    final raw = repository.objects.readRaw(id);
    if (raw == null || raw.kind != ObjectKind.commit) continue;
    final commit = GitObject.parse(raw.kind, raw.content) as Commit;
    for (final parent in commit.parents) {
      if (included.contains(parent)) continue;
      prerequisites[parent] = _subjectOf(repository, parent);
    }
  }

  final writer = PackWriter();
  for (final id in included) {
    final raw = repository.objects.readRaw(id);
    if (raw == null) continue;
    writer.add(id, raw.kind, raw.content);
  }

  final header = StringBuffer()..writeln(_v2Signature);
  // Prerequisites first, sorted, so the same repository bundles to the same
  // bytes twice rather than to whatever order a hash table happened to have.
  for (final id in prerequisites.keys.toList()..sort()) {
    final comment = prerequisites[id]!;
    header.writeln(comment.isEmpty ? '-${id.hex}' : '-${id.hex} $comment');
  }
  for (final ref in carried.keys.toList()..sort()) {
    header.writeln('${carried[ref]!.hex} $ref');
  }
  header.writeln();

  return (BytesBuilder()
        ..add(utf8.encode(header.toString()))
        ..add(writer.build()))
      .takeBytes();
}

/// Every branch and tag, by ref path.
Map<String, ObjectId> _allRefs(Repository repository) {
  final out = <String, ObjectId>{};
  for (final ref in [...repository.refs.branches, ...repository.refs.tags]) {
    final id = repository.refs.resolve(ref.path);
    if (id != null) out[ref.path] = id;
  }
  return out;
}

/// The first line of a commit's message, for the header's benefit.
String _subjectOf(Repository repository, ObjectId id) {
  final raw = repository.objects.readRaw(id);
  if (raw == null || raw.kind != ObjectKind.commit) return '';
  final commit = GitObject.parse(raw.kind, raw.content) as Commit;
  return commit.message.split('\n').first.trim();
}

Set<ObjectId> _reachable(Repository repository, Iterable<ObjectId> from) {
  final seen = <ObjectId>{};
  final walk = <ObjectId>[
    for (final id in from)
      if (repository.objects.contains(id)) id,
  ];
  while (walk.isNotEmpty) {
    final id = walk.removeLast();
    if (!seen.add(id)) continue;
    final raw = repository.objects.readRaw(id);
    if (raw == null) continue;
    _children(GitObject.parse(raw.kind, raw.content), walk);
  }
  return seen;
}

void _children(GitObject object, List<ObjectId> out) {
  switch (object) {
    case Commit commit:
      out.add(commit.tree);
      out.addAll(commit.parents);
    case Tree tree:
      for (final entry in tree.entries) {
        // A gitlink names another repository's commit, which is not here and
        // must not be walked into.
        if (entry.mode.isSubmodule) continue;
        out.add(entry.id);
      }
    case Tag tag:
      out.add(tag.target);
    default:
      break;
  }
}
