/// Emits lib/src/generated/tokens.dart from explorer.umsg.
///
///   dart run tool/generate_tokens.dart          # write
///   dart run tool/generate_tokens.dart --check  # fail if stale
///
/// The check mode is the part that matters. Without it the document is a
/// suggestion, and the first hand edit to the generated file leaves the two
/// silently disagreeing (`pattern.why-step-3`, `pattern.why-step-4`).
///
/// This tool knows one vocabulary — this document's — and refuses anything
/// else, rather than rendering half of it. That is the domain-specific side
/// of `tooling.kinds`; a tool that half-knew the vocabulary would produce
/// plausible tokens from a document it did not understand.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:unimsg/unimsg.dart';

const _specification = 'specs/explorer.umsg';
const _output = 'lib/src/generated/tokens.dart';

/// Renders the tokens from the text of explorer.umsg.
///
/// Separated from [main] so that a test can check the artefact against the
/// document without starting a second Dart process — which deadlocks against
/// the test runner's own package lock, and did.
String renderTokens(String specificationSource) {
  final document = parse(specificationSource);
  final spec = _lookup(document.value, ['gitexplorer']);
  if (spec == null) {
    _fail('$_specification has no `gitexplorer` block; this is not the '
        'document this tool generates from');
  }
  return _render(spec);
}

/// Where the specification and the generated file are, from anywhere in the
/// repository.
({File specification, File output}) locate() {
  final root = _repositoryRoot();
  return (
    specification: File(p.join(root, _specification)),
    output: File(p.join(root, 'apps', 'gitexplorer', _output)),
  );
}

void main(List<String> arguments) {
  final check = arguments.contains('--check');

  final source = File(p.join(_repositoryRoot(), _specification));
  if (!source.existsSync()) {
    _fail('cannot find $_specification; expected it at ${source.path}');
  }

  final generated = renderTokens(source.readAsStringSync());
  final target = File(p.join(Directory.current.path, _output));

  if (check) {
    if (!target.existsSync()) {
      _fail('$_output does not exist; run this tool without --check');
    }
    if (target.readAsStringSync() != generated) {
      _fail('$_output is stale: it does not match $_specification.\n'
          'Run: dart run tool/generate_tokens.dart');
    }
    stdout.writeln('$_output is up to date with $_specification');
    return;
  }

  target.parent.createSync(recursive: true);
  target.writeAsStringSync(generated);
  stdout.writeln('wrote $_output from $_specification');
}

// ---------------------------------------------------------------------------
// rendering
// ---------------------------------------------------------------------------

String _render(UValue spec) {
  final states = _rows(spec, ['status-vocabulary']);
  final kinds = _rows(spec, ['entry-kinds']);
  final revisions = _rows(spec, ['revisions', 'choices']);
  final unavailable = _rows(spec, ['initialising', 'unavailable-reasons']);
  final themes = _rows(spec, ['presentation', 'theme-choices']);
  final persistenceVersion = _int(spec, ['persistence', 'version']);

  final out = StringBuffer()
    ..writeln('// GENERATED FILE — DO NOT EDIT.')
    ..writeln('//')
    ..writeln('// Written by tool/generate_tokens.dart from $_specification.')
    ..writeln('// Edit that document and re-run the tool; the build checks')
    ..writeln('// this file against it.')
    ..writeln('//')
    ..writeln('// Vocabulary only. Colours, sizes and type come from Material,')
    ..writeln('// not from here (`presentation.doc`).')
    ..writeln('');

  // ---- entry kinds ----
  out
    ..writeln('/// What a row in the tree is (`entry-kinds`).')
    ..writeln('enum EntryKind {');
  for (var i = 0; i < kinds.length; i++) {
    final row = kinds[i];
    final last = i == kinds.length - 1;
    out
      ..writeln('  /// ${_cell(row, 'is')}')
      ..writeln('  ${_camel(_cell(row, 'kind'))}(expands: '
          '${_cell(row, 'expands')})${last ? ';' : ','}');
  }
  out
    ..writeln('')
    ..writeln('  const EntryKind({required this.expands});')
    ..writeln('')
    ..writeln('  /// Whether the row can be opened to reveal children.')
    ..writeln('  final bool expands;')
    ..writeln('}')
    ..writeln('');

  // ---- file states ----
  out
    ..writeln('/// A path\'s state (`status-vocabulary`).')
    ..writeln('enum FileState {');
  for (var i = 0; i < states.length; i++) {
    final row = states[i];
    final last = i == states.length - 1;
    out
      ..writeln('  /// ${_cell(row, 'meaning')}')
      ..writeln("  ${_camel(_cell(row, 'state'))}("
          "code: '${_cell(row, 'code')}', "
          'shown: ${_cell(row, 'shown')})${last ? ';' : ','}');
  }
  out
    ..writeln('')
    ..writeln('  const FileState({required this.code, required this.shown});')
    ..writeln('')
    ..writeln('  /// The letter shown in the status column.')
    ..writeln('  final String code;')
    ..writeln('')
    ..writeln('  /// Whether a row in this state is marked at all.')
    ..writeln('  final bool shown;')
    ..writeln('}')
    ..writeln('');

  // ---- revisions ----
  out
    ..writeln('/// What a repository is being viewed at (`revisions.choices`).')
    ..writeln('enum RevisionKind {');
  for (var i = 0; i < revisions.length; i++) {
    final row = revisions[i];
    final last = i == revisions.length - 1;
    out
      ..writeln('  /// ${_cell(row, 'shows')}')
      ..writeln('  ${_camel(_cell(row, 'choice'))}(hasStatus: '
          "${_cell(row, 'status-column')}, "
          "editable: ${_cell(row, 'editable')})${last ? ';' : ','}");
  }
  out
    ..writeln('')
    ..writeln('  const RevisionKind({')
    ..writeln('    required this.hasStatus,')
    ..writeln('    required this.editable,')
    ..writeln('  });')
    ..writeln('')
    ..writeln('  /// Only the working tree is compared with anything, so only')
    ..writeln('  /// it has a status column.')
    ..writeln('  final bool hasStatus;')
    ..writeln('')
    ..writeln('  /// Only the working tree can be edited: the others are views')
    ..writeln('  /// of objects, and an object cannot be edited.')
    ..writeln('  final bool editable;')
    ..writeln('}')
    ..writeln('');

  // ---- theme ----
  out
    ..writeln('/// Which scheme the window uses')
    ..writeln('/// (`presentation.theme-choices`).')
    ..writeln('enum ThemeChoice {');
  for (var i = 0; i < themes.length; i++) {
    final row = themes[i];
    final last = i == themes.length - 1;
    out
      ..writeln('  /// ${_cell(row, 'follows')}')
      ..writeln('  ${_camel(_cell(row, 'choice'))}${last ? ';' : ','}');
  }
  out
    ..writeln('}')
    ..writeln('');

  // ---- why a repository could not be opened ----
  out
    ..writeln('/// Why a chosen folder could not be opened')
    ..writeln('/// (`initialising.unavailable-reasons`).')
    ..writeln('enum UnavailableReason {');
  for (var i = 0; i < unavailable.length; i++) {
    final row = unavailable[i];
    final last = i == unavailable.length - 1;
    out.writeln(
      "  ${_camel(_cell(row, 'reason'))}("
      "says: '${_cell(row, 'says')}', "
      "offersInitialising: ${_cell(row, 'offers-initialising')})"
      '${last ? ';' : ','}',
    );
  }
  out
    ..writeln('')
    ..writeln('  const UnavailableReason({')
    ..writeln('    required this.says,')
    ..writeln('    required this.offersInitialising,')
    ..writeln('  });')
    ..writeln('')
    ..writeln('  /// What to tell the user.')
    ..writeln('  final String says;')
    ..writeln('')
    ..writeln('  /// Whether creating a repository here is offered.')
    ..writeln('  final bool offersInitialising;')
    ..writeln('}')
    ..writeln('');

  // ---- persistence ----
  out
    ..writeln('/// The version written into the persisted repository list')
    ..writeln('/// (`persistence.version`).')
    ..writeln('const int persistedStateVersion = $persistenceVersion;');

  return out.toString();
}
// ---------------------------------------------------------------------------
// reading the document
// ---------------------------------------------------------------------------

