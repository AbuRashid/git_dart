import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../hooks/hook_steps.dart';
import '../hooks/hooks.dart';
import '../object_id.dart';
import '../objects/commit.dart';
import '../objects/git_object.dart';
import '../objects/tag.dart';
import '../objects/tree.dart';
import '../remote/remote.dart';
import '../repository.dart';
import '../storage/pack_writer.dart';
import '../platform/http.dart';
import 'connection.dart';
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

/// What a caller believes the remote currently holds.
///
/// The lease is what makes a rewind safe to take. `force` says "overwrite
/// whatever is there", which throws away work if somebody pushed in the
/// meantime and nobody finds out until they look. A lease says "overwrite it
/// only if it is still what I last saw" — so a rewind that was safe when it
/// was decided on is still safe when it lands, and one that is not is refused
/// instead of quietly taken.
class PushLease {
  /// What the remote is expected to hold, by ref path. A ref named here with
  /// a null value is expected not to exist at all.
  final Map<String, ObjectId?> expected;

  /// Where an unnamed ref's expectation comes from when [expected] is silent:
  /// the remote-tracking ref, which records what was there at the last fetch.
  final bool useTrackingRefs;

  const PushLease({
    this.expected = const {},
    this.useTrackingRefs = true,
  });

  /// The ordinary lease: every ref held against its tracking ref.
  static const PushLease fromTracking = PushLease();

  /// A lease naming the values outright, for a caller that knows what it saw
  /// and would rather not depend on when it last fetched.
  factory PushLease.of(Map<String, ObjectId?> expected) =>
      PushLease(expected: expected, useTrackingRefs: false);
}

