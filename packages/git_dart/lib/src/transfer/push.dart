import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../object_id.dart';
import '../objects/commit.dart';
import '../objects/git_object.dart';
import '../objects/tag.dart';
import '../objects/tree.dart';
import '../remote/remote.dart';
import '../repository.dart';
import '../storage/pack_writer.dart';
import 'credentials.dart';
import 'pkt_line.dart';

/// What happened to one ref.
class PushStatus {
  /// The ref on the remote, such as `refs/heads/main`.
  final String ref;

  final ObjectId? from;
  final ObjectId to;

  /// Null when it went through; the server's reason otherwise.
  final String? rejected;

  final bool forced;

  const PushStatus({
    required this.ref,
    required this.to,
    this.from,
    this.rejected,
    this.forced = false,
  });

  bool get ok => rejected == null;

  @override
  String toString() {
    final range = from == null
        ? '[new] ${to.hex.substring(0, 8)}'
        : '${from!.hex.substring(0, 8)}..${to.hex.substring(0, 8)}';
    return ok ? '$ref $range${forced ? ' (forced)' : ''}' : '$ref rejected: $rejected';
  }
}

class PushResult {
  final List<PushStatus> statuses;
  final int objectsSent;

  const PushResult({required this.statuses, this.objectsSent = 0});

  bool get ok => statuses.every((s) => s.ok);
  List<PushStatus> get rejected => [for (final s in statuses) if (!s.ok) s];
  bool get isEmpty => statuses.isEmpty;
}

/// Sends [branches] to [remote]. Defaults to the current branch.
///
/// A push is refused when it would not be a fast-forward — the remote holds
/// commits the new tip does not contain — unless [force]. That check is the
/// whole of what stands between pushing and losing someone else's work, so it
/// happens here as well as on the server, which may not be configured to make
/// it.
Future<PushResult> push(
  Repository repository,
  Remote remote, {
  List<String>? branches,
  bool force = false,
  Credentials? credentials,
  void Function(String message)? onProgress,
}) async {
  final names = branches ??
      [
        if (repository.refs.currentBranch case final current?)
          current.replaceFirst('refs/heads/', ''),
      ];
  if (names.isEmpty) {
    throw StateError('there is no branch to push');
  }

  final wanted = <String, ObjectId>{};
  for (final name in names) {
    final id = repository.refs.resolve('refs/heads/$name');
    if (id == null) throw StateError('no branch named $name');
    wanted['refs/heads/$name'] = id;
  }

  if (remote.isLocal) {
    return _pushLocal(repository, remote, wanted, force, onProgress);
  }
  if (remote.url.startsWith('http://') || remote.url.startsWith('https://')) {
    return _pushHttp(repository, remote, wanted, force, credentials, onProgress);
  }
  throw UnsupportedError(
    'this build can push to a local path or over http(s); '
    '${remote.url} is neither',
  );
}

/// Every object reachable from [tips] that is not reachable from [have].
///
/// This is what a push has to send: the difference, not the history.
Set<ObjectId> _objectsToSend(
  Repository repository,
  Iterable<ObjectId> tips,
  Iterable<ObjectId> have,
) {
  final stop = <ObjectId>{};
  final pending = <ObjectId>[
    for (final id in have)
      if (repository.objects.contains(id)) id,
  ];

  while (pending.isNotEmpty) {
    final id = pending.removeLast();
    if (!stop.add(id)) continue;
    final raw = repository.objects.readRaw(id);
    if (raw == null) continue;
    _children(GitObject.parse(raw.kind, raw.content), pending);
  }

  final send = <ObjectId>{};
  final walk = <ObjectId>[...tips];
  while (walk.isNotEmpty) {
    final id = walk.removeLast();
    if (stop.contains(id) || !send.add(id)) continue;
    final raw = repository.objects.readRaw(id);
    if (raw == null) continue;
    _children(GitObject.parse(raw.kind, raw.content), walk);
  }

  return send;
}