/// The rows of a table, each as a map from header name to its cell's text.
List<Map<String, String>> _rows(UValue spec, List<String> path) {
  final value = _lookup(spec, path);
  if (value is! USeq) {
    _fail('$_specification: ${path.join('.')} is not a table');
  }
  return [
    for (final row in value.values)
      if (row is UMap)
        {for (final entry in row.entries) entry.key: _text(entry.value)}
      else
        _fail('$_specification: ${path.join('.')} has a row that is not a map'),
  ];
}

String _cell(Map<String, String> row, String column) {
  final value = row[column];
  if (value == null) {
    _fail('$_specification: a row is missing the "$column" column; '
        'it has ${row.keys.toList()}');
  }
  return value;
}

int _int(UValue spec, List<String> path) {
  final value = _unwrap(_lookup(spec, path));
  if (value is UInt) return value.value.toInt();
  _fail('$_specification: ${path.join('.')} is not an integer');
}

UValue? _lookup(UValue root, List<String> path) {
  var current = _unwrap(root);
  for (final key in path) {
    if (current is! UMap) return null;
    final entry = current.entries.where((e) => e.key == key).firstOrNull;
    if (entry == null) return null;
    current = _unwrap(entry.value);
  }
  return current;
}

/// An annotated value is its value; the annotations are metadata for a reader,
/// not part of what was written.
UValue? _unwrap(UValue? value) =>
    value is UAnnotated ? _unwrap(value.value) : value;

/// A cell as text, whatever kind it was written as. A symbol's name, a
/// number's digits and a string's contents all render the same way here
/// because a generated Dart identifier does not care which was used.
String _text(UValue value) {
  final unwrapped = _unwrap(value);
  return switch (unwrapped) {
    UText(:final value) => value,
    USymbol(:final name) => name,
    UInt(:final value) => value.toString(),
    UBool(:final value) => value.toString(),
    UDecimal(:final mantissa) => mantissa.toString(),
    UFloat(:final value) => value.toString(),
    UNull() => '',
    _ => _fail('$_specification: a cell holds a value this tool cannot render '
        'as text: ${unwrapped.runtimeType}'),
  };
}

// ---------------------------------------------------------------------------

String _camel(String kebab) {
  final parts = kebab.split(RegExp('[-_ ]')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return kebab;
  return parts.first +
      parts.skip(1).map((p) => p[0].toUpperCase() + p.substring(1)).join();
}

/// Finds the repository root by walking up until the specification is beside
/// us, so the tool works from the app directory or from the root.
String _repositoryRoot() {
  var directory = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File(p.join(directory.path, _specification)).existsSync()) {
      return directory.path;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return Directory.current.path;
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}