/// Sends [branches] to [remote]. Defaults to the current branch.
///
/// A push is refused when it would not be a fast-forward — the remote holds
/// commits the new tip does not contain — unless [force] or [lease]. That
/// check is the whole of what stands between pushing and losing someone
/// else's work, so it happens here as well as on the server, which may not be
/// configured to make it.
///
/// [lease] is the safe way to rewind: the push goes through only while the
/// remote still holds what the caller last saw. [force] is the unsafe way, and
/// wins over a lease when both are given — a caller that asked for both has
/// asked for the stronger thing.
///
/// Three transports: a directory on this machine, smart HTTP(S), and the two
/// duplex ones — ssh and the git daemon — which are one open connection to
/// `git-receive-pack` rather than a request and a response. Everything above
/// the transport is shared: the same fast-forward check, the same commands,
/// the same pack, the same report. [credentials] only means something to
/// HTTP; ssh authenticates itself, through [sshCommand], exactly as a fetch
/// does, and the daemon does not authenticate at all.
///
/// Once the remote's refs are known and before anything is sent, the
/// `pre-push` hook runs with the remote's name and URL, and a line on its
/// input for each ref about to be updated:
/// `<local ref> <local sha> <remote ref> <remote sha>`, the remote's being
/// zeros for a new branch. A ref already up to date or refused here is not
/// listed, as in git. If the hook fails, [HookFailedException] is thrown and
/// the remote is untouched; [noVerify] skips the hook.
Future<PushResult> push(
  Repository repository,
  Remote remote, {
  List<String>? branches,
  bool force = false,
  PushLease? lease,
  Credentials? credentials,
  void Function(String message)? onProgress,
  String sshCommand = 'ssh',
  bool noVerify = false,
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

  final held = force
      ? null
      : _heldValues(repository, remote, wanted.keys, lease);

  Future<void> prePush(Map<String, ({ObjectId? from, ObjectId to})> updates) {
    if (noVerify) return Future.value();
    return _runPrePush(repository, remote, updates);
  }

  if (remote.isLocal) {
    return _pushLocal(
        repository, remote, wanted, force, held, onProgress, prePush);
  }
  final url = remote.pushUrl;
  if (url.startsWith('http://') || url.startsWith('https://')) {
    return _pushHttp(repository, remote, wanted, force, held, credentials,
        onProgress, prePush);
  }

  // Git never asks receive-pack for protocol version 2: v2 has no push
  // command, and git's own client downgrades a push to v0 before it connects
  // (`connect.c`). Asking anyway would only invite a server to answer in a
  // dialect that cannot carry what is about to be sent.
  final connection = await connectTo(
    url,
    'git-receive-pack',
    sshCommand: sshCommand,
    requestVersion2: false,
  );
  if (connection != null) {
    return _pushOverConnection(repository, remote, connection, wanted, force,
        held, onProgress, prePush);
  }

  throw UnsupportedError(
    'no transport for $url: this build pushes to a local path, http(s), '
    'ssh and git://',
  );
}

typedef _PrePush = Future<void> Function(
    Map<String, ({ObjectId? from, ObjectId to})> updates);

/// Runs `pre-push` over [updates], throwing when it refuses.
///
/// The local and remote ref are the same name because this library only
/// pushes a branch to the branch of the same name.
Future<void> _runPrePush(
  Repository repository,
  Remote remote,
  Map<String, ({ObjectId? from, ObjectId to})> updates,
) async {
  final input = StringBuffer();
  updates.forEach((ref, update) {
    input.write('$ref ${update.to.hex} $ref '
        '${(update.from ?? ObjectId.zero).hex}\n');
  });
  await runHookAsync(
    repository,
    'pre-push',
    arguments: [remote.name, remote.pushUrl],
    stdin: input.toString(),
  );
}

/// What each ref is leased against, or null when there is no lease at all.
///
/// A ref the lease cannot speak for is left out rather than given some
/// default: leasing against a value nobody recorded would let a rewind through
/// on the strength of a guess, which is the one thing a lease exists to stop.
Map<String, ObjectId?>? _heldValues(
  Repository repository,
  Remote remote,
  Iterable<String> refs,
  PushLease? lease,
) {
  if (lease == null) return null;

  final held = <String, ObjectId?>{};
  for (final ref in refs) {
    if (lease.expected.containsKey(ref)) {
      held[ref] = lease.expected[ref];
      continue;
    }
    if (!lease.useTrackingRefs) continue;

    final tracking = remote.trackingRefFor(ref);
    if (tracking == null || tracking.isEmpty) continue;
    // A tracking ref that does not exist says nothing: this repository has
    // never seen the branch, so it holds no opinion about it.
    final seen = repository.refs.resolve(tracking);
    if (seen == null) continue;
    held[ref] = seen;
  }
  return held;
}

/// Why a rewind of [ref] is refused, or null when it may go ahead.
///
/// Reached only when the push is not a fast-forward, so the question is always
/// whether the rewind is allowed rather than whether one is happening.
String? _leaseRefusal(
  Map<String, ObjectId?>? held,
  String ref,
  ObjectId? remoteHas,
) {
  if (held == null) return 'not a fast-forward';
  if (!held.containsKey(ref)) {
    return 'no lease: nothing recorded for $ref, so fetch first';
  }
  if (held[ref] != remoteHas) {
    return 'stale info: the remote has moved since it was last fetched';
  }
  return null;
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

/// The name each of [objects] is known by, taken from the trees among them.
///
/// Only used to order the pack: the packer groups revisions of one file
/// together so it has plausible delta bases to try, and a name it does not
/// have simply falls back to ordering by size.
Map<ObjectId, String> _namesWithin(
  Repository repository,
  Iterable<ObjectId> objects,
) {
  final names = <ObjectId, String>{};
  for (final id in objects) {
    final raw = repository.objects.readRaw(id);
    if (raw == null || raw.kind != ObjectKind.tree) continue;
    for (final entry in Tree.parse(raw.content).entries) {
      if (entry.mode.isSubmodule) continue;
      names.putIfAbsent(entry.id, () => entry.name);
    }
  }
  return names;
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
  Map<String, ObjectId?>? held,
  void Function(String)? onProgress,
  _PrePush prePush,
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
        final refusal = _leaseRefusal(held, entry.key, before);
        if (refusal != null) {
          statuses.add(PushStatus(
            ref: entry.key,
            to: entry.value,
            from: before,
            rejected: refusal,
          ));
          continue;
        }
      }
      accepted[entry.key] = entry.value;
    }

    await prePush({
      for (final entry in accepted.entries)
        entry.key: (from: theirs[entry.key], to: entry.value),
    });

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
        // A rewind is a rewind whether force or a lease allowed it, and the
        // reflog is the only place it will be recorded.
        final before = theirs[ref];
        final rewound = before != null && !_contains(repository, id, before);
        target.refs.write(
          ref,
          id,
          reflogMessage: 'push${rewound ? ' (forced)' : ''}',
        );
        statuses.add(PushStatus(
          ref: ref,
          to: id,
          from: before,
          forced: rewound,
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
// what every wire transport shares
// ---------------------------------------------------------------------------

/// One line of a push request: move [ref] from [from] to [to].
typedef _Command = ({String ref, ObjectId? from, ObjectId to});

/// What `pre-push` is told about a plan: the refs about to move.
Map<String, ({ObjectId? from, ObjectId to})> _hookUpdates(
        List<_Command> commands) =>
    {
      for (final command in commands)
        command.ref: (from: command.from, to: command.to),
    };

/// What the push will ask for, and what it already knows will be refused.
///
/// Decided entirely from the advertisement, before a byte of the pack is
/// built. A ref refused here is never offered to the server at all, which is
/// both cheaper and safer than relying on the server to refuse it: a server
/// with `receive.denyNonFastForwards` unset would take it.
({List<PushStatus> statuses, List<_Command> commands}) _plan(
  Repository repository,
  Map<String, ObjectId> wanted,
  Map<String, ObjectId> theirs,
  bool force,
  Map<String, ObjectId?>? held,
) {
  final statuses = <PushStatus>[];
  final commands = <_Command>[];

  for (final entry in wanted.entries) {
    final before = theirs[entry.key];
    if (before == entry.value) continue; // already there
    if (before != null &&
        !force &&
        !_contains(repository, entry.value, before)) {
      final refusal = _leaseRefusal(held, entry.key, before);
      if (refusal != null) {
        statuses.add(PushStatus(
          ref: entry.key,
          to: entry.value,
          from: before,
          rejected: refusal,
        ));
        continue;
      }
    }
    commands.add((ref: entry.key, from: before, to: entry.value));
  }
  return (statuses: statuses, commands: commands);
}

/// The packfile for [commands]: everything their new tips reach that the
/// server did not advertise.
PackWriter _packFor(
  Repository repository,
  List<_Command> commands,
  Map<String, ObjectId> theirs,
) {
  final send = _objectsToSend(
    repository,
    [for (final command in commands) command.to],
    theirs.values,
  );

  final writer = PackWriter();
  final names = _namesWithin(repository, send);
  for (final id in send) {
    final raw = repository.objects.readRaw(id);
    if (raw == null) continue;
    // Named where the name is known, so revisions of one file sit together
    // and the packer has plausible delta bases to try.
    writer.add(id, raw.kind, raw.content, name: names[id]);
  }
  return writer;
}

/// The capabilities this client asks for, out of what the server offered.
///
/// `report-status-v2` is preferred when offered, as git prefers it: its `ok`
/// and `ng` lines are the ones version 1 sends, and the `option` lines it adds
/// — which a server running a `proc-receive` hook uses to say a ref landed
/// somewhere other than where it was sent — are read past rather than
/// misread. Side-band is asked for only where the reply can be demultiplexed
/// as it arrives, which is the duplex transports.
List<String> _agree(Set<String> offered, {required bool sideBand}) => [
      if (offered.contains('report-status-v2'))
        'report-status-v2'
      else if (offered.contains('report-status'))
        'report-status',
      if (sideBand && offered.contains('side-band-64k')) 'side-band-64k',
      'agent=git/git_dart-0.1',
    ];

/// The command section of a push request, flush included.
///
/// The capabilities ride on the first command after a NUL, the same trick the
/// advertisement uses. The pack follows directly after the flush, unframed.
Uint8List _commandSection(List<_Command> commands, List<String> agreed) {
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
  return body.takeBytes();
}

/// Turns the server's report into the result, and moves the tracking refs of
/// whatever landed.
PushResult _conclude(
  Repository repository,
  Remote remote,
  List<_Command> commands,
  List<PushStatus> statuses,
  _Report report,
  int objectsSent,
) {
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
      // A rewind is a rewind whether force or a lease allowed it.
      forced: command.from != null &&
          !_contains(repository, command.to, command.from!),
    ));
  }
  _updateTrackingRefs(repository, remote, landed);

  statuses.sort((a, b) => a.ref.compareTo(b.ref));
  return PushResult(statuses: statuses, objectsSent: objectsSent);
}

