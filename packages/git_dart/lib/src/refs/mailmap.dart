/// `.mailmap` — the file that says two identities are one person.
///
/// Identities are written into commits and commits are immutable, so a
/// contributor who changed address, or whose name was misspelled once, is
/// permanently several people as far as the object model is concerned. The
/// mailmap is the correction: a file, committed alongside the code, mapping
/// what the commits say onto what is true.
///
/// git applies it by default in `log`, `blame` and `shortlog`, which is why
/// this is not an optional nicety — a listing that skips it disagrees with
/// every listing the same repository produces elsewhere.
///
/// Four line forms, each mapping to a proper name and address:
///
/// ```
/// Proper Name <proper@example.com>
/// <proper@example.com> <commit@example.com>
/// Proper Name <proper@example.com> <commit@example.com>
/// Proper Name <proper@example.com> Commit Name <commit@example.com>
/// ```
///
/// The first sets the name for everyone using that address. The rest key on
/// the commit address, optionally narrowed by the commit name — which is how
/// two people who once shared a machine account are told apart.
library;

import 'dart:convert';

import 'package:path/path.dart' as p;

import '../fs/git_fs.dart';
import '../objects/identity.dart';
import '../repository.dart';

/// A parsed `.mailmap`.
class Mailmap {
  /// Keyed by lowercased commit address, then by lowercased commit name. The
  /// empty name is the entry that applies to any name.
  final Map<String, Map<String, ({String? name, String? email})>> _byEmail;

  const Mailmap._(this._byEmail);

  static const Mailmap empty = Mailmap._({});

  bool get isEmpty => _byEmail.isEmpty;

  /// Parses mailmap text. Unparseable lines are skipped rather than thrown
  /// over: the file is committed content, and one bad line should not cost a
  /// caller the other four hundred good ones.
  factory Mailmap.parse(String text) {
    final byEmail = <String, Map<String, ({String? name, String? email})>>{};

    for (var line in const LineSplitter().convert(text)) {
      final hash = line.indexOf('#');
      if (hash >= 0) line = line.substring(0, hash);
      line = line.trim();
      if (line.isEmpty) continue;

      // Up to two `<address>` fields, with free text before each one.
      final addresses = <({String value, int start, int end})>[];
      var from = 0;
      while (addresses.length < 2) {
        final open = line.indexOf('<', from);
        if (open < 0) break;
        final close = line.indexOf('>', open + 1);
        if (close < 0) break;
        addresses.add((
          value: line.substring(open + 1, close),
          start: open,
          end: close,
        ));
        from = close + 1;
      }
      if (addresses.isEmpty) continue;

      final properName = line.substring(0, addresses.first.start).trim();
      final properEmail = addresses.first.value.trim();

      final String commitName;
      final String commitEmail;
      if (addresses.length == 2) {
        commitName = line
            .substring(addresses.first.end + 1, addresses[1].start)
            .trim();
        commitEmail = addresses[1].value.trim();
      } else {
        // One address: it is both what commits say and what they should say,
        // so this form can only correct the name.
        commitName = '';
        commitEmail = properEmail;
      }
      if (commitEmail.isEmpty) continue;

      byEmail.putIfAbsent(commitEmail.toLowerCase(), () => {})[
          commitName.toLowerCase()] = (
        name: properName.isEmpty ? null : properName,
        email: properEmail.isEmpty ? null : properEmail,
      );
    }

    return Mailmap._(byEmail);
  }

  /// The mailmap in force for [repository].
  ///
  /// `.mailmap` at the top of the working tree is the usual place. Config can
  /// name another file with `mailmap.file` or a committed blob with
  /// `mailmap.blob`, which is how a bare repository — having no working tree
  /// to hold the file — gets one at all.
  factory Mailmap.forRepository(Repository repository) {
    final workTree = repository.workTree;
    if (workTree != null) {
      final file = fs.file(p.join(workTree, '.mailmap'));
      if (file.existsSync()) return Mailmap.parse(file.readAsStringSync());
    }

    if (repository.config['mailmap.file'] case final path?) {
      final file = fs.file(path);
      if (file.existsSync()) return Mailmap.parse(file.readAsStringSync());
    }

    if (repository.config['mailmap.blob'] case final revision?) {
      final id = repository.resolve(revision);
      if (id != null) {
        final raw = repository.objects.readRaw(id);
        if (raw != null) {
          return Mailmap.parse(utf8.decode(raw.content, allowMalformed: true));
        }
      }
    }

    return Mailmap.empty;
  }

  /// The name and address this identity should be shown under.
  ///
  /// The timestamp is carried through untouched: the mailmap corrects who
  /// someone is, never when they did something.
  Identity resolve(Identity identity) {
    final entry = _entryFor(identity.name, identity.email);
    if (entry == null) return identity;
    return Identity(
      name: entry.name ?? identity.name,
      email: entry.email ?? identity.email,
      seconds: identity.seconds,
      timezone: identity.timezone,
    );
  }

  /// As [resolve], for a caller that has the two fields and no [Identity].
  ({String name, String email}) resolveParts(String name, String email) {
    final entry = _entryFor(name, email);
    return (name: entry?.name ?? name, email: entry?.email ?? email);
  }

  ({String? name, String? email})? _entryFor(String name, String email) {
    final byName = _byEmail[email.toLowerCase()];
    if (byName == null) return null;
    // A rule naming the commit name wins over the one that takes any name:
    // it is the more specific statement about who this is.
    return byName[name.toLowerCase()] ?? byName[''];
  }
}
