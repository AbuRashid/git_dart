part of '../unimsg.dart';

const int _formatBudget = 56;

String formatDocument(UnimsgDocument document) {
  if (valueDepth(document.value) > maxDepth) {
    throw UnimsgException('value nested deeper than $maxDepth', 1, 1);
  }
  final output = StringBuffer();
  final header = document.header;
  if (header != null) {
    output.write('%unimsg ${header.version}');
    if (header.label != null) output.write(' ${header.label}');
    output.write('\n');
  }
  if (document.value case UMap(:final entries)) {
    output.write(_renderEntries(entries, 0));
  } else {
    output.write(formatValue(document.value));
  }
  final result = output.toString();
  return result.endsWith('\n') ? result : '$result\n';
}

String formatValue(UValue value) {
  if (valueDepth(value) > maxDepth) {
    throw UnimsgException('value nested deeper than $maxDepth', 1, 1);
  }
  return _renderAt(value, 0);
}

String _renderAt(UValue value, int indent) {
  final single = _inline(value);
  if (single != null && indent + _width(single) <= _formatBudget) {
    return '${' ' * indent}$single';
  }
  final pad = ' ' * indent;
  switch (value) {
    case UMap(:final entries):
      if (entries.isEmpty) return '$pad{}';
      return '$pad{\n${_renderEntries(entries, indent + 2)}\n$pad}';
    case USeq(:final values):
      return _renderSequence(values, indent);
    case UAnnotated(:final annotations, :final value):
      final prefix = annotations.map(_formatAnnotation).join(' ');
      return _attachPrefix('$prefix ', _renderAt(value, indent), indent);
    case UExtension(:final name, :final value):
      return _attachPrefix('!$name ', _renderAt(value, indent), indent);
    case UTagged(:final tag, :final value):
      return _renderAt(
          UExtension('cbor/tag', USeq([UInt(tag), value])), indent);
    default:
      return '$pad${_scalar(value)}';
  }
}

String _renderEntries(List<MapEntry> entries, int indent) {
  final sorted = List<MapEntry>.from(entries);
  sorted.sort((a, b) {
    final aMulti = _inline(a.value) == null || a.comments.isNotEmpty;
    final bMulti = _inline(b.value) == null || b.comments.isNotEmpty;
    if (aMulti != bMulti) return aMulti ? 1 : -1;
    return a.key.compareTo(b.key);
  });
  final lines = <String>[];
  final pad = ' ' * indent;
  for (final entry in sorted) {
    for (final comment in entry.comments) {
      lines.add('$pad-- $comment');
    }
    final key = _formatKey(entry.key);
    final single = _inline(entry.value);
    if (single != null &&
        indent + _width(key) + 1 + _width(single) <= _formatBudget) {
      lines.add('$pad$key $single');
    } else {
      lines.add(_attachPrefix('$key ', _renderAt(entry.value, indent), indent));
    }
  }
  return lines.join('\n');
}

String _renderSequence(List<UValue> values, int indent) {
  final pad = ' ' * indent;
  if (values.isEmpty) return '$pad[]';
  final table = _renderTable(values, indent);
  if (table != null) return table;
  return '$pad[\n${values.map((value) => _renderAt(value, indent + 2)).join('\n')}\n$pad]';
}

String? _renderTable(List<UValue> values, int indent) {
  if (values.length < 2 || values.any((value) => value is! UMap)) return null;
  final maps = values.cast<UMap>().map((map) => map.entries).toList();
  final keys = maps.first.map((entry) => entry.key).toList()..sort();
  if (keys.any((key) => !_isBareKey(key))) return null;
  final rows = <List<String>>[];
  for (final map in maps) {
    if (map.length != keys.length) return null;
    final row = <String>[];
    for (var i = 0; i < keys.length; i++) {
      final key = keys[i];
      final matches = map.where((entry) => entry.key == key).toList();
      if (matches.length != 1 || matches.single.comments.isNotEmpty)
        return null;
      // A cell ending in an identifier annotates the cell after it, so the
      // row would read back one cell short and the table would not parse as
      // the value it was written from. Safe only in the last column, where
      // the newline ends the value.
      if (i + 1 != keys.length && _endsInIdentifier(matches.single.value))
        return null;
      final cell = _inline(matches.single.value);
      if (cell == null) return null;
      row.add(cell);
    }
    rows.add(row);
  }
  final widths = keys.map(_width).toList();
  for (final row in rows) {
    for (var i = 0; i < row.length; i++) {
      if (_width(row[i]) > widths[i]) widths[i] = _width(row[i]);
    }
  }
  final rowPad = ' ' * (indent + 2);
  String renderRow(List<String> cells) {
    final line = StringBuffer('$rowPad|');
    for (var i = 0; i < cells.length; i++) {
      line.write(' ${cells[i]}');
      if (i + 1 != cells.length)
        line.write(' ' * (widths[i] - _width(cells[i])));
    }
    return line.toString();
  }

  return [
    '${' ' * indent}[',
    renderRow(keys),
    ...rows.map(renderRow),
    '${' ' * indent}]',
  ].join('\n');
}

