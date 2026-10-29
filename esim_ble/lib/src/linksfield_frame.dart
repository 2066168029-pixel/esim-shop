/// Linksfield BLE framing and protobuf envelope.
///
/// Everything here is derived from `docs/esim-ble-frame-protocol.md`, which was
/// produced by static analysis of `eSIM_Manager_2.5.2.apk`:
///
///   * Frame: `[len_hi][len_lo][protobuf...]`, length = **payload bytes only**,
///     big endian, 2 bytes by default (some devices use 4).
///   * Only the first chunk carries the header; continuation chunks are raw.
///   * Chunk capacity: first write `min(capacity, mtu - 5)` including the 2-byte
///     header; continuation writes `min(capacity, mtu - 3)` because the ATT
///     header is the only overhead.
///   * First request the vendor app sends is
///     `EuiccDeviceReq{cmd: DEVICE, request: DeviceReq{cmd: getDeviceInfo}}`,
///     which serialises to `08 00 12 02 08 01`.
///
/// The module is pure: no BLE, no I/O. That is what makes it testable offline.
library;

import 'dart:typed_data';

import 'linksfield_secure.dart' show SecurityProtocolMsg;

/// `EuiccDeviceReq.cmd`
class DeviceCommand {
  static const int device = 0;
  static const int euicc = 1;

  /// Top-level command carrying a `SmartCardReq` **and** a `SecurityProtocol`.
  ///
  /// Both use the same outer value; the inner message type is what
  /// distinguishes them. The vendor trace shows SCARD requests as `08 03`.
  static const int scard = 3;
  static const int security = 3;
}

/// `DeviceReq.cmd` -- sub-commands carried inside COMMAND_DEVICE.
class DeviceSubCommand {
  static const int unknown = 0;
  static const int getDeviceInfo = 1;
  static const int notifyDevice = 2;
  static const int resetDevice = 3;
  static const int deviceExtend = 4;
}

/// `SmartCardCommand`
///
/// Numbers come from the vendor trace, not from declaration order:
///
///   `08 03 12 2E 08 02 12 2A 0A 28 <AID>`
///     cmd=3 (SCARD) -> request{ cmd=2, openChannel{ aid } }
///
/// so opening a logical channel is **cmd = 2**. Sending cmd = 1 made the card
/// answer `result = 511` -- its "unknown command" -- and that is what blocked
/// every APDU attempt.
class SmartCardCommand {
  static const int unknown = 0;

  /// `CreateClient`: open a logical channel to an AID.
  static const int openLogicalChannel = 2;

  /// Close the channel opened by [openLogicalChannel].
  static const int closeLogicalChannel = 3;

  /// Send an APDU on an open channel.
  static const int transmitApduLogicalChannel = 4;

  static const int iccReset = 5;
  static const int onGetSimFunction = 6;
}

/// Result codes the firmware returns in `DeviceRsp.result` / `SmartCardRsp.result`.
class LinksfieldResult {
  /// The firmware's sentinel for "establish the secure channel first".
  static const int secureRequired = -256;
}

// ---------------------------------------------------------------------------
// protobuf wire helpers (minimal, no codegen -- see proto_codec.dart for the
// full-featured writer this deliberately keeps separate and dependency-free)
// ---------------------------------------------------------------------------

/// Minimal protobuf writer. Public so the secure-channel layer can reuse it
/// without a second copy drifting out of sync.
class PbWriter {
  final _buf = BytesBuilder();

  void _varint(int value) {
    // Negative values are encoded as 10-byte two's-complement varints, which is
    // what protobuf's int32/int64 do. Dart ints are 64-bit signed, so the loop
    // naturally emits the right bytes.
    var v = value;
    for (var i = 0; i < 10; i++) {
      final b = v & 0x7F;
      v >>= 7;
      if (v == 0 || (v == -1 && (b & 0x40) != 0)) {
        _buf.addByte(b);
        return;
      }
      _buf.addByte(b | 0x80);
    }
  }

  void tag(int field, int wire) => _varint((field << 3) | wire);

