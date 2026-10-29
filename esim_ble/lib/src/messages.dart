/// Dart mirrors of the Linksfield LPAd protobuf messages.
///
/// Each class knows how to encode itself and how to parse the response that
/// comes back. Field numbers are taken verbatim from the decompiled
/// com.linksfield.lpad.grpc sources; see proto/linksfield.proto for the
/// annotated definition.
library;

import 'dart:typed_data';

import 'proto_codec.dart';

/// EuiccDeviceReq.Command -- doubles as the top-level discriminator.
class DeviceCommand {
  static const int device = 0;
  static const int euicc = 1;
  static const int scard = 2;
  static const int security = 3;
}

const int _fieldCmd = 1;
const int _fieldRequest = 2;
// DeviceRsp uses its own numbering: cmd=1, result=2, info=3, extend=4,
// security=5. It does NOT mirror the request layout.
const int _rspFieldResult = 2;
const int _rspFieldInfo = 3;

/// Outer request frame: { cmd: Command, request: bytes }.
Uint8List encodeDeviceReq(int cmd, Uint8List? body) {
  final w = ProtoWriter();
  w.int32(_fieldCmd, cmd);
  w.bytes(_fieldRequest, body);
  return w.toBytes();
}

/// Outer response frame: { result: int32, response: bytes }.
class DeviceRsp {
  final int result;
  final Uint8List response;

  DeviceRsp(this.result, this.response);

  static DeviceRsp parse(Uint8List data) {
    var result = 0;
    var response = Uint8List(0);
    final r = ProtoReader(data);
    while (true) {
      final tag = r.nextTag();
      if (tag == null) break;
      final (field, wire) = tag;
      switch (field) {
        case _rspFieldResult:
          result = r.readInt32();
        case _rspFieldInfo:
          response = r.readBytes();
        default:
          r.skip(wire);
      }
    }
    return DeviceRsp(result, response);
  }
}

// ---------------------------------------------------------------------------
// SmartCard
// ---------------------------------------------------------------------------

/// SmartCardReq.cmd -- the SmartCardCommand enum.
///
/// These are NOT zero-based: the firmware reserves 0 for "unknown", so every
/// value sits one higher than the obvious guess.
class SmartCardReqCmd {
  static const int unknown = 0;
  static const int openLogicalChannel = 1;
  static const int closeLogicalChannel = 2;
  static const int transmitApduLogicalChannel = 3;
  static const int iccReset = 4;
  static const int onGetSimFunction = 5;
}

class SmartCardReq {
  final int cmd;
  final String? openChannelAid;
  final int? openChannelP2;
  final int? closeChannel;
  final TransmitApdu? transmitApdu;

  SmartCardReq.openChannel(String aid, {int p2 = 0})
      : cmd = SmartCardReqCmd.openLogicalChannel,
        openChannelAid = aid,
        openChannelP2 = p2,
        closeChannel = null,
        transmitApdu = null;

  SmartCardReq.closeChannel(int channel)
      : cmd = SmartCardReqCmd.closeLogicalChannel,
        openChannelAid = null,
        openChannelP2 = null,
        closeChannel = channel,
        transmitApdu = null;

  SmartCardReq.apdu(TransmitApdu apdu)
      : cmd = SmartCardReqCmd.transmitApduLogicalChannel,
        openChannelAid = null,
        openChannelP2 = null,
        closeChannel = null,
        transmitApdu = apdu;

  Uint8List encode() {
    final w = ProtoWriter();
    w.int32(1, cmd);
    if (openChannelAid != null) {
      // OpenChannel { aid: string, p2: int32 }
      final inner = ProtoWriter()
        ..string(1, openChannelAid)
        ..int32(2, openChannelP2 ?? 0);
      w.message(2, inner.toBytes());
    }
    if (closeChannel != null) {
      w.int32(3, closeChannel);
    }
    if (transmitApdu != null) {
      w.message(4, transmitApdu!.encode());
    }
    return w.toBytes();
  }
}

