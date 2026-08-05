part of '../unimsg.dart';

const int _symbolTag = 70100;
const int _annotatedTag = 70101;
const int _identifierTag = 70102;
const int _referenceTag = 70103;
const int _hashTag = 70104;
const int _extensionTag = 70105;
const int _timestampTag = 70106;
final BigInt _maxUint64 = (BigInt.one << 64) - BigInt.one;

Uint8List encode(UValue value) {
  final output = <int>[];
  _Encoder(output).value(value);
  return Uint8List.fromList(output);
}

UValue decode(List<int> input) {
  final bytes = input is Uint8List ? input : Uint8List.fromList(input);
  final decoder = _Decoder(bytes);
  final value = decoder.value();
  if (decoder.offset != bytes.length) {
    throw UnimsgException.binary(
        'trailing data after the first value', decoder.offset);
  }
  final canonical = encode(value);
  if (!_bytesEqual(canonical, bytes)) {
    var mismatch = 0;
    while (mismatch < canonical.length &&
        mismatch < bytes.length &&
        canonical[mismatch] == bytes[mismatch]) {
      mismatch++;
    }
    throw UnimsgException.binary(
      'encoding is valid CBOR but is not the required deterministic encoding',
      mismatch,
    );
  }
  return value;
}

final class _Encoder {
  final List<int> output;
  _Encoder(this.output);

  void value(UValue value) {
    switch (value) {
      case UNull():
        output.add(0xf6);
      case UBool(:final value):
        output.add(value ? 0xf5 : 0xf4);
      case UInt(:final value):
        _integer(value);
      case UDecimal(:final exponent, :final mantissa):
        _tag(4);
        _array(2);
        _integer(exponent);
        _integer(mantissa);
      case UFloat(:final value):
        _float(value);
      case UBytes(:final value):
        _byteString(value);
      case UText(:final value):
        _text(value);
      case USeq(:final values):
        _array(values.length);
        for (final item in values) {
          this.value(item);
        }
      case UMap(:final entries):
        _map(entries);
      case USymbol(:final name):
        _tag(_symbolTag);
        _text(name);
      case UAnnotated(:final annotations, :final value):
        if (annotations.isEmpty)
          throw const UnimsgException(
              'annotated value has no annotations', 1, 1);
        _tag(_annotatedTag);
        _array(2);
        _array(annotations.length);
        for (final annotation in annotations) {
          switch (annotation) {
            case SymbolAnnotation(:final name):
              _tag(_symbolTag);
              _text(name);
            case IdentifierAnnotation(:final name):
              _tag(_identifierTag);
              _text(name);
          }
        }
        this.value(value);
      case UIdentifier(:final name):
        _tag(_identifierTag);
        _text(name);
      case UReference(:final name):
        _tag(_referenceTag);
        _text(name);
      case UHash(:final algorithm, :final digest):
        _tag(_hashTag);
        _array(2);
        _text(algorithm);
        _byteString(digest);
      case UExtension(:final name, :final value):
        _tag(_extensionTag);
        _array(2);
        _text(name);
        this.value(value);
      case UTimestamp(:final text):
        _tag(_timestampTag);
        _text(text);
      case UTagged(:final tag, :final value):
        _tag(tag);
        this.value(value);
    }
  }

  void _integer(BigInt value) {
    if (value >= BigInt.zero) {
      if (value <= _maxUint64) {
        _majorBig(0, value);
      } else {
        _tag(2);
        _byteString(_magnitudeBytes(value));
      }
    } else {
      final adjusted = -BigInt.one - value;
      if (adjusted <= _maxUint64) {
        _majorBig(1, adjusted);
      } else {
        _tag(3);
        _byteString(_magnitudeBytes(adjusted));
      }
    }
  }

  void _map(List<MapEntry> entries) {
    final encoded = <(Uint8List, Uint8List)>[];
    for (final entry in entries) {
      final key = <int>[];
      _Encoder(key)._text(entry.key);
      final item = <int>[];
      _Encoder(item).value(entry.value);
      encoded.add((Uint8List.fromList(key), Uint8List.fromList(item)));
    }
    encoded.sort((a, b) => _lengthFirst(a.$1, b.$1));
    for (var i = 1; i < encoded.length; i++) {
      if (_bytesEqual(encoded[i - 1].$1, encoded[i].$1)) {
        throw const UnimsgException('map contains duplicate keys', 1, 1);
      }
    }
    _major(5, encoded.length);
    for (final pair in encoded) {
      output.addAll(pair.$1);
      output.addAll(pair.$2);
    }
  }

