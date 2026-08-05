import 'dart:convert';
import 'dart:typed_data';

/// The three packets that carry no payload.
enum PktKind {
  /// `0000` — the end of a section.
  flush,

  /// `0001` — a boundary within a section, protocol v2.
  delimiter,

  /// `0002` — the end of a response, protocol v2.
  responseEnd,

  data,
}

class PktLine {
  final PktKind kind;

  /// The payload, without the four length characters. Empty for the special
  /// packets.
  final Uint8List payload;

  const PktLine(this.kind, this.payload);

  static final flush = PktLine(PktKind.flush, Uint8List(0));
  static final delimiter = PktLine(PktKind.delimiter, Uint8List(0));
  static final responseEnd = PktLine(PktKind.responseEnd, Uint8List(0));

  factory PktLine.data(List<int> payload) =>
      PktLine(PktKind.data, Uint8List.fromList(payload));

  factory PktLine.text(String text) => PktLine.data(utf8.encode(text));

  bool get isFlush => kind == PktKind.flush;

  String get text => utf8.decode(payload, allowMalformed: true);

  /// The packet as it goes on the wire.
  ///
  /// The length counts its own four characters, so a fifteen-byte payload is
  /// announced as `0013` (`transfer.pkt-line.rule`).
  Uint8List encode() {
    switch (kind) {
      case PktKind.flush:
        return Uint8List.fromList(ascii.encode('0000'));
      case PktKind.delimiter:
        return Uint8List.fromList(ascii.encode('0001'));
      case PktKind.responseEnd:
        return Uint8List.fromList(ascii.encode('0002'));
      case PktKind.data:
        final length = payload.length + 4;
        if (length > 65520) {
          throw ArgumentError.value(
            payload.length,
            'payload',
            'a pkt-line payload is at most 65516 bytes',
          );
        }
        final header = ascii.encode(length.toRadixString(16).padLeft(4, '0'));
        return Uint8List(length)
          ..setRange(0, 4, header)
          ..setRange(4, length, payload);
    }
  }
}

/// Reads pkt-lines out of a buffer.
///
/// Self-delimiting framing over a stream: a reader never needs to know a
/// message's length in advance, so the same code works over a pipe, a socket
/// and HTTP.
class PktLineReader {
  final Uint8List _bytes;
  int _at;

  PktLineReader(this._bytes, [this._at = 0]);

  /// How far the reader has consumed — the offset where a packfile or other
  /// unframed data begins.
  int get position => _at;

  bool get hasMore => _at < _bytes.length;

  /// The next packet, or null at the end of the buffer.
  PktLine? next() {
    if (_at >= _bytes.length) return null;
    if (_at + 4 > _bytes.length) {
      throw const FormatException('a pkt-line length is four characters');
    }

    final header = ascii.decode(_bytes.sublist(_at, _at + 4));
    final length = int.tryParse(header, radix: 16);
    if (length == null) {
      throw FormatException('pkt-line length "$header" is not hexadecimal');
    }
    _at += 4;

    switch (length) {
      case 0:
        return PktLine.flush;
      case 1:
        return PktLine.delimiter;
      case 2:
        return PktLine.responseEnd;
      case 3:
        throw const FormatException('0003 is not a valid pkt-line');
    }

    // The length includes the four characters just consumed. Adding four here
    // instead is the mistake that desynchronises the stream far from its cause
    // (`hazards`).
    final payloadLength = length - 4;
    if (_at + payloadLength > _bytes.length) {
      throw FormatException(
        'pkt-line announces $payloadLength bytes, only '
        '${_bytes.length - _at} remain',
      );
    }
    final payload = Uint8List.fromList(
      _bytes.sublist(_at, _at + payloadLength),
    );
    _at += payloadLength;
    return PktLine(PktKind.data, payload);
  }

  /// Packets up to and including the next flush.
  List<PktLine> readSection() {
    final section = <PktLine>[];
    while (true) {
      final packet = next();
      if (packet == null || packet.isFlush) return section;
      section.add(packet);
    }
  }
}

/// One ref in a v0 advertisement: an object name, a space, and the ref's path.
///
/// The first line carries the server's capabilities after a NUL, which is
/// invisible to a careless reader and is how capability negotiation is
/// bootstrapped (`transfer.advertisement`).
({String name, String path, List<String> capabilities}) parseAdvertisement(
  PktLine packet,
) {
  final nul = packet.payload.indexOf(0);
  final line = nul < 0
      ? packet.text.trimRight()
      : utf8.decode(packet.payload.sublist(0, nul), allowMalformed: true);
  final capabilities = nul < 0
      ? const <String>[]
      : utf8
          .decode(packet.payload.sublist(nul + 1), allowMalformed: true)
          .trim()
          .split(' ')
          .where((c) => c.isNotEmpty)
          .toList();

  final space = line.indexOf(' ');
  if (space < 0) {
    throw FormatException('advertisement line has no ref path', line);
  }
  return (
    name: line.substring(0, space),
    path: line.substring(space + 1).trimRight(),
    capabilities: capabilities,
  );
}