// ---------------------------------------------------------------------------
// smart HTTP
// ---------------------------------------------------------------------------

Future<PushResult> _pushHttp(
  Repository repository,
  Remote remote,
  Map<String, ObjectId> wanted,
  bool force,
  Map<String, ObjectId?>? held,
  Credentials? given,
  void Function(String)? onProgress,
  _PrePush prePush,
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
  final client = newHttpClient();

  Map<String, String> headersFor(Map<String, String> extra) => {
        GitHttpHeaders.userAgent: 'git/git_dart-0.1',
        if (credentials != null)
          GitHttpHeaders.authorization: credentials.authorizationHeader,
        ...extra,
      };

  try {
    onProgress?.call('contacting $base');
    final adUrl = Uri.parse('$base/info/refs?service=git-receive-pack');
    final adResponse = await client.send(
      method: 'GET',
      url: adUrl,
      headers: headersFor(const {}),
    );
    if (adResponse.statusCode == 401) {
      await adResponse.body.drain<void>();
      throw AuthenticationRequired(
        base,
        realm: realmOf(adResponse),
        wereRejected: credentials != null,
      );
    }
    if (adResponse.statusCode != 200) {
      throw GitHttpException(
        'the server answered ${adResponse.statusCode} for the ref '
        'advertisement',
        url: adUrl,
      );
    }

    final advertisement = _readAdvertisement(await _collect(adResponse.body));
    final theirs = advertisement.refs;

    final plan = _plan(repository, wanted, theirs, force, held);
    await prePush(_hookUpdates(plan.commands));
    if (plan.commands.isEmpty) {
      return PushResult(statuses: plan.statuses);
    }

    final writer = _packFor(repository, plan.commands, theirs);
    onProgress?.call('sending ${writer.length} objects');

    // No side-band over HTTP: the whole reply arrives as one body after the
    // server has finished, so there is no progress to show while it works.
    final agreed = _agree(advertisement.capabilities, sideBand: false);
    final body = BytesBuilder()
      ..add(_commandSection(plan.commands, agreed))
      ..add(writer.build());

    final pushUrl = Uri.parse('$base/git-receive-pack');
    final response = await client.send(
      method: 'POST',
      url: pushUrl,
      headers: headersFor({
        GitHttpHeaders.contentType: 'application/x-git-receive-pack-request',
        GitHttpHeaders.accept: 'application/x-git-receive-pack-result',
      }),
      body: body.takeBytes(),
    );
    if (response.statusCode == 401) {
      await response.body.drain<void>();
      throw AuthenticationRequired(
        base,
        realm: realmOf(response),
        wereRejected: credentials != null,
      );
    }
    if (response.statusCode != 200) {
      throw GitHttpException(
        'the server answered ${response.statusCode} for the push',
        url: pushUrl,
      );
    }

    final reader = PktLineReader(await _collect(response.body));
    final report = await _readReport(
      () async => reader.next(),
      sideBand: false,
      onProgress: onProgress,
    );
    return _conclude(repository, remote, plan.commands, plan.statuses, report,
        writer.length);
  } finally {
    client.close();
  }
}

