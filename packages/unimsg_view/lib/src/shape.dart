// What a document is shaped like, decided from structure alone.
//
// Nothing here reads a key's meaning. Every test below is over type, shape or
// arithmetic, and would reach the same answer for a document about anything
// else with the same form. That is the whole discipline: a treatment chosen
// from what a value *means* is a guess that fails silently on the next
// document, and there is always a next document.
//
// No Flutter in this file. The decisions are about documents, not about
// widgets, and keeping them apart is what lets them be tested as decisions.

import 'package:unimsg/unimsg.dart' as u;

/// How a value should be presented.
///
/// Ordered by how much each claims: [fields] claims nothing beyond "this is a
/// map", and every other treatment has to earn its place against it.
enum Treatment {
  /// A run of key and value rows. The default, and what everything falls back
  /// to when no stronger shape is confirmed.
  fields,

  /// A map whose values are all maps: a keyed collection, where each entry is
  /// a thing of the same kind. Drawn as cards.
  entries,

  /// The same, nested deep and narrow. Cards inside cards inside cards stop
  /// being readable at about the third level; an indented outline does not.
  outline,

  /// A sequence of maps with identical key sets — which is what a `| row`
  /// table encodes to, and what a longhand sequence of uniform maps is too.
  table,

  /// A map whose values are all text, at least one of them long: terms and
  /// their definitions.
  glossary,

  /// A map whose values are all plain scalars: a compact aligned list.
  settings,

  /// A map whose values are all non-negative numbers: comparable magnitudes,
  /// drawn as bars.
  breakdown,

  /// A sequence holding no collections: a set of small values.
  chips,

  /// Text long enough to be read rather than glanced at.
  prose,

  /// Anything else — one value, drawn inline.
  scalar,
}

/// Text at or beyond this many characters is read, not glanced at.
///
/// The number is a typographic judgement rather than a discovered constant:
/// it is about the width of a column of prose, which is where a value stops
/// fitting beside its key and has to go under it.
const int longText = 80;

/// Strips annotations to reach the value they qualify.
u.UValue bare(u.UValue value) =>
    value is u.UAnnotated ? bare(value.value) : value;

/// The annotation names on a value, in the order they were written.
List<u.Annotation> annotationsOf(u.UValue value) =>
    value is u.UAnnotated ? value.annotations : const [];

/// Whether this is a number of any of the three spellings.
bool isNumber(u.UValue value) {
  final v = bare(value);
  return v is u.UInt || v is u.UFloat || v is u.UDecimal;
}

/// A number as a double, for comparing magnitudes. Null when it is not one.
double? asNumber(u.UValue value) {
  final v = bare(value);
  if (v is u.UInt) return v.value.toDouble();
  if (v is u.UFloat) return v.value;
  if (v is u.UDecimal) {
    return v.mantissa.toDouble() * _pow10(v.exponent.toInt());
  }
  return null;
}

double _pow10(int exponent) {
  var result = 1.0;
  for (var i = 0; i < exponent.abs(); i++) {
    result *= 10;
  }
  return exponent < 0 ? 1 / result : result;
}

/// Whether this value sits on a line rather than opening a block: everything
/// but a map, a sequence, an extension, and text long enough to be prose.
bool isInline(u.UValue value) {
  final v = bare(value);
  if (v is u.UMap || v is u.USeq || v is u.UExtension) return false;
  if (v is u.UText) return v.value.length < longText;
  return true;
}

/// The columns of a table, if [values] is one.
///
/// A table is a sequence of maps that all carry the same keys in the same
/// order. That is exactly what the `| row` form encodes to, and a longhand
/// sequence with the same property is the same thing written out — the format
/// says so, so a reader that treated them differently would be disagreeing
/// with the format about what it had just read.
List<String>? tableColumns(List<u.UValue> values) {
  if (values.length < 2) return null;
  List<String>? columns;
  for (final value in values) {
    final map = bare(value);
    if (map is! u.UMap || map.entries.isEmpty) return null;
    final keys = [for (final entry in map.entries) entry.key];
    if (columns == null) {
      columns = keys;
    } else if (!_sameKeys(columns, keys)) {
      return null;
    }
  }
  return columns;
}