/// Whether a value renders with a trailing `@name`.
///
/// Table cells carry no separator, which works only while every cell is
/// self-delimiting — `usd 129.99` consumes exactly one qualifier and one
/// value. An identifier is the exception: `@name` before a value annotates it.
/// Envelopes rendering as `prefix VALUE` inherit the hazard from what they
/// wrap.
bool _endsInIdentifier(UValue value) => switch (value) {
      UIdentifier() => true,
      UAnnotated(:final value) => _endsInIdentifier(value),
      UExtension(:final value) => _endsInIdentifier(value),
      _ => false,
    };

String? _inline(UValue value) {
  late String output;
  switch (value) {
    case UMap(:final entries):
      if (entries.any((entry) => entry.comments.isNotEmpty)) return null;
      final sorted = List<MapEntry>.from(entries)
        ..sort((a, b) => a.key.compareTo(b.key));
      final fields = <String>[];
      for (final entry in sorted) {
        final item = _inline(entry.value);
        if (item == null) return null;
        fields.add('${_formatKey(entry.key)} $item');
      }
      output = fields.isEmpty ? '{}' : '{ ${fields.join(', ')} }';
    case USeq(:final values):
      final fields = <String>[];
      for (final value in values) {
        final item = _inline(value);
        if (item == null) return null;
        fields.add(item);
      }
      output = fields.isEmpty ? '[]' : '[ ${fields.join(', ')} ]';
    case UAnnotated(:final annotations, :final value):
      final item = _inline(value);
      if (item == null) return null;
      output = '${annotations.map(_formatAnnotation).join(' ')} $item';
    case UExtension(:final name, :final value):
      final item = _inline(value);
      if (item == null) return null;
      output = '!$name $item';
    case UTagged():
      return null;
    default:
      output = _scalar(value);
  }
  return _width(output) <= _formatBudget ? output : null;
}

String _scalar(UValue value) {
  switch (value) {
    case UNull():
      return 'null';
    case UBool(:final value):
      return value.toString();
    case UInt(:final value):
      return value.toString();
    case UDecimal(:final exponent, :final mantissa):
      return _decimal(exponent, mantissa);
    case UFloat(:final value):
      if (value.isNaN) return 'nan';
      if (value == double.infinity) return 'inf';
      if (value == double.negativeInfinity) return '-inf';
      var text = value.toString();
      if (!text.contains(RegExp(r'[.eE]'))) text = '$text.0';
      return '${text}f';
    case UBytes(:final value):
      return '~hex:${_hex(value)}';
    case UText(:final value):
      return _quote(value);
    case USymbol(:final name):
      return _isBareSymbol(name) ? ':$name' : ':${_quote(name)}';
    case UIdentifier(:final name):
      return '@$name';
    case UReference(:final name):
      return '-> @$name';
    case UHash(:final algorithm, :final digest):
      return '#$algorithm:${_hex(digest)}';
    case UTimestamp(:final text):
      return text;
    default:
      throw StateError('compound value sent to scalar renderer');
  }
}

String _decimal(BigInt exponent, BigInt mantissa) {
  if (exponent >= BigInt.zero || exponent < BigInt.from(-10000))
    return '${mantissa}e$exponent';
  final sign = mantissa < BigInt.zero ? '-' : '';
  final digits = mantissa.abs().toString();
  final places = (-exponent).toInt();
  if (places < digits.length) {
    final split = digits.length - places;
    return '$sign${digits.substring(0, split)}.${digits.substring(split)}';
  }
  return '${sign}0.${'0' * (places - digits.length)}$digits';
}

String _formatAnnotation(Annotation annotation) => switch (annotation) {
      SymbolAnnotation(:final name) => name,
      IdentifierAnnotation(:final name) => '@$name',
    };

String _formatKey(String key) => _isBareKey(key) ? key : _quote(key);
bool _isBareKey(String key) =>
    key.isNotEmpty &&
    !_reservedLiteral(key) &&
    key.runes.every((rune) => _isWordRune(String.fromCharCode(rune)));
bool _isBareSymbol(String name) => _isBareKey(name);

String _quote(String text) {
  final output = StringBuffer('"');
  for (final rune in text.runes) {
    final c = String.fromCharCode(rune);
    switch (c) {
      case '\n':
        output.write(r'\n');
      case '\t':
        output.write(r'\t');
      case '\r':
        output.write(r'\r');
      case '"':
        output.write(r'\"');
      case '\\':
        output.write(r'\\');
      default:
        output.write(c);
    }
  }
  output.write('"');
  return output.toString();
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
String _attachPrefix(String prefix, String rendered, int indent) {
  final pad = ' ' * indent;
  final rest =
      rendered.startsWith(pad) ? rendered.substring(pad.length) : rendered;
  return '$pad$prefix$rest';
}

int _width(String text) => text.runes.length;
