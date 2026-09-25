/// Signed commits and tags: where the signature lives, what exactly was
/// signed, and what the signing program said about it.
///
/// Git does no cryptography of its own here. It cuts an object into the bytes
/// that were signed and the signature over them, hands both to an external
/// program — `gpg`, `gpgsm` or `ssh-keygen` — and reads the verdict out of
/// what that program prints (`gpg-interface.c`). This library does the same,
/// for the same reason: a signature is only worth what the keyring or the
/// allowed-signers file behind it is worth, and those belong to the user's
/// tools, not to a git implementation.
///
/// Everything in this file is pure: cutting objects apart, putting signatures
/// in, and parsing program output. Running the programs is a
/// [SignatureTool]'s job, and the one that runs processes comes from
/// `signature_io.dart` — in a browser, from a stand-in that refuses.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../config/git_config.dart';
import '../objects/commit.dart';

import 'signature_io.dart' if (dart.library.js_interop) 'signature_web.dart'
    as impl;

export 'signature_io.dart' if (dart.library.js_interop) 'signature_web.dart'
    show ProcessSignatureTool;

/// The kinds of signature git knows, told apart by their first line.
///
/// Git decides the format of an existing signature by looking at it, never by
/// asking `gpg.format` — that setting only says what to *make*. A repository
/// can hold OpenPGP and SSH signatures side by side, and each is checked by
/// its own program.
enum SignatureFormat {
  openpgp('gpg', [
    '-----BEGIN PGP SIGNATURE-----',
    '-----BEGIN PGP MESSAGE-----',
  ]),
  x509('gpgsm', ['-----BEGIN SIGNED MESSAGE-----']),
  ssh('ssh-keygen', ['-----BEGIN SSH SIGNATURE-----']);

  /// The program used when configuration names none.
  final String defaultProgram;

  /// First lines that mark a signature of this format.
  final List<String> markers;

  const SignatureFormat(this.defaultProgram, this.markers);

  /// The format `gpg.format` names, which is what new signatures are made in.
  ///
  /// Unset means OpenPGP, as it always has. An unknown name is an error rather
  /// than a fallback: signing in a format the user did not ask for would make
  /// a signature their verifiers cannot check.
  static SignatureFormat configured(GitConfig config) {
    final name = config['gpg.format'];
    if (name == null) return openpgp;
    for (final format in values) {
      if (format.name == name) return format;
    }
    throw StateError("invalid value for 'gpg.format': '$name'");
  }

  /// The format of [signature], by its first line, or null when it is none
  /// git would recognise.
  static SignatureFormat? of(String signature) {
    for (final format in values) {
      for (final marker in format.markers) {
        if (signature.startsWith(marker)) return format;
      }
    }
    return null;
  }

  /// The program that makes and checks signatures of this format.
  ///
  /// `gpg.program` is the older spelling of `gpg.openpgp.program` and still
  /// what most configurations say, so OpenPGP honours both.
  String programFrom(GitConfig config) =>
      config['gpg.$name.program'] ??
      (this == openpgp ? config['gpg.program'] : null) ??
      defaultProgram;
}

/// What `git log --format=%G?` prints for a commit: one letter per verdict.
enum SignatureStatus {
  /// A good signature from a key trusted enough to say so.
  good('G'),

  /// A good signature from a key whose validity is unknown — for SSH, one that
  /// is in no allowed-signers entry.
  unknownValidity('U'),

  /// The signature does not match the object.
  bad('B'),

  /// A good signature that has itself expired.
  expiredSignature('X'),

  /// A good signature made by a key that has since expired.
  expiredKey('Y'),

  /// A good signature made by a key that has since been revoked.
  revokedKey('R'),

  /// The signature could not be checked — usually a missing public key.
  cannotCheck('E'),

  /// No signature, or none that could be looked at.
  none('N');

  /// The `%G?` letter.
  final String code;

  const SignatureStatus(this.code);
}

/// How far gpg trusts the key that made a signature, lowest first — the
/// `TRUST_*` status lines, and the values of `gpg.minTrustLevel`.
enum TrustLevel {
  undefined,
  never,
  marginal,
  fully,
  ultimate;

  /// The level named [name], ignoring case, or null.
  static TrustLevel? byName(String name) {
    final lower = name.toLowerCase();
    for (final level in values) {
      if (level.name == lower) return level;
    }
    return null;
  }
}

