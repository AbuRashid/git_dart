part of '../unimsg.dart';

enum _TokenType {
  separator,
  comment,
  header,
  leftBrace,
  rightBrace,
  leftBracket,
  rightBracket,
  pipe,
  word,
  string,
  number,
  timestamp,
  symbol,
  identifier,
  reference,
  hash,
  bytes,
  extension,
  trueLiteral,
  falseLiteral,
  nullLiteral,
  nan,
  inf,
  negativeInf,
  eof,
}

final class _Token {
  final _TokenType type;
  final Object? value;
  final int line;
  final int column;
  const _Token(this.type, this.value, this.line, this.column);
}

final class _HashToken {
  final String algorithm;
  final Uint8List digest;
  const _HashToken(this.algorithm, this.digest);
}

UnimsgDocument parse(String source) => _Parser(_Lexer(source).lex()).document();

final class _Lexer {
  final String source;
  int offset = 0;
  int line = 1;
  int column = 1;
  bool firstToken = true;

  _Lexer(this.source);

  List<_Token> lex() {
    final output = <_Token>[];
    // U+FEFF is an optional encoding marker, not document content. Skip it
    // without advancing the reported first source column.
    if (source.startsWith('\ufeff')) offset = 1;
    while (offset < source.length) {
      final c = _peek()!;
      if (c == ' ' || c == '\t' || c == '\r') {
        _bump();
        continue;
      }
      final tokenLine = line;
      final tokenColumn = column;
      late _TokenType type;
      Object? value;
      if (c == '\n' || c == ',') {
        _bump();
        type = _TokenType.separator;
      } else if (c == '{') {
        _bump();
        type = _TokenType.leftBrace;
      } else if (c == '}') {
        _bump();
        type = _TokenType.rightBrace;
      } else if (c == '[') {
        _bump();
        type = _TokenType.leftBracket;
      } else if (c == ']') {
        _bump();
        type = _TokenType.rightBracket;
      } else if (c == '|') {
        _bump();
        type = _TokenType.pipe;
      } else if (c == '"') {
        type = _TokenType.string;
        value = _string();
      } else if (c == '%') {
        type = _TokenType.header;
        value = _header(tokenLine, tokenColumn);
      } else if (_startsWith('--')) {
        type = _TokenType.comment;
        value = _comment();
      } else if (_startsWith('->')) {
        type = _TokenType.reference;
        value = _reference(tokenLine, tokenColumn);
      } else if (c == '@') {
        type = _TokenType.identifier;
        value = _sigilPayload('@', false, tokenLine, tokenColumn);
      } else if (c == ':') {
        type = _TokenType.symbol;
        final quoted = offset + 1 < source.length && source[offset + 1] == '"';
        if (quoted) {
          _bump();
          value = _string();
        } else {
          value = _sigilPayload(':', false, tokenLine, tokenColumn);
          if (_reservedLiteral(value as String)) {
            throw UnimsgException(
              '":$value" is a symbol named "$value", not the literal — write $value',
              tokenLine,
              tokenColumn,
            );
          }
        }
      } else if (c == '!') {
        type = _TokenType.extension;
        value = _sigilPayload('!', false, tokenLine, tokenColumn);
      } else if (c == '#') {
        type = _TokenType.hash;
        value = _hash(tokenLine, tokenColumn);
      } else if (c == '~') {
        type = _TokenType.bytes;
        value = _bytes(tokenLine, tokenColumn);
      } else if ('&\$^*?\\'.contains(c)) {
        throw UnimsgException('reserved sigil "$c"', tokenLine, tokenColumn);
      } else if (_startsWith('-inf') && _boundaryAfter(4)) {
        _bumpBytes(4);
        type = _TokenType.negativeInf;
      } else if (_isAsciiDigit(c)) {
        final timestamp = _timestampPrefix(source.substring(offset));
        if (timestamp != null) {
          type = _TokenType.timestamp;
          value = source.substring(offset, offset + timestamp);
          _bumpBytes(timestamp);
        } else {
          type = _TokenType.number;
          value = _number(tokenLine, tokenColumn);
        }
      } else if (c == '-' && _nextIsDigit()) {
        type = _TokenType.number;
        value = _number(tokenLine, tokenColumn);
      } else if (_isWordRune(c)) {
        final word = _word();
        switch (word) {
          case 'true':
            type = _TokenType.trueLiteral;
          case 'false':
            type = _TokenType.falseLiteral;
          case 'null':
            type = _TokenType.nullLiteral;
          case 'nan':
            type = _TokenType.nan;
          case 'inf':
            type = _TokenType.inf;
          default:
            type = _TokenType.word;
            value = word;
        }
      } else {
        throw UnimsgException(
            'unexpected character ${jsonEncode(c)}', tokenLine, tokenColumn);
      }
      firstToken = false;
      output.add(_Token(type, value, tokenLine, tokenColumn));
    }
    output.add(_Token(_TokenType.eof, null, line, column));
    return output;
  }

