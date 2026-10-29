/// Card session with automatic secure-channel negotiation.
///
/// Stock cards accept plaintext frames. Cards that advertise
/// `secureCommunication` reject them, so instead of asking the user which mode
/// to use, the session sends the first request in the clear and, if the device
/// answers with a malformed/error frame, retries over an authenticated session.
///
/// This keeps the happy path a single round trip and still works on locked
/// cards without any configuration.
library;

import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_transport.dart';
import 'constants.dart';
import 'crypto.dart';
import 'handshake.dart';
import 'hexdump.dart';
import 'messages.dart';
import 'secure_channel.dart';


/// Removed: there is no default PSK.
///
/// This used to alias `secure_channel.defaultPsk` (`Linksfield@Esim#2025`) and
/// served as the fallback for [CardSession.open] and [CardSession.attach].
/// That fallback is gone: deployed cards are provisioned with their own
/// password, and a wrong guess surfaces as a fresh challenge instead of UPDATE
/// -- indistinguishable from a protocol bug, and it cost days. Password is now a
/// required argument.

class CardError implements Exception {
  final String message;
  final int? sw;
  CardError(this.message, [this.sw]);
  @override
  String toString() => sw == null
      ? 'CardError: $message'
      : 'CardError: $message (SW=${sw!.toRadixString(16).toUpperCase()})';
}

/// Thin typed wrapper over [CardConnection].
class CardSession {
  final CardConnection _conn;

  /// Password used for the secure handshake when the card demands one.
  final String password;

  SecureSession? _secure;
  bool _secureAttempted = false;

  CardSession._(this._conn, this.password);

  /// Wraps an existing connection (used by the SGP.22 transport adapter).
  ///
  /// The session is stateless until [selectIsdr] runs, so attaching is free.
  /// [password] is required: no default PSK is substituted.
  factory CardSession.attach(CardConnection conn, {required String password}) =>
      CardSession._(conn, password);

  /// Connects and probes the card for secure mode.
  ///
  /// [pin] is the Bluetooth pairing code printed on the card. The plugin turns
  /// it into `device.setPin(...)` when Android raises the pairing request, which
  /// is the only way to pair without user interaction.
  ///
  /// [password] is the card's PSK and is required — see [lpadDefaultPassword].
  static Future<CardSession> open(
    BluetoothDevice device, {
    required String password,
    String? pin,
  }) async {
    final conn = await CardConnection.open(device, pin: pin);
    return CardSession._(conn, password);
  }

  int get channel => _channel;

  /// Logical channel id assigned by MANAGE CHANNEL, 0 until [selectIsdr].
  int _channel = 0;
  bool _isdrSelected = false;

  /// True once a logical channel to the ISD-R applet is open.
  bool get isIsdrSelected => _isdrSelected;

  bool get isSecure => _secure != null;

  /// True once the card has answered anything, proving the link works.
  bool _probed = false;

  /// Probes the card with a device-info request.
  ///
  /// This must happen before any APDU: the greeting doubles as the secure-mode
  /// detection, because a locked card rejects even COMMAND_DEVICE until the
  /// session is established. Calling it explicitly lets the UI surface
  /// connection problems before it starts issuing card commands.
  ///
  /// A card that answers without a DeviceInfo payload is not an error -- the
  /// vendor app treats missing info as "unknown device" and carries on -- so
  /// this returns null in that case rather than throwing.
  Future<DeviceInfo?> probe() async {
    final info = await deviceInfo();
    _probed = true;
    return info;
  }

  bool get hasProbed => _probed;

  /// Wraps [plain] in SecurityData when a session is established.
  Uint8List _wrap(Uint8List plain) {
    final s = _secure;
    if (s == null) return plain;

    final counter = s.id + 1;
    final nonce = s.nonceFor(counter);
    final ciphertext = aesCcmEncrypt(
      key: s.sessionKey,
      nonce: nonce,
      plaintext: plain,
      aad: s.aad,
    );
    _secure = SecureSession(counter, s.sessionKey, s.initNonce, s.aad);

    // SecurityData { id: 1, enc: 2, encsec: 4 }
    final w = _ProtoOut()
      ..int32(1, counter)
      ..bytes(2, ciphertext);
    return Uint8List.fromList(w.bytes_);
  }