// ---------------------------------------------------------------------------
// ssh and the git daemon
// ---------------------------------------------------------------------------

/// A push over one open connection to `git-receive-pack`.
///
/// The same exchange as HTTP with the seams removed: the advertisement, then
/// the commands and the pack, then the report, all on one stream. What the
/// duplex shape adds is that the report can arrive while the server is still
/// working, so side-band is worth asking for — the server's progress, and the
/// output of its hooks, come back on band 2 as they happen.
Future<PushResult> _pushOverConnection(
  Repository repository,
  Remote remote,
  PacketConnection connection,
  Map<String, ObjectId> wanted,
  bool force,
  Map<String, ObjectId?>? held,
  void Function(String)? onProgress,
  _PrePush prePush,
) async {
  try {
    onProgress?.call('contacting ${remote.pushUrl}');

    // ---- what the server opened with ----
    final rejoined = BytesBuilder();
    var said = false;
    while (true) {
      final packet = await connection.receive();
      if (packet == null || packet.kind != PktKind.data) break;
      said = true;
      rejoined.add(packet.encode());
    }
    if (!said) {
      throw StateError(
        'the server said nothing. '
        '${connection is SshConnection && connection.diagnostics.isNotEmpty ? connection.diagnostics : 'It may not have a repository at that path, or — for a git '
            'daemon — may not have been started with '
            '--enable=receive-pack.'}',
      );
    }
    rejoined.add(PktLine.flush.encode());

    final advertisement = _readAdvertisement(rejoined.takeBytes());
    final theirs = advertisement.refs;

    final plan = _plan(repository, wanted, theirs, force, held);
    // Before anything is sent. A refusing hook still has to close the
    // conversation politely, which the flush below does.
    try {
      await prePush(_hookUpdates(plan.commands));
    } on Object {
      connection.send(PktLine.flush.encode());
      await connection.flush();
      rethrow;
    }
    if (plan.commands.isEmpty) {
      // A flush with no commands is how a client says it has nothing to
      // push; receive-pack then exits without waiting for a pack.
      connection.send(PktLine.flush.encode());
      await connection.flush();
      return PushResult(statuses: plan.statuses);
    }

    final writer = _packFor(repository, plan.commands, theirs);
    onProgress?.call('sending ${writer.length} objects');

    final agreed = _agree(advertisement.capabilities, sideBand: true);
    connection
      ..send(_commandSection(plan.commands, agreed))
      ..send(writer.build());
    // Flushed before the report is read: the server is waiting for the end of
    // the pack, and bytes still in a local buffer are a deadlock.
    await connection.flush();

    final report = await _readReport(
      connection.receive,
      sideBand: agreed.contains('side-band-64k'),
      onProgress: onProgress,
    );
    return _conclude(repository, remote, plan.commands, plan.statuses, report,
        writer.length);
  } finally {
    await connection.close();
  }
}