  String? _peek() {
    if (offset >= source.length) return null;
    final rune = _runeAt(source, offset);
    return String.fromCharCode(rune);
  }

  String? _bump() {
    final c = _peek();
    if (c == null) return null;
    offset += c.length;
    if (c == '\n') {
      line++;
      column = 1;
    } else {
      column++;
    }
    return c;
  }

  void _bumpBytes(int count) {
    final end = offset + count;
    while (offset < end) {
      _bump();
    }
  }

  bool _startsWith(String text) => source.startsWith(text, offset);
  bool _nextIsDigit() =>
      offset + 1 < source.length && _isAsciiDigit(source[offset + 1]);
  bool _boundaryAfter(int count) =>
      offset + count >= source.length ||
      _isBoundary(String.fromCharCode(_runeAt(source, offset + count)));

  String _string() {
    final startLine = line;
    final startColumn = column;
    _bump();
    final output = StringBuffer();
    while (true) {
      final c = _bump();
      if (c == null)
        throw UnimsgException('unterminated string', startLine, startColumn);
      if (c == '"') return output.toString();
      if (c != '\\') {
        output.write(c);
        continue;
      }
      final escaped = _bump();
      switch (escaped) {
        case 'n':
          output.write('\n');
        case 't':
          output.write('\t');
        case 'r':
          output.write('\r');
        case '"':
          output.write('"');
        case '\\':
          output.write('\\');
        case null:
          throw UnimsgException(
              'unterminated string escape', startLine, startColumn);
        default:
          throw UnimsgException(
              'unknown string escape \\$escaped', line, column - 2);
      }
    }
  }

  String _comment() {
    _bumpBytes(2);
    if (_peek() == ' ') _bump();
    final start = offset;
    while (_peek() != null && _peek() != '\n') {
      _bump();
    }
    return source.substring(start, offset).trimRight();
  }

  UnimsgHeader _header(int tokenLine, int tokenColumn) {
    if (!firstToken) {
      throw UnimsgException(
          'the %unimsg header is only valid at the start of a document',
          tokenLine,
          tokenColumn);
    }
    final start = offset;
    while (_peek() != null && _peek() != '\n') {
      _bump();
    }
    final fields = source.substring(start, offset).split(RegExp(r'[ \t]+'));
    if (fields.isEmpty || fields.first != '%unimsg') {
      throw UnimsgException('expected %unimsg header', tokenLine, tokenColumn);
    }
    if (fields.length < 2 ||
        int.tryParse(fields[1]) == null ||
        int.parse(fields[1]) < 0) {
      throw UnimsgException('header needs a non-negative integer version',
          tokenLine, tokenColumn);
    }
    if (fields.length > 3)
      throw UnimsgException(
          'header accepts at most one label', tokenLine, tokenColumn);
    return UnimsgHeader(
        int.parse(fields[1]), fields.length == 3 ? fields[2] : null);
  }

  String _sigilPayload(
      String sigil, bool expanded, int tokenLine, int tokenColumn) {
    _bump();
    final start = offset;
    while (true) {
      final c = _peek();
      if (c == null ||
          !(_isWordRune(c) || (expanded && (c == ':' || c == '=')))) break;
      _bump();
    }
    if (offset == start)
      throw UnimsgException(
          '$sigil must be followed by a name', tokenLine, tokenColumn);
    return source.substring(start, offset);
  }