void _children(GitObject object, List<ObjectId> out) {
  switch (object) {
    case Commit commit:
      out
        ..add(commit.tree)
        ..addAll(commit.parents);
    case Tree tree:
      for (final entry in tree.entries) {
        if (!entry.mode.isSubmodule) out.add(entry.id);
      }
    case Tag tag:
      out.add(tag.target);
    case Blob():
      break;
  }
}

/// True when [ours] contains [theirs] — the condition for a fast-forward.
bool _contains(Repository repository, ObjectId ours, ObjectId theirs) {
  final seen = <ObjectId>{};
  final pending = <ObjectId>[ours];
  while (pending.isNotEmpty) {
    final id = pending.removeLast();
    if (id == theirs) return true;
    if (!seen.add(id)) continue;
    final raw = repository.objects.readRaw(id);
    if (raw == null) continue;
    final object = GitObject.parse(raw.kind, raw.content);
    if (object is Commit) pending.addAll(object.parents);
  }
  return false;
}

// ---------------------------------------------------------------------------
// a directory on this machine
// ---------------------------------------------------------------------------

Future<PushResult> _pushLocal(
  Repository repository,
  Remote remote,
  Map<String, ObjectId> wanted,
  bool force,
  void Function(String)? onProgress,
) async {
  final target = Repository.discover(remote.localPath);
  if (target == null) {
    throw StateError('${remote.localPath} is not a repository');
  }

  try {
    final theirs = <String, ObjectId>{};
    for (final ref in target.refs.list()) {
      final id = target.refs.resolve(ref.path);
      if (id != null) theirs[ref.path] = id;
    }

    // Pushing to the branch a working tree has checked out leaves that tree
    // disagreeing with HEAD, which git refuses by default and so does this.
    final checkedOut = target.isBare ? null : target.refs.currentBranch;

    final statuses = <PushStatus>[];
    final accepted = <String, ObjectId>{};

    for (final entry in wanted.entries) {
      final before = theirs[entry.key];
      // Already there: nothing to send and nothing to report, which is what
      // the http path does too.
      if (before == entry.value) continue;
      if (entry.key == checkedOut) {
        statuses.add(PushStatus(
          ref: entry.key,
          to: entry.value,
          from: before,
          rejected: 'branch is checked out in that working tree',
        ));
        continue;
      }
      if (before != null &&
          !force &&
          !_contains(repository, entry.value, before)) {
        statuses.add(PushStatus(
          ref: entry.key,
          to: entry.value,
          from: before,
          rejected: 'not a fast-forward',
        ));
        continue;
      }
      accepted[entry.key] = entry.value;
    }

    var sent = 0;
    if (accepted.isNotEmpty) {
      final send = _objectsToSend(
        repository,
        accepted.values,
        theirs.values,
      );
      for (final id in send) {
        if (target.objects.contains(id)) continue;
        final raw = repository.objects.readRaw(id);
        if (raw == null) continue;
        target.objects.write(GitObject.parse(raw.kind, raw.content));
        sent += 1;
        if (sent % 500 == 0) onProgress?.call('sent $sent objects');
      }

      accepted.forEach((ref, id) {
        target.refs.write(
          ref,
          id,
          reflogMessage: 'push${force && theirs[ref] != null ? ' (forced)' : ''}',
        );
        statuses.add(PushStatus(
          ref: ref,
          to: id,
          from: theirs[ref],
          forced: force && theirs[ref] != null,
        ));
      });
      _updateTrackingRefs(repository, remote, accepted);
    }

    statuses.sort((a, b) => a.ref.compareTo(b.ref));
    return PushResult(statuses: statuses, objectsSent: sent);
  } finally {
    target.close();
  }
}

// ---------------------------------------------------------------------------
// smart HTTP
// ---------------------------------------------------------------------------