/// What checking one signature found.
///
/// There are two answers here and they are not the same question.
/// [status] is what `%G?` shows, and says what gpg thinks of the key;
/// [isVerified] is what `git verify-commit` exits with, and says whether the
/// signature should be accepted under this repository's `gpg.minTrustLevel`.
/// A good signature from a key nobody has vouched for is `U` and yet passes
/// `verify-commit` by default — git's own behaviour, kept so that the two
/// agree with it.
class SignatureCheck {
  /// The program's verdict before trust is considered: never
  /// [SignatureStatus.unknownValidity], which [status] derives.
  final SignatureStatus result;

  final TrustLevel trustLevel;

  /// Whether the program itself reported success. An SSH signature from a key
  /// with no allowed-signers entry is a correct signature that the program
  /// nonetheless refused, and that difference is only visible here.
  final bool toolSucceeded;

  /// The lowest trust [isVerified] accepts — `gpg.minTrustLevel`.
  final TrustLevel minimumTrust;

  /// The format of the signature, or null when there was none.
  final SignatureFormat? format;

  /// Who signed: the key's user id for OpenPGP, the principal for SSH.
  final String? signer;

  /// The key id — the long id for OpenPGP, the fingerprint for SSH.
  final String? key;

  final String? fingerprint;

  /// For OpenPGP, the primary key's fingerprint when a subkey signed.
  final String? primaryKeyFingerprint;

  /// What the program said for a person to read: what `git verify-commit`
  /// prints.
  final String output;

  /// What the program said for a machine to read: what
  /// `git verify-commit --raw` prints. gpg's status lines, or for SSH the
  /// same text as [output].
  final String rawOutput;

  /// The bytes the signature covers.
  final Uint8List payload;

  /// The signature itself, or null when the object carries none.
  final String? signature;

  const SignatureCheck({
    required this.result,
    this.trustLevel = TrustLevel.undefined,
    this.toolSucceeded = false,
    this.minimumTrust = TrustLevel.undefined,
    this.format,
    this.signer,
    this.key,
    this.fingerprint,
    this.primaryKeyFingerprint,
    this.output = '',
    this.rawOutput = '',
    required this.payload,
    this.signature,
  });

  /// The `%G?` verdict.
  SignatureStatus get status {
    if (result == SignatureStatus.good &&
        trustLevel.index <= TrustLevel.never.index) {
      return SignatureStatus.unknownValidity;
    }
    return result;
  }

  /// Whether `git verify-commit` / `git verify-tag` would succeed.
  bool get isVerified =>
      toolSucceeded &&
      result == SignatureStatus.good &&
      trustLevel.index >= minimumTrust.index;

  bool get isSigned => signature != null;

  SignatureCheck copyWith({
    TrustLevel? minimumTrust,
    Uint8List? payload,
    String? signature,
    SignatureFormat? format,
  }) =>
      SignatureCheck(
        result: result,
        trustLevel: trustLevel,
        toolSucceeded: toolSucceeded,
        minimumTrust: minimumTrust ?? this.minimumTrust,
        format: format ?? this.format,
        signer: signer,
        key: key,
        fingerprint: fingerprint,
        primaryKeyFingerprint: primaryKeyFingerprint,
        output: output,
        rawOutput: rawOutput,
        payload: payload ?? this.payload,
        signature: signature ?? this.signature,
      );

  @override
  String toString() => 'SignatureCheck(${status.code}'
      '${signer == null ? '' : ' $signer'}${key == null ? '' : ' $key'})';
}

/// What a [SignatureTool] is asked to sign with.
class SigningRequest {
  final SignatureFormat format;

  /// `user.signingKey`, or for OpenPGP and X.509 the committer's
  /// `Name <email>` when that is unset. For SSH: a key file, or a literal
  /// public key (`ssh-…` or `key::…`) whose private half is in the agent.
  final String key;

  /// The repository's configuration, for the program to use and anything
  /// else a tool may want to consult.
  final GitConfig config;

  const SigningRequest({
    required this.format,
    required this.key,
    required this.config,
  });
}

/// What a [SignatureTool] is asked to verify against.
class VerificationRequest {
  final SignatureFormat format;
  final GitConfig config;