  String _reference(int tokenLine, int tokenColumn) {
    _bumpBytes(2);
    while (_peek() == ' ' || _peek() == '\t') {
      _bump();
    }
    if (_peek() != '@')
      throw UnimsgException(
          'reference must be written -> @name', tokenLine, tokenColumn);
    return _sigilPayload('@', false, tokenLine, tokenColumn);
  }

  _HashToken _hash(int tokenLine, int tokenColumn) {
    final payload = _sigilPayload('#', true, tokenLine, tokenColumn);
    final colon = payload.indexOf(':');
    if (colon <= 0)
      throw UnimsgException(
          'hash must be written #algorithm:hex', tokenLine, tokenColumn);
    final digest = _decodeHex(payload.substring(colon + 1));
    if (digest == null)
      throw UnimsgException(
          'hash digest must contain an even number of hexadecimal digits',
          tokenLine,
          tokenColumn);
    return _HashToken(payload.substring(0, colon), digest);
  }

  Uint8List _bytes(int tokenLine, int tokenColumn) {
    final payload = _sigilPayload('~', true, tokenLine, tokenColumn);
    final colon = payload.indexOf(':');
    if (colon < 0)
      throw UnimsgException('bytes must be written ~hex:data or ~b64:data',
          tokenLine, tokenColumn);
    final encoding = payload.substring(0, colon);
    final data = payload.substring(colon + 1);
    if (encoding == 'hex') {
      final decoded = _decodeHex(data);
      if (decoded == null)
        throw UnimsgException(
            'hex bytes need an even number of hexadecimal digits',
            tokenLine,
            tokenColumn);
      return decoded;
    }
    if (encoding == 'b64') {
      try {
        return Uint8List.fromList(base64.decode(data));
      } on FormatException {
        throw UnimsgException(
            'invalid base64 byte string', tokenLine, tokenColumn);
      }
    }
    throw UnimsgException('unknown byte encoding "$encoding"; use hex or b64',
        tokenLine, tokenColumn);
  }

  String _word() {
    final start = offset;
    while (true) {
      final c = _peek();
      if (c == null || !_isWordRune(c)) break;
      _bump();
    }
    return source.substring(start, offset);
  }

  String _number(int tokenLine, int tokenColumn) {
    final start = offset;
    while (true) {
      final c = _peek();
      if (c == null || _isBoundary(c) || '{}[]|'.contains(c)) break;
      _bump();
    }
    final text = source.substring(start, offset);
    if (!_validNumber(text))
      throw UnimsgException(
          '"$text" is not a valid number or word', tokenLine, tokenColumn);
    return text;
  }
}

final class _Parser {
  final List<_Token> tokens;
  int index = 0;
  _Parser(this.tokens);

  UnimsgDocument document() {
    UnimsgHeader? header;
    if (_peek.type == _TokenType.header) {
      header = _next.value as UnimsgHeader;
    }
    _separators();
    final entries = _pairsUntil(false);
    if (_peek.type != _TokenType.eof) throw _error('expected end of document');
    return UnimsgDocument(header, UMap(entries));
  }

  List<MapEntry> _pairsUntil(bool brace) {
    final entries = <MapEntry>[];
    final comments = <String>[];
    while (true) {
      _separatorsAndComments(comments);
      if ((brace && _peek.type == _TokenType.rightBrace) ||
          _peek.type == _TokenType.eof) break;
      final keyToken = _next;
      if (keyToken.type != _TokenType.word &&
          keyToken.type != _TokenType.string) {
        throw UnimsgException('expected a map key (bare word or string)',
            keyToken.line, keyToken.column);
      }
      final key = keyToken.value as String;
      if (entries.any((entry) => entry.key == key))
        throw UnimsgException(
            'duplicate key "$key"', keyToken.line, keyToken.column);
      final value = _annotatedValue();
      entries.add(MapEntry(key, value, List.unmodifiable(comments)));
      comments.clear();
      if (!_isSeparator &&
          !(brace && _peek.type == _TokenType.rightBrace) &&
          _peek.type != _TokenType.eof) {
        throw _error('expected a newline or comma after the key-value pair');
      }
    }
    return entries;
  }

