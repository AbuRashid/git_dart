part of '../unimsg.dart';

final class UnimsgException implements Exception {
  final String message;
  final int line;
  final int column;

  const UnimsgException(this.message, this.line, this.column);

  factory UnimsgException.binary(String message, int offset) =>
      UnimsgException('CBOR byte $offset: $message', 1, offset + 1);

  @override
  String toString() => '$line:$column: $message';
}

final class UnimsgHeader {
  final int version;
  final String? label;
  const UnimsgHeader(this.version, this.label);
}

final class UnimsgDocument {
  final UnimsgHeader? header;
  final UValue value;
  const UnimsgDocument(this.header, this.value);
}

sealed class Annotation {
  final String name;
  const Annotation(this.name);
}

final class SymbolAnnotation extends Annotation {
  const SymbolAnnotation(super.name);
}

final class IdentifierAnnotation extends Annotation {
  const IdentifierAnnotation(super.name);
}

final class MapEntry {
  final String key;
  final UValue value;
  final List<String> comments;
  const MapEntry(this.key, this.value, [this.comments = const []]);
}

sealed class UValue {
  const UValue();
}

final class UNull extends UValue {
  const UNull();
}

final class UBool extends UValue {
  final bool value;
  const UBool(this.value);
}

final class UInt extends UValue {
  final BigInt value;
  UInt(Object value)
      : value = value is BigInt ? value : BigInt.from(value as int);
}

final class UDecimal extends UValue {
  final BigInt exponent;
  final BigInt mantissa;
  UDecimal(Object exponent, Object mantissa)
      : exponent = exponent is BigInt ? exponent : BigInt.from(exponent as int),
        mantissa = mantissa is BigInt ? mantissa : BigInt.from(mantissa as int);
}

final class UFloat extends UValue {
  final double value;
  const UFloat(this.value);
}

final class UBytes extends UValue {
  final Uint8List value;
  UBytes(List<int> value) : value = Uint8List.fromList(value);
}

final class UText extends UValue {
  final String value;
  const UText(this.value);
}

final class USeq extends UValue {
  final List<UValue> values;
  const USeq(this.values);
}

final class UMap extends UValue {
  final List<MapEntry> entries;
  const UMap(this.entries);
}

final class USymbol extends UValue {
  final String name;
  const USymbol(this.name);
}

final class UAnnotated extends UValue {
  final List<Annotation> annotations;
  final UValue value;
  const UAnnotated(this.annotations, this.value);
}

final class UIdentifier extends UValue {
  final String name;
  const UIdentifier(this.name);
}

final class UReference extends UValue {
  final String name;
  const UReference(this.name);
}

final class UHash extends UValue {
  final String algorithm;
  final Uint8List digest;
  UHash(this.algorithm, List<int> digest) : digest = Uint8List.fromList(digest);
}

final class UExtension extends UValue {
  final String name;
  final UValue value;
  const UExtension(this.name, this.value);
}

final class UTimestamp extends UValue {
  final String text;
  const UTimestamp(this.text);
}

final class UTagged extends UValue {
  final BigInt tag;
  final UValue value;
  UTagged(Object tag, this.value)
      : tag = tag is BigInt ? tag : BigInt.from(tag as int);
}