// ---------------------------------------------------------------------------
// reading what the server says
// ---------------------------------------------------------------------------

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

    // A server asked for version 1 says so before its refs, and otherwise
    // speaks version 0; the line is a preamble, not a ref.
    final text = packet.text.trimRight();
    if (text == 'version 1') continue;
    // Version 2 has no push, so a server that answers in it anyway cannot be
    // pushed to over this conversation. git's receive-pack falls back to
    // version 0 by itself, so this is some other server — said plainly
    // rather than left to fail parsing capability lines as refs.
    if (text == 'version 2') {
      throw UnsupportedError(
        'the server answered a push in protocol version 2, which has no push '
        'command',
      );
    }

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

typedef _Report = ({String? unpackError, Map<String, String> refusals});

/// `unpack ok`, then `ok <ref>` or `ng <ref> <why>` for each command, up to a
/// flush.
///
/// With side-band agreed the report is not the packets themselves: it is a
/// pkt-line stream of its own, cut into pieces and carried inside band 1, with
/// band 2 for progress and band 3 for a fatal error. The pieces are rejoined
/// and read once the outer flush arrives. Without side-band the packets are
/// the report — and are never mistaken for band-tagged ones, since a report
/// line starts with a letter.
///
/// `report-status-v2` adds `option …` lines after an `ok`; nothing here needs
/// them, so they are passed over.
Future<_Report> _readReport(
  Future<PktLine?> Function() next, {
  required bool sideBand,
  void Function(String)? onProgress,
}) async {
  final lines = <PktLine>[];

  if (sideBand) {
    final band1 = BytesBuilder();
    final progress = StringBuffer();
    while (true) {
      final packet = await next();
      if (packet == null || packet.kind != PktKind.data) break;
      if (packet.payload.isEmpty) continue;
      final rest = Uint8List.sublistView(packet.payload, 1);
      switch (packet.payload.first) {
        case 1:
          band1.add(rest);
        case 2:
          // Progress arrives in fragments and uses `\r` to redraw a line;
          // each finished line or redraw is reported once.
          progress.write(utf8.decode(rest, allowMalformed: true));
          final text = progress.toString();
          final cut = text.lastIndexOf(RegExp('[\r\n]'));
          if (cut >= 0) {
            for (final message
                in text.substring(0, cut).split(RegExp('[\r\n]'))) {
              if (message.trim().isNotEmpty) onProgress?.call(message.trim());
            }
            progress
              ..clear()
              ..write(text.substring(cut + 1));
          }
        case 3:
          throw StateError('the server gave up: '
              '${utf8.decode(rest, allowMalformed: true).trim()}');
      }
    }
    final inner = PktLineReader(band1.takeBytes());
    while (true) {
      final packet = inner.next();
      if (packet == null || packet.kind != PktKind.data) break;
      lines.add(packet);
    }
  } else {
    while (true) {
      final packet = await next();
      if (packet == null || packet.kind != PktKind.data) break;
      lines.add(packet);
    }
  }

  final refusals = <String, String>{};
  String? unpackError;
  for (final packet in lines) {
    for (final line in const LineSplitter().convert(packet.text)) {
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