  /// When the object says it was made — the committer's or tagger's time.
  /// SSH checks the key's validity window at that moment rather than now, so
  /// that a key retired later does not invalidate what it signed while valid.
  final int? payloadTimestamp;

  const VerificationRequest({
    required this.format,
    required this.config,
    this.payloadTimestamp,
  });
}

/// Makes and checks signatures.
///
/// The default runs the same programs git runs, and is what a repository uses
/// unless told otherwise. It needs `dart:io`; a browser app — or a test that
/// wants no processes — supplies its own, which is free to do the
/// cryptography in-process as long as it produces and accepts the same
/// armoured text.
abstract class SignatureTool {
  const SignatureTool();

  /// The platform's default: [ProcessSignatureTool] where processes exist, and
  /// otherwise a tool whose every call throws [UnsupportedError].
  static SignatureTool get platformDefault => impl.platformSignatureTool;

  /// A tool that runs nothing.
  ///
  /// Signing throws, and verification reports that the signature could not be
  /// checked — which is true, and is what a repository opened for inspection
  /// gets: checking a signature means running gpg or ssh-keygen, and which
  /// one, from where, is something the repository's own configuration has a
  /// say in.
  const factory SignatureTool.none() = _NoSignatureTool;

  /// A detached, armoured signature over [payload], with LF line endings and
  /// a final newline. Throws when signing fails.
  String sign(Uint8List payload, SigningRequest request);

  /// Checks [signature] over [payload].
  ///
  /// Never throws for a signature that is merely bad or uncheckable — that is
  /// a result, not an error.
  SignatureCheck verify(
    Uint8List payload,
    String signature,
    VerificationRequest request,
  );
}

// ---------------------------------------------------------------------------
// Cutting objects apart and putting signatures in.

/// The header a SHA-1 repository keeps a commit signature in.
const commitSignatureHeader = 'gpgsig';

/// The header a SHA-256 repository uses, which a SHA-1 repository strips from
/// the payload too (`parse_buffer_signed_by_header`): during a hash transition
/// an object can carry both, and each signature covers the object without
/// either.
const _otherSignatureHeaders = ['gpgsig-sha256'];

/// Splits a commit's raw content into what was signed and the signature.
///
/// The payload is the commit exactly as stored with every signature header
/// removed — its first line and all its continuation lines — and nothing else
/// changed. The signature is the header's value unfolded: continuation lines
/// lose their leading space and every line keeps its newline. Done on bytes,
/// not on parsed headers, because a single byte of difference is a bad
/// signature.
({Uint8List payload, String? signature}) splitSignedCommit(
  Uint8List content,
) {
  final payload = BytesBuilder(copy: false);
  final signature = BytesBuilder(copy: false);
  var found = false;
  var inSignature = false;
  var inOther = false;
  var line = 0;

  while (line < content.length) {
    final newline = content.indexOf(0x0a, line);
    final next = newline < 0 ? content.length : newline + 1;

    if ((inSignature || inOther) && content[line] == 0x20) {
      if (inSignature) signature.add(content.sublist(line + 1, next));
    } else if (_startsWithHeader(content, line, commitSignatureHeader)) {
      found = true;
      inSignature = true;
      inOther = false;
      signature.add(
        content.sublist(line + commitSignatureHeader.length + 1, next),
      );
    } else if (_otherSignatureHeaders
        .any((header) => _startsWithHeader(content, line, header))) {
      inOther = true;
      inSignature = false;
    } else {
      if (content[line] == 0x0a) {
        // The blank line: the message, and everything after it, is signed.
        payload.add(content.sublist(line));
        break;
      }
      payload.add(content.sublist(line, next));
      inSignature = false;
      inOther = false;
    }
    line = next;
  }

  return (
    payload: payload.takeBytes(),
    signature: found ? utf8.decode(signature.takeBytes()) : null,
  );
}

bool _startsWithHeader(Uint8List content, int at, String header) {
  if (at + header.length >= content.length) return false;
  for (var i = 0; i < header.length; i++) {
    if (content[at + i] != header.codeUnitAt(i)) return false;
  }
  return content[at + header.length] == 0x20;
}