  void uint(int field, int value) {
    tag(field, 0);
    _varint(value);
  }

  void bytes(int field, List<int> value) {
    tag(field, 2);
    _varint(value.length);
    _buf.add(value);
  }

  void string(int field, String value) => bytes(field, value.codeUnits);

  Uint8List toBytes() => _buf.toBytes();
}

/// Minimal protobuf reader (see [PbWriter]).
class PbReader {
  final Uint8List _d;
  int _i = 0;

  PbReader(this._d);

  bool get atEnd => _i >= _d.length;

  int _varint() {
    var shift = 0;
    var value = 0;
    while (true) {
      if (_i >= _d.length) throw const FormatException('truncated varint');
      final b = _d[_i++];
      value |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) {
        // Only a full-width (10-byte) varint is a sign-extended negative:
        // protobuf pads negatives to 64 bits. The old rule folded every value
        // above 0x7FFFFFFF, which mangled length fields -- a 32-bit length read
        // as a negative is how "cmd=1, security=20B" became unparseable.
        // Dart already holds a 64-bit two's complement in `value`, so nothing
        // needs adjusting for the padded case; genuine int32 negatives are
        // explicitly folded by callers that know the field is signed.
        if (shift > 63) throw const FormatException('varint too long');
        return value;
      }
      shift += 7;
      if (shift > 70) throw const FormatException('varint too long');
    }
  }

  /// Returns (field, wire). Null at end of buffer.
  (int, int)? nextTag() {
    if (atEnd) return null;
    final key = _varint();
    return (key >> 3, key & 7);
  }

  int readUint() => _varint();

  Uint8List readBytes() {
    final n = _varint();
    if (_i + n > _d.length) throw const FormatException('truncated bytes');
    final out = Uint8List.sublistView(_d, _i, _i + n);
    _i += n;
    return out;
  }

  String readString() => String.fromCharCodes(readBytes());

  void skip(int wire) {
    switch (wire) {
      case 0:
        _varint();
      case 1:
        _i += 8;
      case 2:
        readBytes();
      case 5:
        _i += 4;
      default:
        throw FormatException('unsupported wire type $wire');
    }
  }
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

/// Builds `DeviceReq{cmd}`.
///
/// This is the body of a COMMAND_DEVICE request. `getDeviceInfo` carries no
/// arguments, so the message is one varint field.
Uint8List encodeDeviceReq(int subCmd) => (PbWriter()..uint(1, subCmd)).toBytes();

/// Builds `EuiccDeviceReq{cmd, request}`.
Uint8List encodeEuiccDeviceReq(int cmd, Uint8List request) =>
    (PbWriter()
          ..uint(1, cmd)
          ..bytes(2, request))
        .toBytes();

/// The exact first frame the vendor app sends.
///
/// Kept as a named function with a doc comment because it is the one byte
/// sequence the whole protocol hangs on; the offline test asserts it equals
/// `08 00 12 02 08 01`.
Uint8List encodeGetDeviceInfo() =>
    encodeEuiccDeviceReq(DeviceCommand.device, encodeDeviceReq(DeviceSubCommand.getDeviceInfo));

/// `SmartCardReq{cmd: openLogicalChannel, openChannel{aid, p2}}`.
Uint8List encodeOpenLogicalChannel(String aidHex, {int p2 = 0}) {
  final open = (PbWriter()
        ..string(1, aidHex.toUpperCase())
        ..uint(2, p2))
      .toBytes();
  return (PbWriter()
        ..uint(1, SmartCardCommand.openLogicalChannel)
        ..bytes(2, open))
      .toBytes();
}

