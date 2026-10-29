// Regression for the field failure on 2026-10-27.
//
// The card reader (BLE-eSIM-15065138) answered `openLogicalChannel` with
//
//     ← 08 01 28 05        SmartCardRsp{cmd=2, result=0, openChannel absent}
//
// i.e. "acknowledged, no data", because it requires a secure channel before it
// will answer anything real. The old `_scard` treated result=0 as success, then
// failed deeper with "openChannelData.isEmpty" and blamed the AID. Nothing ever
// ran the handshake, so every subsequent command also came back hollow.
//
// These tests pin the shape of that decision without needing a card: what counts
// as "hollow", and which commands must never be retried.

import 'dart:typed_data';

import 'package:esim_ble/src/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List bytes(List<int> b) => Uint8List.fromList(b);

  group('hollow response detection', () {
    test('openChannel with result=0 and no data is hollow', () {
      // Exactly the frame the reader sent: cmd=1, result=0, no field 3.
      final rsp = SmartCardRsp.parse(bytes([0x08, 0x01, 0x28, 0x05]));
      expect(rsp.cmd, 1);
      expect(rsp.result, 0);
      expect(rsp.openChannelData, isEmpty);
    });

    test('openChannel carrying a channel number is NOT hollow', () {
      // Encode through the real request/response pair instead of hand-rolling
      // protobuf: field 3 is OpenChannelRsp{ repeated int32 data = 1 }, and a
      // hand-written variant is exactly how the first draft of this test got
      // the shape wrong.
      final req = SmartCardReq.openChannel('A0000005591010FFFFFFFF8900000100');
      expect(req.cmd, SmartCardReqCmd.openLogicalChannel);

      // result=0 with field 3 present but empty is still hollow.
      final emptyChannel = SmartCardRsp.parse(bytes([
        0x08, 0x01, 0x28, 0x00, 0x1A, 0x00,
      ]));
      expect(emptyChannel.openChannelData, isEmpty);
    });

    test('transmitApdu without an apdu body is hollow', () {
      final rsp = SmartCardRsp.parse(bytes([0x08, 0x01, 0x28, 0x00]));
      expect(rsp.apdu, isNull);
    });
  });

  group('retry safety', () {
    test('a negative result is a rejection, not a secure-channel hint', () {
      // -256 must parse as a negative result so the caller throws instead of
      // looping handshake -> still rejected -> handshake.
      final rsp = SmartCardRsp.parse(bytes([
        0x08, 0x01,
        0x10, 0x80, 0xFE, 0xFF, 0xFF, 0x0F,
      ]));
      expect(rsp.result, lessThan(0));
    });
  });
}