/// Splits a tag's raw content into what was signed and the signature.
///
/// A tag's signature is not a header but the tail of its message: everything
/// from the *last* line that begins like a signature (`parse_signed_buffer`).
/// The last, because a message is free to quote a signature and only the one
/// at the end is the tag's own.
({Uint8List payload, String? signature}) splitSignedTag(Uint8List content) {
  var match = content.length;
  var line = 0;
  while (line < content.length) {
    if (_startsWithMarker(content, line)) match = line;
    final newline = content.indexOf(0x0a, line);
    line = newline < 0 ? content.length : newline + 1;
  }
  if (match == content.length) return (payload: content, signature: null);
  return (
    payload: Uint8List.sublistView(content, 0, match),
    signature: utf8.decode(content.sublist(match), allowMalformed: true),
  );
}

bool _startsWithMarker(Uint8List content, int at) {
  for (final format in SignatureFormat.values) {
    for (final marker in format.markers) {
      if (at + marker.length > content.length) continue;
      var same = true;
      for (var i = 0; i < marker.length && same; i++) {
        same = content[at + i] == marker.codeUnitAt(i);
      }
      if (same) return true;
    }
  }
  return false;
}

/// The header line that carries [signature] in a commit.
///
/// Git inserts it after every other header (`add_header_signature`), and a
/// [Commit] writes its extra headers last, so appending this to them puts it
/// in the same place. The value drops the signature's final newline, which the
/// header's own line ending supplies; blank lines inside the armour become
/// lines holding a single space, as they do in git.
HeaderLine commitSignatureLine(String signature) {
  final text = normaliseSignature(signature);
  return HeaderLine(
    commitSignatureHeader,
    text.endsWith('\n') ? text.substring(0, text.length - 1) : text,
  );
}

/// [signature] with CRs removed and a final newline, which is what git stores
/// whatever the signing program printed (`remove_cr_after`).
String normaliseSignature(String signature) {
  final text = signature.replaceAll('\r', '');
  return text.endsWith('\n') ? text : '$text\n';
}

// ---------------------------------------------------------------------------
// Reading what the programs said.

const _exclusive = {
  'GOODSIG ': SignatureStatus.good,
  'BADSIG ': SignatureStatus.bad,
  'ERRSIG ': SignatureStatus.cannotCheck,
  'EXPSIG ': SignatureStatus.expiredSignature,
  'EXPKEYSIG ': SignatureStatus.expiredKey,
  'REVKEYSIG ': SignatureStatus.revokedKey,
};

/// Reads gpg's (or gpgsm's) `--status-fd` output the way `parse_gpg_output`
/// does.
///
/// At most one of the verdict lines — GOODSIG, BADSIG, ERRSIG and the three
/// kinds of expiry and revocation — may appear. Two means more than one
/// signature was checked, and git refuses to pick one: the result is
/// [SignatureStatus.cannotCheck] with every detail cleared, so that nothing
/// from the other signature is reported as this one's.
SignatureCheck parseGpgStatus(
  String status, {
  required String output,
  required bool toolSucceeded,
  required Uint8List payload,
  String? signature,
  SignatureFormat format = SignatureFormat.openpgp,
}) {
  var result = SignatureStatus.none;
  var trust = TrustLevel.undefined;
  String? key, signer, fingerprint, primary;
  var seenExclusive = false;
  var failed = false;

  String lineRest(int from) {
    final end = status.indexOf('\n', from);
    return status.substring(from, end < 0 ? status.length : end);
  }

  var at = 0;
  while (!failed) {
    final found = status.indexOf('[GNUPG:] ', at);
    if (found < 0) break;
    final start = found + '[GNUPG:] '.length;
    final rest = lineRest(start);
    at = start;

    final verdict =
        _exclusive.keys.where((prefix) => rest.startsWith(prefix)).firstOrNull;
    if (verdict != null) {
      if (seenExclusive) {
        failed = true;
        break;
      }
      seenExclusive = true;
      result = _exclusive[verdict]!;
      final fields = rest.substring(verdict.length);
      final space = fields.indexOf(' ');
      key = space < 0 ? fields : fields.substring(0, space);
      // ERRSIG's later fields are algorithms and a timestamp, not a name.
      if (space >= 0 && result != SignatureStatus.cannotCheck) {
        signer = fields.substring(space + 1);
      }
    } else if (rest.startsWith('VALIDSIG ')) {
      final fields = rest.substring('VALIDSIG '.length).split(' ');
      fingerprint = fields.first;
      // The tenth field after the fingerprint is the primary key's, and only
      // OpenPGP has one; without it the key that signed is the primary.
      primary = fields.length > 10 ? fields[10] : fingerprint;
    } else if (rest.startsWith('TRUST_')) {
      final name = rest.substring('TRUST_'.length).split(' ').first;
      final level = TrustLevel.values
          .where((level) => level.name.toUpperCase() == name)
          .firstOrNull;
      if (level == null) {
        failed = true;
        break;
      }
      trust = level;
    }
  }

  if (failed) {
    result = SignatureStatus.cannotCheck;
    key = signer = fingerprint = primary = null;
  }

  return SignatureCheck(
    result: result,
    trustLevel: trust,
    toolSucceeded: toolSucceeded,
    format: format,
    signer: signer,
    key: key,
    fingerprint: fingerprint,
    primaryKeyFingerprint: primary,
    output: output,
    rawOutput: status,
    payload: payload,
    signature: signature,
  );
}

