import 'dart:convert';
import 'dart:typed_data';

import '../object_id.dart';
import 'pkt_line.dart';

/// Protocol version 2: what a server can do, and how to ask.
///
/// Version 0 grew capabilities onto the ref advertisement, so a client
/// received every ref before it could say anything at all. On a repository
/// with a hundred thousand refs that is megabytes of names sent before the
/// conversation starts, every time, whatever the client wanted.
///
/// Version 2 turns it around: the server advertises what commands it supports,
/// and the client asks for exactly the refs it cares about. Everything below
/// the command layer — pkt-lines, wants and haves, the packfile — is
/// unchanged, which is why a client can speak both with one implementation of
/// the parts that matter (`transfer.two-protocols`).
class V2Capabilities {
  /// Command name to its argument string, which is empty for most.
  final Map<String, String> commands;

  const V2Capabilities(this.commands);

  bool get isEmpty => commands.isEmpty;
  bool has(String name) => commands.containsKey(name);

  /// Whether the server offers both commands a fetch needs.
  bool get supportsFetch => has('ls-refs') && has('fetch');

  /// Whether `ls-refs` will report which ref `HEAD` points at.
  ///
  /// A clone needs this and version 0 has no way to ask: there, the default
  /// branch is guessed from which ref shares HEAD's object name, which is
  /// wrong whenever two branches point at the same commit.
  bool get canReportSymrefs => has('ls-refs');

  /// Whether the server will accept `have` lines and answer with
  /// acknowledgements rather than simply sending everything.
  bool get canNegotiate {
    final fetch = commands['fetch'];
    return fetch != null && !fetch.contains('no-negotiate');
  }

  @override
  String toString() => commands.keys.join(', ');
}

/// Reads the capability advertisement a version 2 server opens with.
///
/// Returns an empty set when the response is a version 0 advertisement
/// instead — which is what a server that does not know version 2 sends, and is
/// the signal to fall back rather than an error.
V2Capabilities readV2Capabilities(Uint8List bytes) {
  final reader = PktLineReader(bytes);
  final commands = <String, String>{};
  var sawVersion = false;

  while (true) {
    final packet = reader.next();
    if (packet == null) break;

    if (packet.kind != PktKind.data) {
      // Smart HTTP opens with `# service=git-upload-pack` and a flush before
      // anything either version has to say. Stopping at that flush finds no
      // version line and reports version 0 for a version 2 server — which
      // then fails a line later, parsing `version 2` as an object name.
      if (sawVersion) break;
      continue;
    }

    final line = packet.text.trim();
    if (line.isEmpty) continue;
    // The service banner; version 0 puts a ref in this position instead.
    if (line.startsWith('#')) continue;

    if (!sawVersion) {
      if (line != 'version 2') return const V2Capabilities({});
      sawVersion = true;
      continue;
    }

    final equals = line.indexOf('=');
    if (equals < 0) {
      commands[line] = '';
    } else {
      commands[line.substring(0, equals)] = line.substring(equals + 1);
    }
  }

  return sawVersion ? V2Capabilities(commands) : const V2Capabilities({});
}

/// The `ls-refs` request.
///
/// [prefixes] is what makes version 2 worth having: the server filters, so a
/// client that only wants branches never hears about a hundred thousand tags.
Uint8List lsRefsRequest({
  List<String> prefixes = const ['refs/heads/', 'refs/tags/'],
  bool peel = true,
  bool symrefs = true,
  String agent = 'git/git_dart-0.1',
}) {
  final body = BytesBuilder()
    ..add(PktLine.text('command=ls-refs\n').encode())
    ..add(PktLine.text('agent=$agent\n').encode())
    ..add(PktLine.delimiter.encode());

  if (peel) body.add(PktLine.text('peel\n').encode());
  if (symrefs) body.add(PktLine.text('symrefs\n').encode());
  for (final prefix in prefixes) {
    body.add(PktLine.text('ref-prefix $prefix\n').encode());
  }
  body.add(PktLine.flush.encode());
  return body.takeBytes();
}

/// What `ls-refs` answered.
class V2Refs {
  final Map<String, ObjectId> refs;

  /// What a symbolic ref points at — `HEAD` to `refs/heads/main`.
  final Map<String, String> symrefs;

  /// For an annotated tag, the commit it ultimately names.
  final Map<String, ObjectId> peeled;

  const V2Refs({
    required this.refs,
    this.symrefs = const {},
    this.peeled = const {},
  });

  /// The branch `HEAD` names, when the server said.
  String? get defaultBranch => symrefs['HEAD'];
}