  /// Unwraps a SecurityData response, or returns [raw] unchanged.
  Uint8List _unwrap(Uint8List raw) {
    final s = _secure;
    if (s == null) return raw;

    // Try to read it as SecurityData { id, enc, encsec }; if the parse does not
    // look like one, hand the bytes back untouched so the caller can surface
    // them in an error.
    try {
      final parsed = _readSecurityData(raw);
      if (parsed == null) return raw;
      final nonce = s.nonceFor(_secure!.id);
      final plain = aesCcmDecrypt(
        key: s.sessionKey,
        nonce: nonce,
        ciphertext: parsed.ciphertext,
        aad: s.aad,
      );
      return plain;
    } catch (_) {
      return raw;
    }
  }

  /// Sends a request, transparently handling the secure fallback.
  Future<Uint8List> _send(Uint8List payload) async {
    if (_secure != null) {
      return _unwrap(await _conn.request(_wrap(payload)));
    }

    final raw = await _conn.request(payload);
    if (_secureAttempted || _looksValid(raw)) return raw;

    // Plaintext was rejected outright (structurally impossible frame).
    _secureAttempted = true;
    await _establishSecure();
    return _unwrap(await _conn.request(_wrap(payload)));
  }

  /// Runs the handshake exactly once, then retries [retry] on the secure link.
  ///
  /// Used by callers that can tell "acknowledged but hollow" apart from a real
  /// answer -- only they have the parsed fields to check.
  Future<T> _withSecureRetry<T>(Future<T> Function() retry) async {
    if (_secureAttempted) return retry();
    _secureAttempted = true;
    await _establishSecure();
    return retry();
  }

  /// Cheap sanity check: does [raw] parse as a DeviceRsp at all?
  ///
  /// Field 1 (result, varint) or field 2 (response, bytes) must be the first
  /// tag. A card in secure mode answers with SecurityData instead, which starts
  /// with field 1 as a varint too -- so this only catches frames that are
  /// structurally impossible, and the secure fallback also triggers on a parse
  /// failure in the caller.
  static bool _looksValid(Uint8List raw) {
    if (raw.isEmpty) return false;
    final field = raw[0] >> 3;
    final wire = raw[0] & 7;
    if (field != 1 && field != 2) return false;
    // Field 1 is a varint, field 2 length-delimited. Anything else is garbage.
    if (field == 1 && wire != 0) return false;
    if (field == 2 && wire != 2) return false;
    return true;
  }

  /// Runs the three-step AUTH/UPDATE handshake.
  Future<void> _establishSecure() async {
    final pskKey = derivePsk(password);

    // Step 1: ask the device for a challenge.
    final start = encodeDeviceReq(DeviceCommand.security, encodeAuthStart());
    final rsp1 = await _conn.request(start);

    final DeviceRsp outer1;
    try {
      outer1 = DeviceRsp.parse(rsp1);
    } on FormatException catch (e) {
      throw CardError(
        '握手响应解析失败（${e.message}）\n'
        '总长度: ${rsp1.length} 字节\n${_hexHead(rsp1)}',
      );
    }
    final reply1 = SecurityProtocolReply.parse(outer1.response);

    if (reply1.type != SecurityType.auth || reply1.authRandom.isEmpty) {
      throw CardError(
        '卡片要求安全通道，但握手未返回挑战值\n'
        '响应 (${outer1.response.length}B):\n${hexDump(outer1.response)}',
      );
    }

    // Step 2: prove we know the PSK.
    final pcNonce = randomBytes(32);
    final proof = buildProof(pskKey, reply1.authRandom, pcNonce);
    final step2 = encodeDeviceReq(
      DeviceCommand.security,
      encodeAuthReq(pcNonce, proof),
    );
    final rsp2 = await _conn.request(step2);

    final DeviceRsp outer2;
    try {
      outer2 = DeviceRsp.parse(rsp2);
    } on FormatException catch (e) {
      throw CardError(
        '握手第二步响应解析失败（${e.message}）\n'
        '总长度: ${rsp2.length} 字节\n${_hexHead(rsp2)}',
      );
    }
    final reply2 = SecurityProtocolReply.parse(outer2.response);

    // Step 3: accept the session keys from the UPDATE message.
    final session = deriveSession(
      challenge: reply1.authRandom,
      pskKey: pskKey,
      pcNonce: pcNonce,
      deviceConfigNonce: reply2.configNonce,
      deviceConfigAad: reply2.configAad,
      deviceConfigAuth: reply2.configAuth,
    );
    _secure = session;
  }

