import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../object_id.dart';
import 'commit.dart';
import 'tag.dart';
import 'tree.dart';

/// The four object kinds of `objects.kinds`.
enum ObjectKind {
  blob('blob'),
  tree('tree'),
  commit('commit'),
  tag('tag');

  const ObjectKind(this.name);

  /// The kind's name as it appears in the object header and on the wire.
  final String name;

  static ObjectKind byName(String name) {
    for (final kind in ObjectKind.values) {
      if (kind.name == name) return kind;
    }
    throw FormatException('unknown object kind "$name"');
  }
}

/// An object's kind and content, without its header.
///
/// Every object is addressed by the SHA-1 of `kind SP length NUL content` —
/// the header is hashed, and over the *uncompressed* bytes, so an object's
/// name does not depend on how it is stored.
abstract class GitObject {
  ObjectKind get kind;

  /// The serialised content, excluding the header.
  Uint8List get content;

  ObjectId get id => hashObject(kind, content);

  /// The full serialised form: header, then content.
  Uint8List serialise() => _framed(kind, content);

  /// Parses [content] according to [kind]. The content must already have had
  /// its header removed.
  static GitObject parse(ObjectKind kind, Uint8List content) {
    switch (kind) {
      case ObjectKind.blob:
        return Blob(content);
      case ObjectKind.tree:
        return Tree.parse(content);
      case ObjectKind.commit:
        return Commit.parse(content);
      case ObjectKind.tag:
        return Tag.parse(content);
    }
  }

  /// Splits a serialised object into its kind and content.
  static ({ObjectKind kind, Uint8List content}) split(Uint8List serialised) {
    final nul = serialised.indexOf(0);
    if (nul < 0) {
      throw const FormatException('object header has no NUL terminator');
    }
    final header = ascii.decode(serialised.sublist(0, nul));
    final space = header.indexOf(' ');
    if (space < 0) {
      throw FormatException('malformed object header "$header"');
    }
    final kind = ObjectKind.byName(header.substring(0, space));
    final declared = int.tryParse(header.substring(space + 1));
    if (declared == null) {
      throw FormatException('malformed length in object header "$header"');
    }
    final content = Uint8List.sublistView(serialised, nul + 1);
    if (content.length != declared) {
      throw FormatException(
        'object header declares $declared bytes, found ${content.length}',
      );
    }
    return (kind: kind, content: content);
  }
}

/// Reads `<kind> <size>\0` from the front of a stored object.
///
/// [prefix] need only hold the header: the content may be absent, cut short,
/// or all there. Null when the header itself is not complete in what was
/// given, which is how a caller asks for "enough to know" and finds out
/// whether it got it.
({ObjectKind kind, int size})? parseObjectHeader(Uint8List prefix) {
  final nul = prefix.indexOf(0);
  if (nul < 0) return null;
  final header = ascii.decode(prefix.sublist(0, nul));
  final space = header.indexOf(' ');
  if (space < 0) {
    throw FormatException('malformed object header "$header"');
  }
  final size = int.tryParse(header.substring(space + 1));
  if (size == null) {
    throw FormatException('malformed length in object header "$header"');
  }
  return (kind: ObjectKind.byName(header.substring(0, space)), size: size);
}

Uint8List _framed(ObjectKind kind, Uint8List content) {
  final header = ascii.encode('${kind.name} ${content.length}\x00');
  final out = Uint8List(header.length + content.length)
    ..setRange(0, header.length, header)
    ..setRange(header.length, header.length + content.length, content);
  return out;
}

/// The name of an object with this kind and content.
///
/// `vectors.the-header-is-hashed`: the empty blob is the hash of `blob 0` NUL,
/// not of the empty string.
ObjectId hashObject(ObjectKind kind, Uint8List content) {
  final digest = sha1.convert(_framed(kind, content));
  return ObjectId(Uint8List.fromList(digest.bytes));
}

/// File contents, uninterpreted.
class Blob extends GitObject {
  @override
  final Uint8List content;

  Blob(this.content);

  Blob.fromString(String text) : content = Uint8List.fromList(utf8.encode(text));

  @override
  ObjectKind get kind => ObjectKind.blob;

  String get text => utf8.decode(content, allowMalformed: true);
}
