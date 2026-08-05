import 'dart:convert';
import 'dart:typed_data';

import '../object_id.dart';
import 'git_object.dart';
import 'identity.dart';

/// One header line of a commit or tag: `name value`, with continuation lines
/// folded in. `gpgsig` is the reason values may be multi-line.
class HeaderLine {
  final String name;
  final String value;

  const HeaderLine(this.name, this.value);
}

/// A tree, its parents, and who and when (`objects.commit-format`).
class Commit extends GitObject {
  final ObjectId tree;

  /// Parents in order. The first is the branch merged into, so the order is
  /// meaningful and must be preserved.
  final List<ObjectId> parents;

  final Identity author;
  final Identity committer;

  /// Headers other than `tree`, `parent`, `author` and `committer`, in the
  /// order they appeared — `gpgsig`, `encoding`, `mergetag`.
  final List<HeaderLine> extraHeaders;

  final Uint8List rawMessage;

  /// The bytes this commit was parsed from, kept so that re-serialising an
  /// object read from a repository reproduces it exactly, whatever this
  /// implementation does or does not understand about its headers.
  final Uint8List? _sourceContent;

  Commit({
    required this.tree,
    required this.parents,
    required this.author,
    required this.committer,
    required this.rawMessage,
    this.extraHeaders = const [],
  }) : _sourceContent = null;

  Commit._parsed({
    required this.tree,
    required this.parents,
    required this.author,
    required this.committer,
    required this.rawMessage,
    required this.extraHeaders,
    required Uint8List source,
  }) : _sourceContent = source;

  factory Commit.build({
    required ObjectId tree,
    List<ObjectId> parents = const [],
    required Identity author,
    Identity? committer,
    required String message,
    List<HeaderLine> extraHeaders = const [],
  }) {
    return Commit(
      tree: tree,
      parents: parents,
      author: author,
      committer: committer ?? author,
      rawMessage: Uint8List.fromList(utf8.encode(message)),
      extraHeaders: extraHeaders,
    );
  }

  factory Commit.parse(Uint8List content) {
    final parsed = parseHeaders(content);
    ObjectId? tree;
    final parents = <ObjectId>[];
    Identity? author;
    Identity? committer;
    final extra = <HeaderLine>[];

    for (final header in parsed.headers) {
      switch (header.name) {
        case 'tree':
          tree = ObjectId.fromHex(header.value);
        case 'parent':
          parents.add(ObjectId.fromHex(header.value));
        case 'author':
          author = Identity.parse(header.value);
        case 'committer':
          committer = Identity.parse(header.value);
        default:
          extra.add(header);
      }
    }

    if (tree == null) throw const FormatException('commit has no tree header');
    if (author == null) {
      throw const FormatException('commit has no author header');
    }

    return Commit._parsed(
      tree: tree,
      parents: parents,
      author: author,
      committer: committer ?? author,
      rawMessage: parsed.message,
      extraHeaders: extra,
      source: content,
    );
  }

  @override
  ObjectKind get kind => ObjectKind.commit;

  String get message => utf8.decode(rawMessage, allowMalformed: true);

  /// The first line of the message, which is what a log listing shows.
  String get summary {
    final text = message;
    final end = text.indexOf('\n');
    return end < 0 ? text : text.substring(0, end);
  }

  @override
  Uint8List get content {
    final source = _sourceContent;
    if (source != null) return source;
    return writeHeaders([
      HeaderLine('tree', tree.hex),
      for (final parent in parents) HeaderLine('parent', parent.hex),
      HeaderLine('author', author.toString()),
      HeaderLine('committer', committer.toString()),
      ...extraHeaders,
    ], rawMessage);
  }

  @override
  String toString() => 'commit ${tree.hex} "$summary"';
}

/// Splits a commit or tag body into its header lines and its message.
({List<HeaderLine> headers, Uint8List message}) parseHeaders(
  Uint8List content,
) {
  final headers = <HeaderLine>[];
  var offset = 0;

  while (offset < content.length) {
    if (content[offset] == 0x0a) {
      // The blank line: everything after it is the message.
      offset += 1;
      break;
    }
    var end = content.indexOf(0x0a, offset);
    if (end < 0) end = content.length;

    final buffer = StringBuffer(
      utf8.decode(content.sublist(offset, end), allowMalformed: true),
    );
    offset = end + 1;

    // A line beginning with a space continues the header above it.
    while (offset < content.length && content[offset] == 0x20) {
      var next = content.indexOf(0x0a, offset);
      if (next < 0) next = content.length;
      buffer.write('\n');
      buffer.write(
        utf8.decode(content.sublist(offset + 1, next), allowMalformed: true),
      );
      offset = next + 1;
    }

    final line = buffer.toString();
    final space = line.indexOf(' ');
    if (space < 0) {
      headers.add(HeaderLine(line, ''));
    } else {
      headers.add(HeaderLine(line.substring(0, space), line.substring(space + 1)));
    }
  }

  return (
    headers: headers,
    message: Uint8List.fromList(content.sublist(offset)),
  );
}

Uint8List writeHeaders(List<HeaderLine> headers, Uint8List message) {
  final builder = BytesBuilder(copy: false);
  for (final header in headers) {
    final folded = header.value.replaceAll('\n', '\n ');
    builder.add(utf8.encode('${header.name} $folded\n'));
  }
  builder.addByte(0x0a);
  builder.add(message);
  return builder.takeBytes();
}