Future<PushResult> _pushHttp(
  Repository repository,
  Remote remote,
  Map<String, ObjectId> wanted,
  bool force,
  Credentials? given,
  void Function(String)? onProgress,
) async {
  // A `user@host` URL carries the name but not the secret, and HttpClient
  // ignores both, so they are taken out here and sent as a header instead.
  final split = splitCredentials(remote.pushUrl);
  final credentials = given ??
      (split.credentials != null && split.credentials!.password.isNotEmpty
          ? split.credentials
          : null);

  final full = split.url.toString();
  final base = full.endsWith('/') ? full.substring(0, full.length - 1) : full;
  final client = HttpClient();

  try {
    onProgress?.call('contacting $base');
    final adRequest = await client.getUrl(
      Uri.parse('$base/info/refs?service=git-receive-pack'),
    );
    adRequest.headers.set('User-Agent', 'git/git_dart-0.1');
    if (credentials != null) {
      adRequest.headers.set(
        HttpHeaders.authorizationHeader,
        credentials.authorizationHeader,
      );
    }
    final adResponse = await adRequest.close();
    if (adResponse.statusCode == 401) {
      await adResponse.drain<void>();
      throw AuthenticationRequired(
        base,
        realm: realmOf(adResponse),
        wereRejected: credentials != null,
      );
    }
    if (adResponse.statusCode != 200) {
      throw HttpException(
        'the server answered ${adResponse.statusCode} for the ref '
        'advertisement',
        uri: adRequest.uri,
      );
    }

    final advertisement = _readAdvertisement(await _collect(adResponse));
    final theirs = advertisement.refs;
    final capabilities = advertisement.capabilities;

    // ---- what may be sent ----
    final statuses = <PushStatus>[];
    final commands = <({String ref, ObjectId? from, ObjectId to})>[];

    for (final entry in wanted.entries) {
      final before = theirs[entry.key];
      if (before == entry.value) continue; // already there
      if (before != null &&
          !force &&
          !_contains(repository, entry.value, before)) {
        statuses.add(PushStatus(
          ref: entry.key,
          to: entry.value,
          from: before,
          rejected: 'not a fast-forward',
        ));
        continue;
      }
      commands.add((ref: entry.key, from: before, to: entry.value));
    }

    if (commands.isEmpty) {
      return PushResult(statuses: statuses);
    }

    // ---- the pack ----
    final send = _objectsToSend(
      repository,
      [for (final command in commands) command.to],
      theirs.values,
    );

    final writer = PackWriter();
    for (final id in send) {
      final raw = repository.objects.readRaw(id);
      if (raw == null) continue;
      writer.add(id, raw.kind, raw.content);
    }
    onProgress?.call('sending ${writer.length} objects');

    final agreed = <String>[
      if (capabilities.contains('report-status')) 'report-status',
      'agent=git/git_dart-0.1',
    ];

    final body = BytesBuilder();
    for (var i = 0; i < commands.length; i++) {
      final command = commands[i];
      final line = '${(command.from ?? ObjectId.zero).hex} '
          '${command.to.hex} ${command.ref}';
      body.add(
        PktLine.text(i == 0 ? '$line\x00${agreed.join(' ')}\n' : '$line\n')
            .encode(),
      );
    }
    body.add(PktLine.flush.encode());
    // The pack follows the commands directly, unframed.
    body.add(writer.build());

    final request = await client.postUrl(Uri.parse('$base/git-receive-pack'));
    request.headers
      ..set('Content-Type', 'application/x-git-receive-pack-request')
      ..set('Accept', 'application/x-git-receive-pack-result')
      ..set('User-Agent', 'git/git_dart-0.1');
    if (credentials != null) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        credentials.authorizationHeader,
      );
    }
    request.add(body.takeBytes());

    final response = await request.close();
    if (response.statusCode == 401) {
      await response.drain<void>();
      throw AuthenticationRequired(
        base,
        realm: realmOf(response),
        wereRejected: credentials != null,
      );
    }
    if (response.statusCode != 200) {
      throw HttpException(
        'the server answered ${response.statusCode} for the push',
        uri: request.uri,
      );
    }

    final report = _readReport(await _collect(response));
    if (report.unpackError != null) {
      throw StateError('the server could not unpack what was sent: '
          '${report.unpackError}');
    }

    final landed = <String, ObjectId>{};
    for (final command in commands) {
      final refused = report.refusals[command.ref];
      if (refused == null) landed[command.ref] = command.to;
      statuses.add(PushStatus(
        ref: command.ref,
        to: command.to,
        from: command.from,
        rejected: refused,
        forced: force && command.from != null,
      ));
    }
    _updateTrackingRefs(repository, remote, landed);

    statuses.sort((a, b) => a.ref.compareTo(b.ref));
    return PushResult(statuses: statuses, objectsSent: writer.length);
  } finally {
    client.close(force: true);
  }
}