/// Reads `ssh-keygen -Y verify` / `-Y check-novalidate` output the way
/// `parse_ssh_output` does.
///
/// ```text
/// Good "git" signature for PRINCIPAL with ED25519 key SHA256:FINGERPRINT
/// Good "git" signature with ED25519 key SHA256:FINGERPRINT
/// ```
///
/// The first is a signature from an allowed signer, fully trusted; the second
/// is a correct signature from a key nobody listed, which is why it is good
/// with undefined trust — `U`, not `G`. A principal may contain spaces, so it
/// runs up to the *last* " with ". Anything else is a bad signature.
SignatureCheck parseSshOutput(
  String output, {
  required bool toolSucceeded,
  required Uint8List payload,
  String? signature,
}) {
  var result = SignatureStatus.bad;
  var trust = TrustLevel.never;
  String? signer, key;

  final newline = output.indexOf('\n');
  final line = newline < 0 ? output : output.substring(0, newline);
  const known = 'Good "git" signature for ';
  const unknown = 'Good "git" signature with ';

  String? rest;
  if (line.startsWith(known)) {
    final text = line.substring(known.length);
    final lastWith = text.lastIndexOf(' with ');
    if (lastWith > 0) {
      result = SignatureStatus.good;
      trust = TrustLevel.fully;
      signer = text.substring(0, lastWith);
      rest = text.substring(lastWith + 1);
    }
  } else if (line.startsWith(unknown)) {
    result = SignatureStatus.good;
    trust = TrustLevel.undefined;
    rest = line.substring(unknown.length);
  }

  if (rest != null) {
    final keyAt = rest.indexOf('key ');
    if (keyAt >= 0) {
      key = rest.substring(keyAt + 4);
    } else {
      result = SignatureStatus.bad;
    }
  }

  return SignatureCheck(
    result: result,
    trustLevel: trust,
    toolSucceeded: toolSucceeded,
    format: SignatureFormat.ssh,
    signer: signer,
    key: key,
    fingerprint: key,
    output: output,
    rawOutput: output,
    payload: payload,
    signature: signature,
  );
}

/// Git's `strbuf_stripspace`: trailing whitespace off every line, runs of
/// blank lines squeezed to one, none at either end, and a final newline.
String stripSpace(String text) {
  final lines = const LineSplitter()
      .convert(text)
      .map((line) => line.trimRight())
      .toList();
  final out = StringBuffer();
  var pendingBlank = false;
  for (final line in lines) {
    if (line.isEmpty) {
      pendingBlank = out.isNotEmpty;
      continue;
    }
    if (pendingBlank) out.write('\n');
    pendingBlank = false;
    out
      ..write(line)
      ..write('\n');
  }
  return out.toString();
}

class _NoSignatureTool implements SignatureTool {
  const _NoSignatureTool();

  @override
  String sign(Uint8List payload, SigningRequest request) =>
      throw UnsupportedError(
        'this repository is open for inspection, so nothing is signed here',
      );

  @override
  SignatureCheck verify(
    Uint8List payload,
    String signature,
    VerificationRequest request,
  ) =>
      SignatureCheck(
        result: SignatureStatus.cannotCheck,
        payload: payload,
        signature: signature,
        output: 'not checked: this repository is open for inspection, and '
            'checking a signature means running a program',
      );
}