  UValue _annotatedValue() {
    final annotations = <Annotation>[];
    while (true) {
      if (_peek.type == _TokenType.word) {
        annotations.add(SymbolAnnotation(_next.value as String));
      } else if (_peek.type == _TokenType.identifier && !_nextIsBoundary) {
        annotations.add(IdentifierAnnotation(_next.value as String));
      } else {
        break;
      }
    }
    if (_isBoundary) {
      if (annotations.isEmpty) throw _error('expected a value');
      final name = annotations.last.name;
      throw _error('annotation "$name" has no value — did you mean ":$name"?');
    }
    final value = _value();
    return annotations.isEmpty ? value : UAnnotated(annotations, value);
  }

  UValue _value() {
    final token = _next;
    switch (token.type) {
      case _TokenType.leftBrace:
        final entries = _pairsUntil(true);
        _expect(_TokenType.rightBrace, "expected '}'");
        return UMap(entries);
      case _TokenType.leftBracket:
        return _sequenceOrTable();
      case _TokenType.string:
        return UText(token.value as String);
      case _TokenType.number:
        return _numberValue(token.value as String);
      case _TokenType.timestamp:
        return UTimestamp(token.value as String);
      case _TokenType.symbol:
        return USymbol(token.value as String);
      case _TokenType.identifier:
        return UIdentifier(token.value as String);
      case _TokenType.reference:
        return UReference(token.value as String);
      case _TokenType.hash:
        final hash = token.value as _HashToken;
        return UHash(hash.algorithm, hash.digest);
      case _TokenType.bytes:
        return UBytes(token.value as Uint8List);
      case _TokenType.extension:
        if (_isBoundary)
          throw UnimsgException('extension !${token.value} needs a value',
              token.line, token.column);
        return UExtension(token.value as String, _annotatedValue());
      case _TokenType.trueLiteral:
        return const UBool(true);
      case _TokenType.falseLiteral:
        return const UBool(false);
      case _TokenType.nullLiteral:
        return const UNull();
      case _TokenType.nan:
        return UFloat(double.nan);
      case _TokenType.inf:
        return UFloat(double.infinity);
      case _TokenType.negativeInf:
        return UFloat(double.negativeInfinity);
      default:
        throw UnimsgException('expected a value', token.line, token.column);
    }
  }

  UValue _sequenceOrTable() {
    _separators();
    if (_peek.type == _TokenType.pipe) return _table();
    final values = <UValue>[];
    while (_peek.type != _TokenType.rightBracket) {
      if (_peek.type == _TokenType.eof)
        throw _error("unterminated sequence; expected ']'");
      values.add(_annotatedValue());
      if (!_isSeparator && _peek.type != _TokenType.rightBracket)
        throw _error('expected a newline or comma between sequence values');
      _separators();
    }
    index++;
    return USeq(values);
  }

  UValue _table() {
    index++;
    final keys = <String>[];
    while (!_isSeparator) {
      final token = _next;
      if (token.type != _TokenType.word && token.type != _TokenType.string)
        throw UnimsgException('table headers must be bare or quoted keys',
            token.line, token.column);
      final key = token.value as String;
      if (keys.contains(key))
        throw UnimsgException(
            'duplicate table key "$key"', token.line, token.column);
      keys.add(key);
    }
    if (keys.isEmpty) throw _error('table header needs at least one column');
    _separators();
    final rows = <UValue>[];
    while (_peek.type != _TokenType.rightBracket) {
      _expect(_TokenType.pipe, "expected '|' at the start of a table row");
      final entries = <MapEntry>[];
      for (final key in keys) {
        if (_isBoundary)
          throw _error('table row has fewer than ${keys.length} cells');
        entries.add(MapEntry(key, _annotatedValue()));
      }
      if (!_isSeparator)
        throw _error('table row has more than ${keys.length} cells');
      rows.add(UMap(entries));
      _separators();
    }
    index++;
    return USeq(rows);
  }