/// ISO 7816-4 APDU as the firmware expects it. [data] is hex-encoded because
/// the wire field is declared as String in the original.
class TransmitApdu {
  final int channel;
  final int cla;
  final int instruction;
  final int p1;
  final int p2;
  final int p3;
  final String dataHex;

  TransmitApdu({
    required this.channel,
    required this.cla,
    required this.instruction,
    this.p1 = 0,
    this.p2 = 0,
    this.p3 = 0,
    this.dataHex = '',
  });

  Uint8List encode() {
    final w = ProtoWriter();
    w.int32(1, channel);
    w.int32(2, cla);
    w.int32(3, instruction);
    w.int32(4, p1);
    w.int32(5, p2);
    w.int32(6, p3);
    if (dataHex.isNotEmpty) w.string(7, dataHex);
    return w.toBytes();
  }
}

class TransmitApduRsp {
  final int sw1;
  final int sw2;
  final Uint8List payload;

  TransmitApduRsp(this.sw1, this.sw2, this.payload);

  /// True for 0x9000 -- the only success status the LPA applet returns.
  bool get isOk => sw1 == 0x90 && sw2 == 0x00;

  /// 0x61XX means "more data available, issue GET RESPONSE".
  bool get hasMoreData => sw1 == 0x61;

  int get sw => (sw1 << 8) | sw2;

  static TransmitApduRsp parse(Uint8List data) {
    var sw1 = 0;
    var sw2 = 0;
    var payload = Uint8List(0);
    final r = ProtoReader(data);
    while (true) {
      final tag = r.nextTag();
      if (tag == null) break;
      final (field, wire) = tag;
      switch (field) {
        case 1:
          sw1 = r.readInt32();
        case 2:
          sw2 = r.readInt32();
        case 3:
          payload = r.readBytes();
        default:
          r.skip(wire);
      }
    }
    return TransmitApduRsp(sw1, sw2, payload);
  }
}

class SmartCardRsp {
  final int cmd;
  final int result;

  /// OpenChannelRsp.data is `repeated int32`, not bytes -- the first entry is
  /// the logical channel number and the rest is extra payload.
  final List<int> openChannelData;
  final TransmitApduRsp? apdu;
  /// The bytes this was parsed from, kept for diagnostics.
  final Uint8List raw;

  SmartCardRsp(this.cmd, this.result, this.openChannelData, this.apdu,
      [Uint8List? raw])
      : raw = raw ?? Uint8List(0);

  /// Only negative results are failures, matching the vendor app's
  /// `Math.min(result, 0)` check. Positive values carry no error meaning here.
  bool get isOk => result >= 0;

  static SmartCardRsp parse(Uint8List data) {
    var cmd = 0;
    var result = 0;
    var openData = <int>[];
    TransmitApduRsp? apdu;
    final r = ProtoReader(data);
    while (true) {
      final tag = r.nextTag();
      if (tag == null) break;
      final (field, wire) = tag;
      switch (field) {
        case 1:
          cmd = r.readInt32();
        case 2:
          result = r.readInt32();
        case 3:
          // OpenChannelRsp { repeated int32 data = 1 }
          final inner = ProtoReader(r.readBytes());
          while (true) {
            final t2 = inner.nextTag();
            if (t2 == null) break;
            if (t2.$1 == 1) {
              // repeated int32 is packed: a single length-delimited blob of
              // varints -- or, in unpacked form, one varint per tag.
              if (t2.$2 == 2) {
                final packed = ProtoReader(inner.readBytes());
                while (!packed.isAtEnd) {
                  openData.add(packed.readInt32());
                }
              } else {
                openData.add(inner.readInt32());
              }
            } else {
              inner.skip(t2.$2);
            }
          }
        case 4:
          apdu = TransmitApduRsp.parse(r.readBytes());
        default:
          r.skip(wire);
      }
    }
    return SmartCardRsp(cmd, result, openData, apdu, data);
  }
}

// ---------------------------------------------------------------------------
// Device info
// ---------------------------------------------------------------------------

class DeviceInfo {
  final String vendor;
  final String imei;
  final String sn;
  final String deviceName;
  final List<String> capability;
  final bool scardMode;
  final List<String> ability;