/// Moves this repository's copy of the remote's branches to what was just
/// pushed.
///
/// Git does this on every successful push, and without it a repository that
/// has only ever pushed has no `refs/remotes/<remote>/…` at all — so nothing
/// to compare a branch against, and every question about how far ahead it is
/// answers "no idea". Found exactly that way.
void _updateTrackingRefs(
  Repository repository,
  Remote remote,
  Map<String, ObjectId> pushed,
) {
  pushed.forEach((ref, id) {
    final tracking = remote.trackingRefFor(ref);
    if (tracking == null || tracking.isEmpty) return;
    repository.refs.write(tracking, id, reflogMessage: 'update by push');
  });
}

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder();
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

({Map<String, ObjectId> refs, Set<String> capabilities}) _readAdvertisement(
  Uint8List bytes,
) {
  final reader = PktLineReader(bytes);
  final refs = <String, ObjectId>{};
  final capabilities = <String>{};

  var first = true;
  while (true) {
    final packet = reader.next();
    if (packet == null) break;
    if (packet.kind != PktKind.data) continue;
    if (packet.text.startsWith('#')) continue;

    final line = parseAdvertisement(packet);
    if (first) {
      capabilities.addAll(line.capabilities);
      first = false;
    }
    if (line.name == '0' * 40) continue; // an empty repository
    if (line.path.endsWith('^{}')) continue;
    refs[line.path] = ObjectId.fromHex(line.name);
  }

  return (refs: refs, capabilities: capabilities);
}

/// `unpack ok`, then `ok <ref>` or `ng <ref> <why>` for each command.
({String? unpackError, Map<String, String> refusals}) _readReport(
  Uint8List bytes,
) {
  final reader = PktLineReader(bytes);
  final refusals = <String, String>{};
  String? unpackError;

  while (true) {
    final packet = reader.next();
    if (packet == null) break;
    if (packet.kind != PktKind.data) continue;

    var text = packet.text;
    // A server that agreed side-band puts the report on band 1.
    if (packet.payload.isNotEmpty && packet.payload.first <= 3) {
      final band = packet.payload.first;
      final rest = utf8.decode(
        Uint8List.sublistView(packet.payload, 1),
        allowMalformed: true,
      );
      if (band == 3) return (unpackError: rest.trim(), refusals: refusals);
      if (band == 2) continue;
      text = rest;
    }

    for (final line in const LineSplitter().convert(text)) {
      if (line.startsWith('unpack ')) {
        final status = line.substring(7).trim();
        if (status != 'ok') unpackError = status;
      } else if (line.startsWith('ng ')) {
        final rest = line.substring(3).trim();
        final space = rest.indexOf(' ');
        if (space > 0) {
          refusals[rest.substring(0, space)] = rest.substring(space + 1);
        } else {
          refusals[rest] = 'rejected';
        }
      }
    }
  }

  return (unpackError: unpackError, refusals: refusals);
}