bool _sameKeys(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// How deep a map of maps goes, and how wide it is at its widest.
///
/// Used to tell a collection of things apart from an outline: both are maps
/// of maps, and what separates them is that one is a list of siblings and the
/// other is a hierarchy.
({int depth, int widest}) _nesting(u.UMap map) {
  var depth = 0;
  var widest = 0;

  void walk(u.UMap node, int level) {
    if (level > depth) depth = level;
    if (node.entries.length > widest) widest = node.entries.length;
    for (final entry in node.entries) {
      final value = bare(entry.value);
      if (value is u.UMap && value.entries.isNotEmpty) walk(value, level + 1);
    }
  }

  walk(map, 1);
  return (depth: depth, widest: widest);
}

/// Which treatment [value] has earned.
///
/// Tried in order of how much each claims. The first that is confirmed wins,
/// and [Treatment.fields] catches everything that confirms nothing.
Treatment treatmentOf(u.UValue value) {
  final v = bare(value);

  if (v is u.UText) {
    return v.value.length >= longText ? Treatment.prose : Treatment.scalar;
  }

  if (v is u.USeq) {
    if (tableColumns(v.values) != null) return Treatment.table;
    if (v.values.isEmpty) return Treatment.chips;
    if (v.values.every(isInline)) return Treatment.chips;
    return Treatment.fields;
  }

  if (v is! u.UMap) return Treatment.scalar;
  if (v.entries.length < 2) return Treatment.fields;

  final values = [for (final entry in v.entries) bare(entry.value)];

  if (values.every((each) => each is u.UMap && each.entries.isNotEmpty)) {
    final shape = _nesting(v);
    // Deep and narrow is a hierarchy; shallow or wide is a collection of
    // siblings. Cards nest to about three levels before the borders are
    // carrying more of the page than the content is.
    return shape.depth >= 3 && shape.widest <= 4
        ? Treatment.outline
        : Treatment.entries;
  }

  if (values.every((each) => each is u.UText)) {
    final texts = values.cast<u.UText>();
    // A definition is long enough to be a sentence. A map of short strings is
    // a set of settings that happen to be spelled with quotes, and drawing it
    // as a glossary gives every one of them a paragraph of its own.
    return texts.any((each) => each.value.length >= longText)
        ? Treatment.glossary
        : Treatment.settings;
  }

  // Three is the fewest that can show a pattern; two bars are a comparison a
  // reader makes faster from the numbers themselves. Negative magnitudes have
  // no length, and a bar drawn for one would be a lie about its size.
  if (v.entries.length >= 3 && values.every(isNumber)) {
    final numbers = [for (final each in values) asNumber(each)!];
    if (numbers.every((each) => each >= 0) && numbers.any((each) => each > 0)) {
      return Treatment.breakdown;
    }
  }

  if (values.every(isInline)) return Treatment.settings;

  return Treatment.fields;
}

/// A document with its envelope opened.
///
/// A root holding one pair whose value is a map is a wrapper: the document is
/// what is inside it. Rendering the wrapper as the only section gives a page
/// with no hierarchy and one heading, which is the shape of every document in
/// this repository. Unwrapping reads the shape of the root and nothing about
/// what its key means.
class DocumentShape {
  /// The name the envelope was written under, or null when there was none.
  final String? envelope;

  /// The annotations on the envelope, which is where a document usually
  /// declares its own identifier.
  final List<u.Annotation> envelopeAnnotations;

  /// The comment block at the top of the file, which is the document's own
  /// statement of what it is. Comment lines, as [readNote] wants them.
  final List<String> preamble;

  /// The pairs that become the page's sections.
  final List<u.MapEntry> sections;

  /// `%unimsg 0 label`, as written, or null for a document with no header.
  final String? header;

  const DocumentShape({
    required this.envelope,
    required this.envelopeAnnotations,
    required this.preamble,
    required this.sections,
    required this.header,
  });

  /// Reads [document]. [source] is the text it was parsed from, and is needed
  /// only for the preamble — see [leadingComments].
  factory DocumentShape.of(u.UnimsgDocument document, {String? source}) {
    final root = bare(document.value);
    var sections = root is u.UMap ? root.entries : <u.MapEntry>[];
    String? envelope;
    var annotations = const <u.Annotation>[];
    var preamble = const <String>[];

    if (sections.length == 1) {
      final only = sections.first;
      final inner = bare(only.value);
      if (inner is u.UMap && inner.entries.isNotEmpty) {
        envelope = only.key;
        annotations = annotationsOf(only.value);
        // Whatever preceded the envelope preceded the whole document.
        preamble = only.comments;
        sections = inner.entries;
      }
    }

    if (preamble.isEmpty && source != null) {
      // Nothing in the tree claimed the top of the file. Without an envelope
      // the leading block belongs to the first section and renders there, so
      // it is only unclaimed when that section has no comments either.
      final claimed = envelope == null &&
          sections.isNotEmpty &&
          sections.first.comments.isNotEmpty;
      if (!claimed) preamble = leadingComments(source);
    }

    final head = document.header;
    return DocumentShape(
      envelope: envelope,
      envelopeAnnotations: annotations,
      preamble: preamble,
      sections: sections,
      header: head == null
          ? null
          : '%unimsg ${head.version}'
              '${head.label == null ? '' : ' ${head.label}'}',
    );
  }
}

/// The comment lines at the top of [source], before any pair.
///
/// Read from the text rather than from the tree, because the Dart parser
/// drops them: `_separators()` counts a comment as a separator, so the call
/// that skips past the header consumes the whole preamble before the pair
/// loop can collect it. The JavaScript implementation keeps them, attached to
/// the first pair, and that is the reading this follows.
///
/// [DocumentShape] asks the tree first and only falls back here, so this stops
/// being reached the day the parser is fixed rather than doubling up with it.
///
/// The result matches what that parser would have produced: `--` and one
/// following space removed, trailing space trimmed, and blank source lines
/// dropped — a paragraph break in a comment block is written as a bare `--`,
/// which survives as an empty line, and that is the break [readNote] reads.
List<String> leadingComments(String source) {
  final comments = <String>[];
  for (final raw in source.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('%')) {
      // The header, which is not part of the preamble and cannot follow it.
      if (comments.isEmpty) continue;
      break;
    }
    if (!line.startsWith('--')) break;
    var text = line.substring(2);
    if (text.startsWith(' ')) text = text.substring(1);
    comments.add(text.trimRight());
  }
  while (comments.isNotEmpty && comments.last.isEmpty) {
    comments.removeLast();
  }
  return comments;
}

