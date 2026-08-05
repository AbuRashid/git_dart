import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:unimsg/unimsg.dart';

void main(List<String> arguments) {
  try {
    _run(arguments);
  } on UnimsgException catch (error) {
    stderr.writeln('unimsg: $error');
    exitCode = 1;
  } on FormatException catch (error) {
    stderr.writeln('unimsg: ${error.message}');
    exitCode = 1;
  } on FileSystemException catch (error) {
    stderr.writeln(
        'unimsg: ${error.message}${error.path == null ? '' : ': ${error.path}'}');
    exitCode = 1;
  } on ArgumentError catch (error) {
    stderr.writeln('unimsg: ${error.message}');
    exitCode = 2;
  }
}

void _run(List<String> arguments) {
  final args = List<String>.from(arguments);
  final command = args.isEmpty ? 'help' : args.removeAt(0);
  String? input;
  String? output;
  var check = false;
  while (args.isNotEmpty) {
    final arg = args.removeAt(0);
    if (arg == '-o' || arg == '--output') {
      if (args.isEmpty) throw ArgumentError('--output needs a file path');
      output = args.removeAt(0);
    } else if (arg == '--check') {
      check = true;
    } else if (arg == '-h' || arg == '--help') {
      _help();
      return;
    } else if (input == null) {
      input = arg;
    } else {
      throw ArgumentError('unexpected argument "$arg"');
    }
  }
  switch (command) {
    case 'encode':
      _write(output, textToCbor(_readText(input)));
    case 'decode':
      _write(output,
          Uint8List.fromList(utf8.encode(cborToText(_readBytes(input)))));
    case 'format' || 'fmt':
      final source = _readText(input);
      final formatted = formatDocument(parse(source));
      if (check) {
        if (source != formatted)
          throw const FormatException('input is not canonically formatted');
      } else {
        _write(output, Uint8List.fromList(utf8.encode(formatted)));
      }
    case 'check':
      final document = parse(_readText(input));
      final first = encode(document.value);
      final second = encode(decode(first));
      if (!_equal(first, second))
        throw const FormatException('internal round-trip check failed');
      stderr.writeln(
          'valid unimsg v0 (${first.length} deterministic CBOR bytes)');
    case 'help':
      _help();
    default:
      throw ArgumentError(
          'unknown command "$command"; run `dart run unimsg help`');
  }
}

String _readText(String? path) => path == null
    ? utf8.decode(_readBytes(null))
    : File(path).readAsStringSync();
Uint8List _readBytes(String? path) {
  if (path != null) return File(path).readAsBytesSync();
  final builder = BytesBuilder(copy: false);
  while (true) {
    final chunk = stdin.readByteSync();
    if (chunk < 0) break;
    builder.addByte(chunk);
  }
  return builder.takeBytes();
}

void _write(String? path, List<int> bytes) {
  if (path == null) {
    stdout.add(bytes);
  } else {
    File(path).writeAsBytesSync(bytes);
  }
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void _help() =>
    stdout.writeln('''unimsg v0 pure Dart parser and deterministic CBOR codec

USAGE:
  dart run unimsg encode [FILE] [-o FILE]
  dart run unimsg decode [FILE] [-o FILE]
  dart run unimsg format [FILE] [-o FILE] [--check]
  dart run unimsg check  [FILE]

Omit FILE to read standard input. Binary encode/decode use raw CBOR.''');