  void _float(double number) {
    if (number.isNaN) {
      output.addAll(const [0xf9, 0x7e, 0x00]);
      return;
    }
    final half = _exactHalf(number);
    if (half != null) {
      output.addAll([0xf9, half >> 8, half & 0xff]);
      return;
    }
    final single = _asFloat32(number);
    if (_sameFloat(single, number)) {
      final data = ByteData(4)..setFloat32(0, single, Endian.big);
      output.add(0xfa);
      output.addAll(data.buffer.asUint8List());
    } else {
      final data = ByteData(8)..setFloat64(0, number, Endian.big);
      output.add(0xfb);
      output.addAll(data.buffer.asUint8List());
    }
  }

  void _text(String text) {
    final bytes = utf8.encode(text);
    _major(3, bytes.length);
    output.addAll(bytes);
  }

  void _byteString(List<int> bytes) {
    _major(2, bytes.length);
    output.addAll(bytes);
  }

  void _tag(Object tag) =>
      _majorBig(6, tag is BigInt ? tag : BigInt.from(tag as int));
  void _array(int length) => _major(4, length);

  void _major(int major, int argument) =>
      _majorBig(major, BigInt.from(argument));

  void _majorBig(int major, BigInt argument) {
    final prefix = major << 5;
    if (argument <= BigInt.from(23)) {
      output.add(prefix | argument.toInt());
    } else if (argument <= BigInt.from(0xff)) {
      output.addAll([prefix | 24, argument.toInt()]);
    } else if (argument <= BigInt.from(0xffff)) {
      output.add(prefix | 25);
      _unsigned(argument, 2);
    } else if (argument <= BigInt.from(0xffffffff)) {
      output.add(prefix | 26);
      _unsigned(argument, 4);
    } else if (argument <= _maxUint64) {
      output.add(prefix | 27);
      _unsigned(argument, 8);
    } else {
      throw const UnimsgException('CBOR argument exceeds 64 bits', 1, 1);
    }
  }

  void _unsigned(BigInt value, int bytes) {
    for (var shift = (bytes - 1) * 8; shift >= 0; shift -= 8) {
      output.add(((value >> shift) & BigInt.from(0xff)).toInt());
    }
  }
}

final class _Decoder {
  final Uint8List bytes;
  int offset = 0;
  _Decoder(this.bytes);

  UValue value() {
    final start = offset;
    final initial = _byte();
    final major = initial >> 5;
    final info = initial & 31;
    switch (major) {
      case 0:
        return UInt(_argument(info));
      case 1:
        return UInt(-BigInt.one - _argument(info));
      case 2:
        return UBytes(_take(_length(info)));
      case 3:
        final raw = _take(_length(info));
        try {
          return UText(utf8.decode(raw));
        } on FormatException {
          throw UnimsgException.binary('text string is not UTF-8', start);
        }
      case 4:
        final length = _length(info);
        return USeq([for (var i = 0; i < length; i++) value()]);
      case 5:
        final length = _length(info);
        final entries = <MapEntry>[];
        final keys = <Uint8List>[];
        for (var i = 0; i < length; i++) {
          final keyStart = offset;
          final keyValue = value();
          final keyBytes = Uint8List.sublistView(bytes, keyStart, offset);
          if (keys.any((key) => _bytesEqual(key, keyBytes)))
            throw UnimsgException.binary('duplicate map key', keyStart);
          if (keyValue is! UText)
            throw UnimsgException.binary(
                'unimsg v0 map keys must be text strings', keyStart);
          final item = value();
          keys.add(Uint8List.fromList(keyBytes));
          entries.add(MapEntry(keyValue.value, item));
        }
        return UMap(entries);
      case 6:
        final tag = _argument(info);
        return _decodeTag(tag, value(), start);
      case 7:
        return _simple(info, start);
      default:
        throw StateError('unreachable');
    }
  }