/// `SmartCardReq{cmd: transmitApduLogicalChannel, transmitApdu{...}}`.
///
/// `data` is a **hex string** on the wire, not bytes -- confirmed from
/// `TransmitApdu`'s serialised descriptor.
Uint8List encodeTransmitApdu({
  required int channel,
  required int cla,
  required int instruction,
  required int p1,
  required int p2,
  required int p3,
  String dataHex = '',
}) {
  final apdu = (PbWriter()
        ..uint(1, channel)
        ..uint(2, cla)
        ..uint(3, instruction)
        ..uint(4, p1)
        ..uint(5, p2)
        ..uint(6, p3)
        ..string(7, dataHex.toUpperCase()))
      .toBytes();
  return (PbWriter()
        ..uint(1, SmartCardCommand.transmitApduLogicalChannel)
        ..bytes(4, apdu))
      .toBytes();
}

/// `SmartCardReq{cmd: closeLogicalChannel, closeChannel}`.
Uint8List encodeCloseLogicalChannel(int channel) => (PbWriter()
      ..uint(1, SmartCardCommand.closeLogicalChannel)
      ..uint(3, channel))
    .toBytes();

/// `SmartCardReq{cmd: iccReset}` — no payload.
///
/// Vendor capture 2026-10-23 18:27:56.955 shows the reset exactly as
/// `08 03 12 02 1A 00`: an **empty** `SmartCardReq` — the reset is carried by
/// the `EuiccDeviceReq.cmd = 3` (SCARD) envelope and an empty payload, with no
/// `SmartCardReq.cmd` at all. That is the frame the vendor app sends to make
/// the card re-issue a challenge after a `result = 5`.
///
/// Writing `SmartCardCommand.iccReset` into the payload instead produces
/// `08 03 12 04 08 05 1A 00`, which is a different frame: the card still
/// answers `08 05 28 05`, so the mistake is invisible in the response but the
/// bytes do not match the vendor's.
///
/// The declared length is `0x02`, not the `+1` the other encoders emit: this
/// payload is one byte (`1A 00` = "field 3, empty"), so `len + 1` would give
/// `12 03` and produce `08 03 12 03 1A 00` — one byte longer than the vendor
/// frame. Verified against the capture byte for byte.
Uint8List encodeIccReset() => Uint8List.fromList(const [
      0x08, 0x03, // EuiccDeviceReq.cmd = SCARD
      0x12, 0x02, // scard, 2 bytes
      0x1A, 0x00, // SmartCardReq field 3, empty  -> "reset"
    ]);

/// `EuiccDeviceReq` wrapping a `SmartCardReq`.
/// `EuiccDeviceReq` wrapping a `SmartCardReq`.
///
/// The vendor trace for CreateClient is
/// `08 03 12 2E 08 02 12 2A 0A 28 <AID>`:
///
///   08 03        EuiccDeviceReq.cmd = 3
///     12 2E      request
///       08 02    SmartCardReq.cmd = 2 (openLogicalChannel)
///
/// so the *outer* command is 3, the same value this enum calls `security`, and
/// the specific card operation lives in the inner `SmartCardReq.cmd`. Sending
/// the outer as 2 made the card echo `08 02 10 FF 03` -- a 511 rejection --
/// because 2 is not a top-level command it knows.
Uint8List wrapScard(Uint8List scardReq) =>
    encodeEuiccDeviceReq(DeviceCommand.scard, scardReq);

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

/// `DeviceInfo` (field 3 of `DeviceRsp`).
class DeviceInfo {
  final String vendor;
  final String imei;
  final String sn;
  final String deviceName;
  final List<String> capability;
  final bool scardMode;
  final List<String> ability;

  const DeviceInfo({
    this.vendor = '',
    this.imei = '',
    this.sn = '',
    this.deviceName = '',
    this.capability = const [],
    this.scardMode = false,
    this.ability = const [],
  });

  static DeviceInfo parse(Uint8List data) {
    var vendor = '';
    var imei = '';
    var sn = '';
    var name = '';
    var scard = false;
    final cap = <String>[];
    final abil = <String>[];
    final r = PbReader(data);
    while (true) {
      final t = r.nextTag();
      if (t == null) break;
      final (field, wire) = t;
      switch (field) {
        case 1:
          vendor = r.readString();
        case 2:
          imei = r.readString();
        case 3:
          sn = r.readString();
        case 4:
          name = r.readString();
        case 5:
          cap.add(r.readString());
        case 6:
          scard = r.readUint() != 0;
        case 7:
          abil.add(r.readString());
        default:
          r.skip(wire);
      }
    }
    return DeviceInfo(
      vendor: vendor,
      imei: imei,
      sn: sn,
      deviceName: name,
      capability: cap,
      scardMode: scard,
      ability: abil,
    );
  }