  /// Sends a COMMAND_SCARD / SmartCardReq and returns the parsed response.
  ///
  /// There is no outer envelope on this path: the device answers with a bare
  /// SmartCardRsp, which the vendor client parses directly
  /// (k3.onComplete -> `a(0, bArr)` where bArr is the SmartCardRsp bytes).
  /// Wrapping it in DeviceRsp first shifts every field by one level and yields
  /// a bogus cmd=0/result=0 with an empty body.
  Future<SmartCardRsp> _scard(SmartCardReq req) async {
    final payload = encodeDeviceReq(DeviceCommand.scard, req.encode());

    SmartCardRsp parseOrThrow(Uint8List raw) {
      final SmartCardRsp sc;
      try {
        sc = SmartCardRsp.parse(raw);
      } on FormatException catch (e) {
        throw CardError('SmartCardRsp 解析失败（${e.message}）\n'
            '响应字节 (${raw.length}B):\n${hexDump(raw)}');
      }

      // -256 is the firmware's "secure channel required" sentinel.
      if (sc.result == -256) {
        throw CardError('卡片要求安全通道');
      }
      if (sc.result < 0) {
        throw CardError('Card rejected the command (result=${sc.result})');
      }
      return sc;
    }

    var sc = parseOrThrow(await _send(payload));

    // The real trap on this hardware: a card that requires a secure channel
    // answers every plaintext SCARD command with `result=0` and *no data*.
    //
    //   → 08 03 12 3C 08 01 1A 38 ...   (openChannel to ISD-R)
    //   ← 08 01 28 05                    (cmd=2, result=0, openChannel absent)
    //
    // result=0 reads as success, so the old code sailed past it and then failed
    // deeper with "openChannelData.isEmpty", pointing the finger at the AID or
    // the channel handling. The command was in fact understood and deliberately
    // left unanswered until we authenticate.
    if (_secure == null && _isHollow(sc, req)) {
      sc = await _withSecureRetry(
        () async => parseOrThrow(await _send(payload)),
      );
    }

    return sc;
  }

  /// True when [rsp] acknowledges the command but carries none of the data that
  /// command is supposed to return.
  static bool _isHollow(SmartCardRsp rsp, SmartCardReq req) {
    switch (req.cmd) {
      case SmartCardReqCmd.openLogicalChannel:
        return rsp.openChannelData.isEmpty;
      case SmartCardReqCmd.transmitApduLogicalChannel:
        return rsp.apdu == null;
      default:
        // Close returns no payload legitimately; nothing to infer.
        return false;
    }
  }

  /// Reads vendor/IMEI/SN and capability list, or null if the card does not
  /// report any.
  Future<DeviceInfo?> deviceInfo() async {
    final body = encodeDeviceSubReq(DeviceSubCommand.getDeviceInfo);
    final payload = encodeDeviceReq(DeviceCommand.device, body);
    final raw = await _send(payload);

    final DeviceRsp rsp;
    try {
      rsp = DeviceRsp.parse(raw);
    } on FormatException catch (e) {
      // The most useful diagnostic is the head of the frame: a length prefix we
      // mis-read shows up immediately in the first bytes.
      final head = raw.length > 24 ? raw.sublist(0, 24) : raw;
      throw CardError(
        '响应解析失败（${e.message}）\n'
        '总长度: ${raw.length} 字节\n'
        '前${head.length}字节: ${head.map((b) => b.toRadixString(16).padLeft(2, "0").toUpperCase()).join(" ")}',
      );
    }

    // The firmware's Result enum is not a reliable success signal: the vendor
    // app ignores it entirely and just reads `.getInfo()` off the response
    // (AbstractPbDevice.getDeviceInfo). A card that answers with an empty
    // payload simply has no info to report; that is not a failure.
    final info = DeviceInfoRsp.parse(rsp.response);
    return info.info;
  }

  /// Selects the ISD-R applet by opening a logical channel to it.
  ///
  /// A bare SELECT on the basic channel is rejected by this firmware, so the
  /// MANAGE CHANNEL path is the only one that works. The response carries the
  /// channel number as a list of integers; the first entry is the one to use,
  /// and subsequent APDUs must OR it into CLA.
  Future<void> selectIsdr() async {
    final opened = await _scard(SmartCardReq.openChannel(_hex(isdrAid)));
    if (!opened.isOk || opened.openChannelData.isEmpty) {
      throw CardError(
        '无法打开 ISD-R 逻辑通道（result=${opened.result}）\n'
        '响应字节:\n${hexDump(opened.raw)}',
      );
    }
    _channel = opened.openChannelData.first & 0xFF;
    _isdrSelected = true;
  }