  UValue _simple(int info, int start) {
    switch (info) {
      case 20:
        return const UBool(false);
      case 21:
        return const UBool(true);
      case 22:
        return const UNull();
      case 25:
        final bits = _unsigned(2).toInt();
        return UFloat(_halfToDouble(bits));
      case 26:
        final data = ByteData.sublistView(_take(4));
        return UFloat(data.getFloat32(0, Endian.big));
      case 27:
        final data = ByteData.sublistView(_take(8));
        return UFloat(data.getFloat64(0, Endian.big));
      case 31:
        throw UnimsgException.binary('indefinite lengths are forbidden', start);
      default:
        throw UnimsgException.binary(
            'unsupported CBOR simple value $info', start);
    }
  }

  BigInt _argument(int info) {
    if (info <= 23) return BigInt.from(info);
    switch (info) {
      case 24:
        return BigInt.from(_byte());
      case 25:
        return _unsigned(2);
      case 26:
        return _unsigned(4);
      case 27:
        return _unsigned(8);
      case 31:
        throw UnimsgException.binary(
            'indefinite lengths are forbidden', offset - 1);
      default:
        throw UnimsgException.binary(
            'reserved CBOR additional information', offset - 1);
    }
  }

  int _length(int info) {
    final length = _argument(info);
    if (length > (BigInt.one << 63) - BigInt.one) {
      throw UnimsgException.binary('length does not fit this platform', offset);
    }
    return length.toInt();
  }

  int _byte() {
    if (offset >= bytes.length)
      throw UnimsgException.binary('unexpected end of input', offset);
    return bytes[offset++];
  }

  Uint8List _take(int count) {
    final end = offset + count;
    if (count < 0 || end > bytes.length)
      throw UnimsgException.binary('unexpected end of input', offset);
    final result = Uint8List.sublistView(bytes, offset, end);
    offset = end;
    return result;
  }

  BigInt _unsigned(int count) {
    var result = BigInt.zero;
    for (final byte in _take(count)) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }
}

UValue _decodeTag(BigInt tag, UValue content, int offset) {
  UnimsgException bad(String text) => UnimsgException.binary(text, offset);
  if (tag == BigInt.two || tag == BigInt.from(3)) {
    if (content is! UBytes) throw bad('bignum tag must contain a byte string');
    if (content.value.isEmpty || content.value.first == 0)
      throw bad('bignum magnitude must be non-empty with no leading zero');
    if (content.value.length <= 8)
      throw bad('bignum tag used for a value representable by a major type');
    final magnitude = _bytesMagnitude(content.value);
    return UInt(tag == BigInt.two ? magnitude : -BigInt.one - magnitude);
  }
  if (tag == BigInt.from(4)) {
    if (content is! USeq ||
        content.values.length != 2 ||
        content.values[0] is! UInt ||
        content.values[1] is! UInt) {
      throw bad('decimal tag must contain [exponent, mantissa] integers');
    }
    return UDecimal(
        (content.values[0] as UInt).value, (content.values[1] as UInt).value);
  }
  if (tag == BigInt.from(_symbolTag))
    return USymbol(_expectText(content, 'symbol', offset));
  if (tag == BigInt.from(_identifierTag))
    return UIdentifier(_expectText(content, 'identifier', offset));
  if (tag == BigInt.from(_referenceTag))
    return UReference(_expectText(content, 'reference', offset));
  if (tag == BigInt.from(_timestampTag))
    return UTimestamp(_expectText(content, 'timestamp', offset));
  if (tag == BigInt.from(_annotatedTag)) {
    if (content is! USeq ||
        content.values.length != 2 ||
        content.values[0] is! USeq)
      throw bad('annotated tag must contain [annotations, value]');
    final raw = (content.values[0] as USeq).values;
    if (raw.isEmpty) throw bad('annotation list must not be empty');
    final annotations = <Annotation>[];
    for (final item in raw) {
      if (item is USymbol) {
        annotations.add(SymbolAnnotation(item.name));
      } else if (item is UIdentifier) {
        annotations.add(IdentifierAnnotation(item.name));
      } else {
        throw bad('annotations must be symbols or identifiers');
      }
    }
    return UAnnotated(annotations, content.values[1]);
  }
  if (tag == BigInt.from(_hashTag)) {
    if (content is! USeq ||
        content.values.length != 2 ||
        content.values[0] is! UText ||
        content.values[1] is! UBytes) {
      throw bad('hash must contain algorithm text and digest bytes');
    }
    return UHash((content.values[0] as UText).value,
        (content.values[1] as UBytes).value);
  }
  if (tag == BigInt.from(_extensionTag)) {
    if (content is! USeq ||
        content.values.length != 2 ||
        content.values[0] is! UText)
      throw bad('extension must contain name text and a value');
    return UExtension((content.values[0] as UText).value, content.values[1]);
  }
  return UTagged(tag, content);
}