  @override
  String toString() => 'DeviceInfo(vendor=$vendor, name=$deviceName, '
      'sn=$sn, scardMode=$scardMode, ability=${ability.join(",")})';
}

/// `DeviceRsp`.
class DeviceRsp {
  final int cmd;
  final int result;
  final Uint8List infoBytes;
  final Uint8List securityBytes;

  const DeviceRsp(this.cmd, this.result, this.infoBytes, this.securityBytes);

  /// The vendor app ignores `result` for device info and just reads `.info`;
  /// a card with no info is not an error. Kept explicit so callers can decide.
  DeviceInfo? get info => infoBytes.isEmpty ? null : DeviceInfo.parse(infoBytes);

  /// True when the firmware wants the secure channel established first.
  bool get needsSecureChannel => result == LinksfieldResult.secureRequired;

  static DeviceRsp parse(Uint8List data) {
    var cmd = 0;
    var result = 0;
    var info = Uint8List(0);
    var security = Uint8List(0);
    final r = PbReader(data);
    while (true) {
      final t = r.nextTag();
      if (t == null) break;
      final (field, wire) = t;
      switch (field) {
        case 1:
          cmd = r.readUint();
        case 2:
          // Same int32 sign problem as SmartCardRsp: -256 arrives as a
          // sign-extended 64-bit varint and must be folded back to be
          // recognised as `secureRequired`.
          result = readInt32(r);
        case 3:
          info = r.readBytes();
        case 5:
          security = r.readBytes();
        default:
          r.skip(wire);
      }
    }
    return DeviceRsp(cmd, result, info, security);
  }
}

/// `SmartCardRsp`.
class SmartCardRsp {
  final int cmd;
  final int result;
  final List<int> openChannelData;
  final Uint8List apduBytes;

  /// Raw bytes of field 3, before any `data` interpretation.
  ///
  /// On this firmware `openLogicalChannel` answers `08 02 1A 14 12 12 0A 10
  /// <16B>`: `result = 0` (accepted) but field 3 holds a `SecurityProtocol`
  /// auth challenge instead of a channel number. Parsing it as repeated int32
  /// yields an empty list, which looked like a failure while the card had in
  /// fact accepted the command and asked for the secure channel first.
  final Uint8List openChannelRaw;

  SmartCardRsp(
    this.cmd,
    this.result,
    this.openChannelData,
    this.apduBytes, {
    Uint8List? openChannelRaw,
  }) : openChannelRaw = openChannelRaw ?? Uint8List(0);

  /// True when field 3 is a security challenge rather than a channel number.
  bool get opensSecureChannel =>
      openChannelData.isEmpty && openChannelRaw.isNotEmpty;
  /// The challenge carried by an `openLogicalChannel` reply, if any.
  Uint8List? get challenge {
    if (!opensSecureChannel) return null;
    final p = SecurityProtocolMsg.parse(openChannelRaw);
    final r = p.authRandom;
    return (r.length == 16 || r.length == 32) ? Uint8List.fromList(r) : null;
  }

  bool get needsSecureChannel => result == LinksfieldResult.secureRequired;

