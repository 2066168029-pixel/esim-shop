/// Minimal BER/DER encoder and parser for the SGP.22 ASN.1 structures.
///
/// SGP.22 uses BER with a few multi-byte tags (0xBF20, 0xBF2E, 0xBF36 ...).
/// That is the whole reason a general ASN.1 library is not needed: we only
/// ever need to build TLV nodes and walk them by tag.
library;

import 'dart:convert';
import 'dart:typed_data';

/// A parsed TLV node. [self] is the full encoding including tag and length,
/// which is what the SM-DP+ expects when a whole structure is base64'd.
class DerNode {
  final int tag;
  final Uint8List value;
  final Uint8List self;

  DerNode(this.tag, this.value, this.self);

  @override
  String toString() =>
      'DerNode(0x${tag.toRadixString(16).toUpperCase()}, ${value.length}B)';
}

/// Encodes a tag: single byte, or the 2-byte form 0xBFxx / 0x9Fxx.
Uint8List _encodeTag(int tag) {
  if (tag <= 0xFF) return Uint8List.fromList([tag]);
  return Uint8List.fromList([(tag >> 8) & 0xFF, tag & 0xFF]);
}

/// DER length: short form below 128, then 0x81/0x82/0x83 long form.
Uint8List _encodeLength(int len) {
  if (len < 0x80) return Uint8List.fromList([len]);
  if (len <= 0xFF) return Uint8List.fromList([0x81, len]);
  if (len <= 0xFFFF) return Uint8List.fromList([0x82, len >> 8, len & 0xFF]);
  return Uint8List.fromList(
      [0x83, (len >> 16) & 0xFF, (len >> 8) & 0xFF, len & 0xFF]);
}

/// Builds a TLV node from a tag and already-encoded content bytes.
Uint8List tlv(int tag, List<int> content) {
  final t = _encodeTag(tag);
  final l = _encodeLength(content.length);
  return Uint8List.fromList([...t, ...l, ...content]);
}

/// Builds a TLV node from child nodes.
Uint8List tlvChildren(int tag, List<Uint8List> children) {
  final body = BytesBuilder();
  for (final c in children) {
    body.add(c);
  }
  return tlv(tag, body.toBytes());
}

/// Encodes an integer as a DER INTEGER (tag 0x02), minimal two's complement.
Uint8List derInteger(int value) {
  final bytes = <int>[];
  var v = value;
  while (v > 0) {
    bytes.insert(0, v & 0xFF);
    v >>= 8;
  }
  if (bytes.isEmpty) bytes.add(0);
  // Ensure the sign bit is clear by prepending 0x00 when needed.
  if (bytes.first & 0x80 != 0) bytes.insert(0, 0);
  return tlv(0x02, bytes);
}

/// Encodes an OCTET STRING (tag 0x04).
Uint8List octetString(List<int> data) => tlv(0x04, data);

/// Encodes a UTF8String (tag 0x0C) -- used for IMEI and matchingId fields.
Uint8List utf8String(String s) => tlv(0x0C, s.codeUnits);

/// Reads a tag at [pos], returning (tag, nextPos).
(int, int) _readTag(Uint8List data, int pos) {
  final b = data[pos];
  // Multi-byte tags: low 5 bits all set means the tag continues.
  if ((b & 0x1F) == 0x1F) {
    if (pos + 1 >= data.length) {
      throw FormatException('Truncated tag at $pos');
    }
    return ((b << 8) | data[pos + 1], pos + 2);
  }
  return (b, pos + 1);
}

/// Reads a length at [pos], returning (length, contentStart).
(int, int) _readLength(Uint8List data, int pos) {
  if (pos >= data.length) throw FormatException('Truncated length at $pos');
  final b = data[pos];
  if (b < 0x80) return (b, pos + 1);
  final n = b & 0x7F;
  if (n == 0 || n > 4 || pos + n >= data.length) {
    throw FormatException('Indefinite or invalid length at $pos');
  }
  var v = 0;
  for (var i = 0; i < n; i++) {
    v = (v << 8) | data[pos + 1 + i];
  }
  return (v, pos + 1 + n);
}

/// Parses one TLV at [pos].
DerNode parseNode(Uint8List data, int pos) {
  final (tag, afterTag) = _readTag(data, pos);
  final (len, contentStart) = _readLength(data, afterTag);
  final end = contentStart + len;
  if (end > data.length) {
    throw FormatException('TLV at $pos declares $len bytes, only '
        '${data.length - contentStart} available');
  }
  return DerNode(
    tag,
    Uint8List.sublistView(data, contentStart, end),
    Uint8List.sublistView(data, pos, end),
  );
}

/// Parses every top-level TLV in [data].
List<DerNode> parseAll(Uint8List data) {
  final out = <DerNode>[];
  var pos = 0;
  while (pos < data.length) {
    final node = parseNode(data, pos);
    out.add(node);
    pos += node.self.length;
  }
  return out;
}

/// Finds the first descendant with [tag], depth-first.
///
/// Searches *children* of [data], not [data] itself, so callers that already
/// hold a node can pass `node.self` and get its inner payload rather than the
/// same node back.
DerNode? findByTag(Uint8List data, int tag) {
  for (final node in parseAll(data)) {
    final inner = _findIncludingSelf(node, tag);
    if (inner != null) return inner;
  }
  return null;
}

DerNode? _findIncludingSelf(DerNode node, int tag) {
  if (node.tag == tag) return node;
  return _tryFindIn(node.value, tag);
}

DerNode? _tryFindIn(Uint8List data, int tag) {
  try {
    for (final node in parseAll(data)) {
      if (node.tag == tag) return node;
      final inner = _tryFindIn(node.value, tag);
      if (inner != null) return inner;
    }
  } on FormatException {
    // Leaf node with non-TLV content; nothing to descend into.
  }
  return null;
}

/// Encodes a base64-decoded EUICCInfo1 etc. as needed by callers.
String toBase64(Uint8List data) => base64.encode(data);