String _expectText(UValue value, String kind, int offset) {
  if (value is UText) return value.value;
  throw UnimsgException.binary('$kind tag must contain text', offset);
}

Uint8List _magnitudeBytes(BigInt value) {
  final output = <int>[];
  while (value > BigInt.zero) {
    output.add((value & BigInt.from(0xff)).toInt());
    value >>= 8;
  }
  return Uint8List.fromList(output.reversed.toList());
}

BigInt _bytesMagnitude(List<int> bytes) {
  var output = BigInt.zero;
  for (final byte in bytes) {
    output = (output << 8) | BigInt.from(byte);
  }
  return output;
}

int _lengthFirst(List<int> a, List<int> b) {
  if (a.length != b.length) return a.length.compareTo(b.length);
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return 0;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

double _asFloat32(double value) {
  final data = ByteData(4)..setFloat32(0, value, Endian.host);
  return data.getFloat32(0, Endian.host);
}

bool _sameFloat(double a, double b) {
  final data = ByteData(16)
    ..setFloat64(0, a, Endian.host)
    ..setFloat64(8, b, Endian.host);
  for (var i = 0; i < 8; i++) {
    if (data.getUint8(i) != data.getUint8(i + 8)) return false;
  }
  return true;
}

int? _exactHalf(double value) {
  if (value.isInfinite) return value.isNegative ? 0xfc00 : 0x7c00;
  final single = _asFloat32(value);
  if (!_sameFloat(single, value)) return null;
  final half = _float32ToHalf(single);
  return _sameFloat(_halfToDouble(half), value) ? half : null;
}

int _float32ToHalf(double value) {
  final data = ByteData(4)..setFloat32(0, value, Endian.host);
  final bits = data.getUint32(0, Endian.host);
  final sign = (bits >> 16) & 0x8000;
  final exponent = (bits >> 23) & 0xff;
  final mantissa = bits & 0x7fffff;
  if (exponent == 255) return sign | (mantissa == 0 ? 0x7c00 : 0x7e00);
  final halfExponent = exponent - 127 + 15;
  if (halfExponent >= 31) return sign | 0x7c00;
  if (halfExponent <= 0) {
    if (halfExponent < -10) return sign;
    final m = mantissa | 0x800000;
    final shift = 14 - halfExponent;
    var rounded = m >> shift;
    final remainder = m & ((1 << shift) - 1);
    final halfway = 1 << (shift - 1);
    if (remainder > halfway || (remainder == halfway && rounded.isOdd))
      rounded++;
    return sign | rounded;
  }
  var rounded = mantissa >> 13;
  final remainder = mantissa & 0x1fff;
  if (remainder > 0x1000 || (remainder == 0x1000 && rounded.isOdd)) rounded++;
  if (rounded == 0x400) return sign | ((halfExponent + 1) << 10);
  return sign | (halfExponent << 10) | rounded;
}

double _halfToDouble(int bits) {
  final sign = bits & 0x8000 != 0 ? -1.0 : 1.0;
  final exponent = (bits >> 10) & 0x1f;
  final mantissa = bits & 0x3ff;
  if (exponent == 0 && mantissa == 0) return sign * 0.0;
  if (exponent == 0) return sign * mantissa * _pow2(-24);
  if (exponent == 31 && mantissa == 0) return sign * double.infinity;
  if (exponent == 31) return double.nan;
  return sign * (1.0 + mantissa / 1024.0) * _pow2(exponent - 15);
}

double _pow2(int exponent) {
  if (exponent >= 0) return (1 << exponent).toDouble();
  return 1.0 / (1 << -exponent);
}