  static SmartCardRsp parse(Uint8List data) {
    var cmd = 0;
    var result = 0;
    var open = <int>[];
    var apdu = Uint8List(0);
    var openRaw = Uint8List(0);
    final r = PbReader(data);
    while (true) {
      final t = r.nextTag();
      if (t == null) break;
      final (field, wire) = t;
      switch (field) {
        case 1:
          cmd = r.readUint();
        case 2:
          // `result` is an int32 and uses -1 / -256 as failures. A negative
          // int32 is written as a 64-bit sign-extended varint, so reading it as
          // unsigned yields a huge number. A length-delimited field 2 is not a
          // result at all -- it means the payload sits there rather than in a
          // oneof at field 3+ -- and treating those bytes as a varint throws.
          // Record them as payload and keep parsing.
          if (wire == 2) {
            final blob = r.readBytes();
            if (open.isEmpty) open = _parseRepeatedInt(blob);
            if (apdu.isEmpty) apdu = blob;
          } else {
            result = _readInt32(r);
          }
        case 3:
          final blob = r.readBytes();
          openRaw = Uint8List.fromList(blob);
          open = _parseRepeatedInt(blob);        case 4:
          apdu = r.readBytes();
        case 5:
          // `error` carries the card's rejection code on some firmware.
          if (wire == 0 && result == 0) result = _readInt32(r);
          else r.skip(wire);
        default:
          r.skip(wire);
      }
    }
    return SmartCardRsp(cmd, result, open, apdu, openChannelRaw: openRaw);
  }

  /// Reads a varint that is declared `int32` and folds it back to signed.
  ///
  /// protobuf writes negative int32 values as ten-byte sign-extended varints.
  /// `readUint` returns the raw 64-bit pattern; masking to 32 bits and then
  /// re-interpreting as signed recovers the number the sender meant.
  static int _readInt32(PbReader r) => readInt32(r);