  _Token get _peek => tokens[index];
  _Token get _next => tokens[index++];
  bool get _isSeparator =>
      _peek.type == _TokenType.separator || _peek.type == _TokenType.comment;
  bool get _isBoundary =>
      _isSeparator ||
      {_TokenType.rightBrace, _TokenType.rightBracket, _TokenType.eof}
          .contains(_peek.type);
  bool get _nextIsBoundary =>
      index + 1 >= tokens.length ||
      {
        _TokenType.separator,
        _TokenType.comment,
        _TokenType.rightBrace,
        _TokenType.rightBracket,
        _TokenType.eof
      }.contains(tokens[index + 1].type);
  UnimsgException _error(String message) =>
      UnimsgException(message, _peek.line, _peek.column);

  void _expect(_TokenType type, String message) {
    if (_peek.type != type) throw _error(message);
    index++;
  }

  void _separators() {
    while (_isSeparator) {
      index++;
    }
  }

  void _separatorsAndComments(List<String> comments) {
    while (true) {
      if (_peek.type == _TokenType.separator) {
        index++;
      } else if (_peek.type == _TokenType.comment) {
        comments.add(_next.value as String);
      } else {
        break;
      }
    }
  }
}

bool _reservedLiteral(String value) =>
    const {'true', 'false', 'null', 'nan', 'inf', '-inf'}.contains(value);
bool _isBoundary(String c) => RegExp(r'\s').hasMatch(c) || c == ',';
bool _isAsciiDigit(String c) =>
    c.length == 1 && c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;

final RegExp _wordCategory = RegExp(r'^[\p{L}\p{N}\p{M}]$', unicode: true);
bool _isWordRune(String c) => _wordCategory.hasMatch(c) || '_-./+'.contains(c);

int? _timestampPrefix(String source) {
  final match = RegExp(
          r'^\d{4}-\d{2}(-\d{2}([T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})?)?)?')
      .firstMatch(source);
  if (match == null) return null;
  final end = match.end;
  if (end < source.length) {
    final next = String.fromCharCode(_runeAt(source, end));
    if (!_isBoundary(next) && !'}]|'.contains(next)) return null;
  }
  return end;
}

bool _validNumber(String text) {
  final core = text.endsWith('f') ? text.substring(0, text.length - 1) : text;
  return RegExp(r'^-?\d+(\.\d+)?([eE][+-]?\d+)?$').hasMatch(core) &&
      (core.contains('.') ||
          core.contains(RegExp('[eE]')) ||
          !text.endsWith('f'));
}

UValue _numberValue(String text) {
  if (text.endsWith('f'))
    return UFloat(double.parse(text.substring(0, text.length - 1)));
  if (!text.contains(RegExp(r'[.eE]'))) return UInt(BigInt.parse(text));
  final match =
      RegExp(r'^(-?)(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$').firstMatch(text)!;
  final fraction = match.group(3) ?? '';
  final sign = match.group(1)!;
  final mantissa = BigInt.parse('$sign${match.group(2)}$fraction');
  final exponent =
      BigInt.parse(match.group(4) ?? '0') - BigInt.from(fraction.length);
  return UDecimal(exponent, mantissa);
}

Uint8List? _decodeHex(String text) {
  if (text.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(text))
    return null;
  return Uint8List.fromList([
    for (var i = 0; i < text.length; i += 2)
      int.parse(text.substring(i, i + 2), radix: 16)
  ]);
}

int _runeAt(String text, int offset) {
  final first = text.codeUnitAt(offset);
  if (first >= 0xd800 && first <= 0xdbff && offset + 1 < text.length) {
    final second = text.codeUnitAt(offset + 1);
    if (second >= 0xdc00 && second <= 0xdfff) {
      return 0x10000 + ((first - 0xd800) << 10) + second - 0xdc00;
    }
  }
  return first;
}