/// Reads `<oid> <ref>[ symref-target:<ref>][ peeled:<oid>]` lines.
V2Refs parseLsRefs(Uint8List bytes) {
  final reader = PktLineReader(bytes);
  final refs = <String, ObjectId>{};
  final symrefs = <String, String>{};
  final peeled = <String, ObjectId>{};

  while (true) {
    final packet = reader.next();
    if (packet == null) break;
    if (packet.kind != PktKind.data) continue;

    final line = packet.text.trim();
    if (line.isEmpty) continue;

    final parts = line.split(' ');
    if (parts.length < 2 || parts[0].length != ObjectId.hexLength) continue;

    final id = ObjectId.fromHex(parts[0]);
    final path = parts[1];
    refs[path] = id;

    for (final attribute in parts.skip(2)) {
      if (attribute.startsWith('symref-target:')) {
        symrefs[path] = attribute.substring('symref-target:'.length);
      } else if (attribute.startsWith('peeled:')) {
        peeled[path] =
            ObjectId.fromHex(attribute.substring('peeled:'.length));
      }
    }
  }

  return V2Refs(refs: refs, symrefs: symrefs, peeled: peeled);
}

/// The `fetch` request.
///
/// [done] ends the negotiation and asks for the pack. Leaving it false asks
/// the server what it recognises so far, which is what a round of negotiation
/// is.
Uint8List fetchRequest({
  required List<ObjectId> wants,
  required List<ObjectId> haves,
  required bool done,
  bool ofsDelta = true,
  bool includeTag = true,
  String agent = 'git/git_dart-0.1',
}) {
  final body = BytesBuilder()
    ..add(PktLine.text('command=fetch\n').encode())
    ..add(PktLine.text('agent=$agent\n').encode())
    ..add(PktLine.delimiter.encode());

  if (ofsDelta) body.add(PktLine.text('ofs-delta\n').encode());
  if (includeTag) body.add(PktLine.text('include-tag\n').encode());

  // `sideband-all` is deliberately not asked for. It wraps the *whole*
  // response, section headers included, so a reader must de-multiplex before
  // it can tell which section it is in. Without it only the packfile section
  // is banded, which is the shape the reader here wants and costs nothing.
  //
  // `thin-pack` is deliberately not asked for either. A thin pack contains
  // deltas against objects it does not carry, on the understanding that the
  // receiver already has them and will fix the pack up before storing it.
  // Storing one as it arrives produces a pack whose bases are missing — which
  // the indexer refuses, correctly and unhelpfully. Asking for a complete
  // pack costs bandwidth and cannot be got subtly wrong.

  for (final want in wants) {
    body.add(PktLine.text('want ${want.hex}\n').encode());
  }
  for (final have in haves) {
    body.add(PktLine.text('have ${have.hex}\n').encode());
  }
  if (done) body.add(PktLine.text('done\n').encode());

  body.add(PktLine.flush.encode());
  return body.takeBytes();
}

/// The sections a version 2 `fetch` response is divided into.
///
/// Named sections rather than a fixed order is the other half of what version
/// 2 changed: a response can carry acknowledgements, or a pack, or both, and
/// the client is told which it is looking at instead of inferring it from
/// position.
enum V2Section {
  acknowledgments,
  shallowInfo,
  wantedRefs,
  packfileUris,
  packfile,
  unknown,
}

V2Section sectionNamed(String line) => switch (line.trim()) {
      'acknowledgments' => V2Section.acknowledgments,
      'shallow-info' => V2Section.shallowInfo,
      'wanted-refs' => V2Section.wantedRefs,
      'packfile-uris' => V2Section.packfileUris,
      'packfile' => V2Section.packfile,
      _ => V2Section.unknown,
    };

/// The `Git-Protocol` header that asks a smart-HTTP server for version 2.
///
/// A server that does not know it ignores it and answers in version 0, which
/// is why asking costs nothing and why the reply has to be examined rather
/// than assumed.
const gitProtocolHeader = 'Git-Protocol';
const gitProtocolVersion2 = 'version=2';

/// The same request, for a transport that runs a command rather than sending
/// a header: ssh and the daemon carry it in the environment.
const gitProtocolEnvironment = 'GIT_PROTOCOL';

String describeV2(V2Capabilities capabilities) =>
    capabilities.isEmpty ? 'version 0' : 'version 2 (${capabilities})';

/// Decodes the text of a data packet, tolerating a server that sends bytes
/// which are not valid UTF-8 in a progress line.
String packetText(PktLine packet) =>
    utf8.decode(packet.payload, allowMalformed: true);