/// Where a name in this document can be reached.
///
/// Two kinds, and the format says which is which: a name with a dot in it is
/// a path from the root, each segment a map key; a name without one is an
/// identifier, declared with `@` somewhere. Both are collected here, and
/// resolving is a separate act from reading — a reference that resolves to
/// nothing is inert rather than broken, because the document it points into
/// may simply not be open.
class Anchors {
  final Map<String, String> _byName = {};
  final Set<String> _targets = {};

  /// Records that [name] can be reached at [target].
  ///
  /// The first claim on a name wins. A later one is a second place the same
  /// name appears, and sending a reader to the second occurrence of something
  /// rather than its definition is worse than sending them nowhere.
  void declare(String name, String target) {
    _byName.putIfAbsent(name, () => target);
    _targets.add(target);
  }

  /// Whether [path] is somewhere a reference could land.
  ///
  /// Asked before a widget is given a key to be found by, so that a document
  /// of four hundred fields costs four hundred keys only if four hundred of
  /// them are pointed at.
  bool isTarget(String path) => _targets.contains(path);

  /// Where [name] leads, or null when nothing in this document declares it.
  ///
  /// A dotted name is tried whole first, then by its last segment: a document
  /// addressed with its envelope and one addressed without it name the same
  /// place, and a reader should not have to know which spelling the author
  /// used.
  String? resolve(String name) =>
      _byName[name] ??
      (name.contains('.') ? _byName[name.split('.').last] : null);

  bool get isEmpty => _byName.isEmpty;
  Iterable<String> get names => _byName.keys;
}

/// Walks [shape] and collects every name a reference could reach.
///
/// A keyed collection defines its keys: a map holding `bishop`, `rook` and
/// `king` defines those three words for the rest of the document. An
/// identifier annotation declares a name outright. Both are read here by
/// position and spelling, and neither is read for meaning.
Anchors anchorsOf(DocumentShape shape) {
  final anchors = Anchors();

  void walk(u.MapEntry entry, String path) {
    final here = path.isEmpty ? entry.key : '$path.${entry.key}';
    anchors.declare(here, here);
    // The last segment, so that `syntax-colour` reaches
    // `presentation.syntax-colour` — the spelling authors actually use when
    // the name is unambiguous.
    anchors.declare(entry.key, here);
    for (final annotation in annotationsOf(entry.value)) {
      if (annotation is u.IdentifierAnnotation) {
        anchors.declare(annotation.name, here);
      }
    }
    final value = bare(entry.value);
    if (value is u.UMap) {
      for (final child in value.entries) {
        walk(child, here);
      }
    }
  }

  for (final section in shape.sections) {
    walk(section, '');
  }
  return anchors;
}