  DeviceInfo({
    required this.vendor,
    required this.imei,
    required this.sn,
    required this.deviceName,
    required this.capability,
    required this.scardMode,
    required this.ability,
  });

  static DeviceInfo parse(Uint8List data) {
    var vendor = '';
    var imei = '';
    var sn = '';
    var name = '';
    var scardMode = false;
    final capability = <String>[];
    final ability = <String>[];
    final r = ProtoReader(data);
    while (true) {
      final tag = r.nextTag();
      if (tag == null) break;
      final (field, wire) = tag;
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
          capability.add(r.readString());
        case 6:
          scardMode = r.readBool();
        case 7:
          ability.add(r.readString());
        default:
          r.skip(wire);
      }
    }
    return DeviceInfo(
      vendor: vendor,
      imei: imei,
      sn: sn,
      deviceName: name,
      capability: capability,
      scardMode: scardMode,
      ability: ability,
    );
  }
}

/// DeviceReq.Command -- sub-commands inside COMMAND_DEVICE.
class DeviceSubCommand {
  static const int unknown = 0;
  static const int getDeviceInfo = 1;
  static const int notifyDevice = 2;
  static const int resetDevice = 3;
  static const int deviceExtend = 4;
}

/// Builds `DeviceReq { cmd: <sub> }`.
///
/// Note this is a DIFFERENT message from EuiccDeviceReq: the outer envelope is
/// COMMAND_DEVICE, and its body carries the DeviceCommand enum. Sending an
/// empty body makes the firmware answer with an error, not device info.
Uint8List encodeDeviceSubReq(int subCmd) {
  final w = ProtoWriter();
  w.int32(_fieldCmd, subCmd);
  return w.toBytes();
}

/// DeviceRsp.Result enum values.
///
/// Note the inversion: FAIL is 0 and SUCCESS is 1. Treating 0 as success (the
/// natural JSON/HTTP convention) makes every successful call look like a
/// failure, so the values are spelled out here rather than compared inline.
class DeviceResult {
  static const int fail = 0;
  static const int success = 1;
}

/// Result of a device-info request.
///
/// The wire message is DeviceRsp itself (cmd=1, result=2, info=3), so this is
/// a thin, typed view over it rather than a separate structure.
class DeviceInfoRsp {
  final int result;
  final DeviceInfo? info;

  DeviceInfoRsp(this.result, this.info);

  /// Parses a DeviceRsp frame whose `info` field is expected to be present.
  static DeviceInfoRsp parse(Uint8List data) {
    final rsp = DeviceRsp.parse(data);
    final info = rsp.response.isEmpty ? null : DeviceInfo.parse(rsp.response);
    return DeviceInfoRsp(rsp.result, info);
  }
}

// ---------------------------------------------------------------------------
// Security
// ---------------------------------------------------------------------------
// SecurityType lives in secure_channel.dart; it is the single definition.

/// Builds a SecurityProtocol message. Only needed when the card has security
/// enabled; the default plaintext path never touches this.
Uint8List encodeSecurityProtocol({
  required int type,
  List<int>? psk,
  bool? enableSec,
}) {
  final w = ProtoWriter();
  w.int32(1, type);
  if (psk != null) w.bytes(4, psk);
  if (enableSec != null) w.bool_(5, enableSec);
  return w.toBytes();
}

/// SecurityProtocol as returned by the device.
class SecurityProtocolRsp {
  final int type;
  final bool hasEnableSec;
  final bool enableSec;

  SecurityProtocolRsp(this.type, this.hasEnableSec, this.enableSec);

  static SecurityProtocolRsp parse(Uint8List data) {
    var type = 0;
    var hasEnableSec = false;
    var enableSec = false;
    final r = ProtoReader(data);
    while (true) {
      final tag = r.nextTag();
      if (tag == null) break;
      final (field, wire) = tag;
      switch (field) {
        case 1:
          type = r.readInt32();
        case 5:
          enableSec = r.readBool();
          hasEnableSec = true;
        default:
          r.skip(wire);
      }
    }
    return SecurityProtocolRsp(type, hasEnableSec, enableSec);
  }
}
