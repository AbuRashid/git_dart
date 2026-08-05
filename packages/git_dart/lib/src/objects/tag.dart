import 'dart:convert';
import 'dart:typed_data';

import '../object_id.dart';
import 'commit.dart';
import 'git_object.dart';
import 'identity.dart';

/// An annotated pointer to any object.
///
/// The same header-then-message shape as a commit, with a different vocabulary:
/// `object`, `type`, `tag`, `tagger`.
class Tag extends GitObject {
  final ObjectId target;
  final ObjectKind targetKind;

  /// The tag's own name, as recorded inside the object. A lightweight tag has
  /// no tag object at all and so does not appear here.
  final String name;

  final Identity? tagger;
  final List<HeaderLine> extraHeaders;
  final Uint8List rawMessage;
  final Uint8List? _sourceContent;

  Tag({
    required this.target,
    required this.targetKind,
    required this.name,
    required this.tagger,
    required this.rawMessage,
    this.extraHeaders = const [],
  }) : _sourceContent = null;

  Tag._parsed({
    required this.target,
    required this.targetKind,
    required this.name,
    required this.tagger,
    required this.rawMessage,
    required this.extraHeaders,
    required Uint8List source,
  }) : _sourceContent = source;

  factory Tag.parse(Uint8List content) {
    final parsed = parseHeaders(content);
    ObjectId? target;
    ObjectKind? targetKind;
    String? name;
    Identity? tagger;
    final extra = <HeaderLine>[];

    for (final header in parsed.headers) {
      switch (header.name) {
        case 'object':
          target = ObjectId.fromHex(header.value);
        case 'type':
          targetKind = ObjectKind.byName(header.value);
        case 'tag':
          name = header.value;
        case 'tagger':
          tagger = Identity.parse(header.value);
        default:
          extra.add(header);
      }
    }

    if (target == null || targetKind == null) {
      throw const FormatException('tag has no object or type header');
    }

    return Tag._parsed(
      target: target,
      targetKind: targetKind,
      name: name ?? '',
      tagger: tagger,
      rawMessage: parsed.message,
      extraHeaders: extra,
      source: content,
    );
  }

  @override
  ObjectKind get kind => ObjectKind.tag;

  String get message => utf8.decode(rawMessage, allowMalformed: true);

  @override
  Uint8List get content {
    final source = _sourceContent;
    if (source != null) return source;
    final tagger = this.tagger;
    return writeHeaders([
      HeaderLine('object', target.hex),
      HeaderLine('type', targetKind.name),
      HeaderLine('tag', name),
      if (tagger != null) HeaderLine('tagger', tagger.toString()),
      ...extraHeaders,
    ], rawMessage);
  }

  @override
  String toString() => 'tag $name -> ${target.hex}';
}