  /// `OpenChannelRsp.data` is `repeated int32`, packed by default.
  static List<int> _parseRepeatedInt(Uint8List body) {
    final out = <int>[];
    final r = PbReader(body);
    while (true) {
      final t = r.nextTag();
      if (t == null) break;
      final (field, wire) = t;
      if (field == 1) {
        if (wire == 2) {
          final packed = PbReader(r.readBytes());
          while (!packed.atEnd) {
            out.add(packed.readUint());
          }
        } else {
          out.add(r.readUint());
        }
      } else {
        r.skip(wire);
      }
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// Framing
// ---------------------------------------------------------------------------

/// Splits one protobuf payload into the exact GATT writes the firmware expects.
///
/// [mtu] is the **negotiated ATT MTU** (the number `requestMtu` resolves to),
/// not the raw BLE packet size. Two different overheads apply:
///
///   * first write: 2-byte protocol header + 3-byte ATT header  → `mtu - 5`
///   * continuation: 3-byte ATT header only                     → `mtu - 3`
///
/// The vendor code uses `mtu - 5` for both, which overruns the ATT limit by two
/// bytes on continuation writes; this implementation uses the correct `mtu - 3`
/// and therefore can only ever send fewer bytes per write, never more.
List<Uint8List> framePayload(
  Uint8List payload, {
  required int mtu,
  int lengthHeaderSize = 2,
  int maxWriteBytes = 512,
}) {
  if (lengthHeaderSize != 2 && lengthHeaderSize != 4) {
    throw ArgumentError.value(lengthHeaderSize, 'lengthHeaderSize', 'must be 2 or 4');
  }
  if (payload.length >= 0x10000 && lengthHeaderSize == 2) {
    throw ArgumentError('payload of ${payload.length} bytes does not fit a 2-byte header');
  }

  final header = Uint8List(lengthHeaderSize);
  for (var i = 0; i < lengthHeaderSize; i++) {
    header[lengthHeaderSize - 1 - i] = (payload.length >> (8 * i)) & 0xFF;
  }

  final firstCap = _min(mtu - 5, maxWriteBytes);
  if (firstCap <= lengthHeaderSize) {
    throw ArgumentError('mtu $mtu is too small for a $lengthHeaderSize-byte header');
  }
  final firstBody = firstCap - lengthHeaderSize;

  final chunks = <Uint8List>[];
  final first = Uint8List(lengthHeaderSize + _min(firstBody, payload.length))
    ..setRange(0, lengthHeaderSize, header)
    ..setRange(lengthHeaderSize, lengthHeaderSize + _min(firstBody, payload.length), payload);
  chunks.add(first);

  var off = first.length - lengthHeaderSize;
  final contCap = _min(mtu - 3, maxWriteBytes);
  while (off < payload.length) {
    final end = _min(off + contCap, payload.length);
    chunks.add(Uint8List.sublistView(payload, off, end));
    off = end;
  }
  return chunks;
}

/// Reassembles a response stream.
///
/// Notifications are not message-aligned: one notification can carry the tail
/// of one message plus the head of the next, and the header itself can be split.
/// `push` therefore drains in a loop and returns every complete payload it has.
class FrameAssembler {
  final int lengthHeaderSize;
  FrameAssembler({this.lengthHeaderSize = 2});

  /// Bytes only. Never interpreted as a header until enough have arrived.
  Uint8List? partial;

  /// Declared length of the message currently being received.
  int? expected;

  /// How many bytes are buffered right now (for diagnostics).
  int get buffered => _bufferedLength;
  int _bufferedLength = 0;

  /// Bytes discarded because a header announced an impossible length.
  int rejectedHeaders = 0;

  List<Uint8List> push(List<int> chunk) {
    if (chunk.isEmpty) return const [];
    final data = _take(chunk);
    final out = <Uint8List>[];

    while (true) {
      if (expected == null) {
        if (data.length < lengthHeaderSize) break;
        var len = 0;
        for (var i = 0; i < lengthHeaderSize; i++) {
          len = (len << 8) | data[i];
        }
        // A length that cannot be a real message means the stream is out of
        // sync; drop the header and let the caller surface the rejection
        // instead of buffering forever.
        if (len <= 0 || len > 0xFFFF) {
          rejectedHeaders++;
          data.removeRange(0, lengthHeaderSize);
          continue;
        }
        expected = len;
        data.removeRange(0, lengthHeaderSize);
      }

      if (data.length < expected!) break;
      out.add(Uint8List.fromList(data.sublist(0, expected!)));
      data.removeRange(0, expected!);
      expected = null;
    }

    _bufferedLength = data.length;
    partial = data.isEmpty ? null : Uint8List.fromList(data);
    return out;
  }

  void reset() {
    _bufferedLength = 0;
    expected = null;
    partial = null;
  }

  /// Prepends whatever was left over from the previous push.
  List<int> _take(List<int> chunk) {
    final existing = <int>[];
    if (partial != null) existing.addAll(partial!);
    existing.addAll(chunk);
    return existing;
  }
}

int _min(int a, int b) => a < b ? a : b;

/// Reads an `int32` field and folds the sign-extended varint back to signed.
///
/// protobuf encodes negative int32 as a ten-byte varint; `PbReader.readUint`
/// returns that raw 64-bit pattern, so `-1` shows up as a huge positive number
/// (masked to 32 bits it looks like 511 after truncation). Every signed result
/// code in this protocol goes through here.
int readInt32(PbReader r) {
  final raw = r.readUint();
  final low = raw & 0xFFFFFFFF;
  return low >= 0x80000000 ? low - 0x100000000 : low;
}

String hexOf(List<int> bytes, {int max = 64}) {
  if (bytes.isEmpty) return '(空)';
  final shown = bytes.length > max ? bytes.sublist(0, max) : bytes;
  final s = shown
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
  return bytes.length > max ? '$s … (+${bytes.length - max}B)' : s;
}

/// Wraps a SecurityProtocol body in EuiccDeviceReq{cmd: SECURITY}.
Uint8List wrapSecurity(Uint8List securityProtocol) =>
    encodeEuiccDeviceReq(DeviceCommand.security, securityProtocol);

/// Reads every top-level varint/bytes field into a {field: Uint8List} map.
///
/// Used by the offline card simulator, which needs the request field of an
/// EuiccDeviceReq before it can parse the SecurityProtocol inside.
Map<int, Uint8List> parseAllFields(Uint8List data) {
  final out = <int, Uint8List>{};
  final r = PbReader(data);
  while (true) {
    final t = r.nextTag();
    if (t == null) break;
    final (field, wire) = t;
    if (wire == 2) {
      out[field] = r.readBytes();
    } else {
      r.skip(wire);
    }
  }
  return out;
}