  /// Closes the logical channel to ISD-R.
  Future<void> closeChannel(int channel) async {
    if (channel <= 0) return;
    await _scard(SmartCardReq.closeChannel(channel));
    _channel = 0;
    _isdrSelected = false;
  }

  /// Sends an APDU and returns the parsed response.
  ///
  /// Logical channels require the channel id in the low bits of CLA, so the
  /// channel is ORed in automatically once it is known.
  Future<TransmitApduRsp> transmit(TransmitApdu apdu) async {
    final effective = (_channel != 0 && apdu.channel == 0)
        ? TransmitApdu(
            channel: _channel,
            cla: apdu.cla | _channel,
            instruction: apdu.instruction,
            p1: apdu.p1,
            p2: apdu.p2,
            p3: apdu.p3,
            dataHex: apdu.dataHex,
          )
        : apdu;

    final rsp = await _scard(SmartCardReq.apdu(effective));
    final a = rsp.apdu;
    if (a == null) {
      throw CardError(
        '卡片未返回 APDU 响应\n'
        'SmartCardRsp: cmd=${rsp.cmd} result=${rsp.result}\n'
        '响应字节:\n${hexDump(rsp.raw)}',
      );
    }
    return a;
  }

  /// Sends an APDU and requires 9000, handling 61XX GET RESPONSE.
  Future<Uint8List> transmitOk(TransmitApdu apdu) async {
    var rsp = await transmit(apdu);
    final out = BytesBuilder();
    var guard = 0;
    while (true) {
      out.add(rsp.payload);
      if (rsp.isOk) return out.toBytes();
      if (rsp.hasMoreData) {
        if (guard++ > 20) throw CardError('GET RESPONSE loop');
        rsp = await transmit(TransmitApdu(
          channel: apdu.channel,
          cla: apdu.cla,
          instruction: 0xC0,
          p3: rsp.sw2,
        ));
        continue;
      }
      throw CardError('APDU failed', rsp.sw);
    }
  }

  Future<void> close() => _conn.close();

  static String _hex(List<int> b) =>
      b.map((e) => e.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

  /// Formats the first bytes of a frame for an error message.
  static String _hexHead(Uint8List raw, {int max = 24}) {
    final n = raw.length < max ? raw.length : max;
    final head = raw.sublist(0, n)
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
    return '前$n字节: $head';
  }
}

/// Minimal protobuf writer, duplicated here to keep this file self-contained.
class _ProtoOut {
  final _buf = BytesBuilder();

  void _varint(int v) {
    var x = v;
    while (x >= 0x80) {
      _buf.addByte((x & 0x7F) | 0x80);
      x >>= 7;
    }
    _buf.addByte(x & 0x7F);
  }

  _ProtoOut int32(int field, int value) {
    _varint(field << 3);
    _varint(value);
    return this;
  }

  _ProtoOut bytes(int field, List<int> value) {
    _varint((field << 3) | 2);
    _varint(value.length);
    _buf.add(value);
    return this;
  }

  List<int> get bytes_ => _buf.toBytes();
}

/// Reads `SecurityData { id, enc, encsec }`, returning null when the buffer is
/// not shaped like one.
_SecurityData? _readSecurityData(Uint8List data) {
  if (data.isEmpty) return null;
  var pos = 0;
  var sawEnc = false;
  Uint8List? cipher;

  int? varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (pos >= data.length) return null;
      final b = data[pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
      if (shift > 63) return null;
    }
  }

  while (pos < data.length) {
    final tag = varint();
    if (tag == null) return null;
    final field = tag >> 3;
    final wire = tag & 7;
    if (wire == 0) {
      if (varint() == null) return null;
    } else if (wire == 2) {
      final len = varint();
      if (len == null || pos + len > data.length) return null;
      if (field == 2 || field == 4) {
        cipher = Uint8List.sublistView(data, pos, pos + len);
        sawEnc = true;
      }
      pos += len;
    } else {
      return null;
    }
  }

  if (!sawEnc || cipher == null) return null;
  return _SecurityData(cipher);
}

class _SecurityData {
  final Uint8List ciphertext;
  _SecurityData(this.ciphertext);
}
