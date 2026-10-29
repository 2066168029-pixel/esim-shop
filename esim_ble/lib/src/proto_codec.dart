/// Minimal protobuf wire-format encoder/decoder.
///
/// The Linksfield device protocol is small enough that hand-rolling the
/// codec beats adding protoc + build_runner to the toolchain: no generated
/// files to keep in sync, no extra build step, and the wire format is only
/// varints + length-delimited fields.
///
/// Encoding order matters only in that fields must be written in tag order to
/// match what the firmware round-trips; the firmware itself parses by tag.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Protobuf wire types we actually use.
class WireType {
  static const int varint = 0;
  static const int fixed64 = 1;
  static const int lengthDelimited = 2;
  static const int fixed32 = 5;
}

/// Encodes protobuf fields into a byte buffer.
class ProtoWriter {
  final BytesBuilder _buf = BytesBuilder(copy: false);

  int get length => _buf.length;

  Uint8List toBytes() => _buf.toBytes();

  /// Writes a field tag (field number + wire type) as a varint.
  void _tag(int field, int wireType) {
    _writeVarint((field << 3) | wireType);
  }

  void _writeVarint(int value) {
    // Protobuf varints are unsigned 64-bit little-endian with continuation bits.
    var v = value;
    while (v >= 0x80) {
      _buf.addByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    _buf.addByte(v & 0x7F);
  }

  /// Writes an int32/int64 field. Negative values are encoded as 64-bit
  /// two's complement varints, matching protobuf's int32 semantics.
  void int32(int field, int? value) {
    if (value == null) return;
    _tag(field, WireType.varint);
    if (value < 0) {
      _writeVarint64(value);
    } else {
      _writeVarint(value);
    }
  }

  void bool_(int field, bool? value) {
    if (value == null) return;
    _tag(field, WireType.varint);
    _writeVarint(value ? 1 : 0);
  }

  void _writeVarint64(int value) {
    // Negative values are always encoded as a full 10-byte varint (their
    // unsigned 64-bit two's complement). Positive values stop as soon as the
    // remaining bits are zero.
    if (value < 0) {
      var v = value;
      for (var i = 0; i < 10; i++) {
        final b = v & 0x7F;
        v = v >> 7;
        _buf.addByte(i == 9 ? b : (b | 0x80));
      }
      return;
    }

    var v = value;
    while (v >= 0x80) {
      _buf.addByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    _buf.addByte(v & 0x7F);
  }

  /// Writes a length-delimited bytes field.
  void bytes(int field, List<int>? value) {
    if (value == null) return;
    _tag(field, WireType.lengthDelimited);
    _writeVarint(value.length);
    _buf.add(value);
  }

  /// Writes a length-delimited string field (UTF-8).
  void string(int field, String? value) {
    if (value == null) return;
    bytes(field, utf8.encode(value));
  }

  /// Writes a nested message field.
  void message(int field, Uint8List? value) {
    bytes(field, value);
  }
}

/// Decodes protobuf fields from a byte buffer.
class ProtoReader {
  final Uint8List _data;
  int _pos = 0;

  ProtoReader(this._data);

  bool get isAtEnd => _pos >= _data.length;

  /// Reads the next tag. Returns null at end of buffer.
  (int field, int wireType)? nextTag() {
    if (isAtEnd) return null;
    final tag = _readVarint();
    return (tag >> 3, tag & 0x07);
  }

  int _readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_pos >= _data.length) {
        throw FormatException('Truncated varint at offset $_pos');
      }
      final b = _data[_pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) break;
      shift += 7;
      if (shift > 63) throw FormatException('Varint too long');
    }
    return result;
  }

  int readInt32() {
    final v = _readVarint();
    // Protobuf encodes negative int32 as a 10-byte 64-bit varint. Dart ints are
    // 64-bit, so a value beyond the int32 range is a negative number already
    // sign-folded into the upper bits; truncating to 32 bits recovers it.
    if (v > 0x7FFFFFFF) {
      final low32 = v & 0xFFFFFFFF;
      return low32 >= 0x80000000 ? low32 - 0x100000000 : low32;
    }
    return v;
  }

  bool readBool() => _readVarint() != 0;

  Uint8List readBytes() {
    final len = _readVarint();
    if (_pos + len > _data.length) {
      throw FormatException('Truncated bytes at offset $_pos (len=$len)');
    }
    final out = Uint8List.sublistView(_data, _pos, _pos + len);
    _pos += len;
    return out;
  }

  String readString() => utf8.decode(readBytes());

  /// Skips an unknown field so parsing stays tolerant of firmware additions.
  void skip(int wireType) {
    // Dart does not fall through between cases, but every branch must still
    // consume its own payload or the reader desynchronises.
    switch (wireType) {
      case WireType.varint:
        _readVarint();
      case WireType.lengthDelimited:
        readBytes();
      case WireType.fixed32:
        if (_pos + 4 > _data.length) {
          throw FormatException('Truncated fixed32 at offset $_pos');
        }
        _pos += 4;
      case WireType.fixed64:
        if (_pos + 8 > _data.length) {
          throw FormatException('Truncated fixed64 at offset $_pos');
        }
        _pos += 8;
      default:
        throw FormatException('Unsupported wire type $wireType');
    }
  }
}
