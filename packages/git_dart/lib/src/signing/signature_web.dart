/// Signing in a browser, which has no gpg and no ssh-keygen to run.
///
/// The same name as `signature_io.dart`, so code that mentions
/// [ProcessSignatureTool] compiles for the web; using it fails with an error
/// that says what to do instead.
library;

import 'dart:typed_data';

import 'signature.dart';

SignatureTool get platformSignatureTool => const ProcessSignatureTool();

Never _unavailable() => throw UnsupportedError(
      'signing and verifying run gpg or ssh-keygen, which needs dart:io and '
      'a browser does not have; set Repository.signatureTool to an '
      'in-process SignatureTool instead',
    );

class ProcessSignatureTool extends SignatureTool {
  final Map<String, String>? environment;

  const ProcessSignatureTool({this.environment});

  @override
  String sign(Uint8List payload, SigningRequest request) => _unavailable();

  @override
  SignatureCheck verify(
    Uint8List payload,
    String signature,
    VerificationRequest request,
  ) =>
      _unavailable();
}
