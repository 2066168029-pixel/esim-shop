import 'package:esim_ble/src/messages.dart';
import 'package:esim_ble/src/proto_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeviceRsp.Result semantics', () {
    test('SUCCESS is 1, not 0', () {
      // The firmware uses SUCCESS=1 / FAIL=0, the inverse of the usual
      // convention. Getting this backwards makes every success look like a
      // failure, which is exactly what happened on the real device.
      expect(DeviceResult.success, 1);
      expect(DeviceResult.fail, 0);
    });

    test('a result=1 frame parses to success', () {
      final w = ProtoWriter();
      w.int32(2, DeviceResult.success);
      final rsp = DeviceRsp.parse(w.toBytes());
      expect(rsp.result, DeviceResult.success);
      expect(rsp.result == DeviceResult.success, isTrue);
    });

    test('a result=0 frame parses to failure', () {
      final w = ProtoWriter();
      w.int32(2, DeviceResult.fail);
      final rsp = DeviceRsp.parse(w.toBytes());
      expect(rsp.result, DeviceResult.fail);
      expect(rsp.result == DeviceResult.success, isFalse);
    });

    test('a result=1 frame carrying device info yields both fields', () {
      final info = ProtoWriter();
      info.string(1, 'Linksfield');
      info.string(4, 'BLE-eSIM v1.0');
      info.string(3, 'SN123');
      info.bool_(6, true);

      final w = ProtoWriter();
      w.int32(2, DeviceResult.success);
      w.bytes(3, info.toBytes());

      final rsp = DeviceRsp.parse(w.toBytes());
      expect(rsp.result, DeviceResult.success);

      // rsp.response already holds the DeviceInfo payload; parse it directly.
      final parsed = DeviceInfoRsp.parse(w.toBytes());
      expect(parsed.result, DeviceResult.success);
      expect(parsed.info, isNotNull);
      expect(parsed.info!.vendor, 'Linksfield');
      expect(parsed.info!.deviceName, 'BLE-eSIM v1.0');
      expect(parsed.info!.sn, 'SN123');
      expect(parsed.info!.scardMode, isTrue);
    });

    test('SmartCardRsp.isOk treats only negative results as failures', () {
      // SmartCardRsp.result is a plain int32. The vendor app checks
      // Math.min(result, 0), so 0 and positives are all "no error".
      final ok = ProtoWriter()..int32(2, 0);
      expect(SmartCardRsp.parse(ok.toBytes()).isOk, isTrue);

      final positive = ProtoWriter()..int32(2, 1);
      expect(SmartCardRsp.parse(positive.toBytes()).isOk, isTrue);

      final bad = ProtoWriter()..int32(2, -3);
      // Negative int32 travels as its 10-byte unsigned 64-bit two's complement.
      expect(bad.toBytes().length, 11); // 1 tag byte + 10 varint bytes
      expect(SmartCardRsp.parse(bad.toBytes()).isOk, isFalse);
    });

    test('SmartCardReq.cmd uses the one-based SmartCardCommand enum', () {
      // 0 is reserved for "unknown", so open starts at 1.
      expect(SmartCardReqCmd.openLogicalChannel, 1);
      expect(SmartCardReqCmd.closeLogicalChannel, 2);
      expect(SmartCardReqCmd.transmitApduLogicalChannel, 3);

      final apduReq = SmartCardReq.apdu(TransmitApdu(
        channel: 0,
        cla: 0x80,
        instruction: 0xE2,
        p1: 0x91,
        p2: 0,
        p3: 0,
      )).encode();
      // First field is cmd = 3 -> tag 0x08, value 0x03
      expect(apduReq[0], 0x08);
      expect(apduReq[1], 0x03);
    });
  });

  group('DeviceReq encoding', () {
    test('getDeviceInfo is sub-command 1', () {
      expect(DeviceSubCommand.getDeviceInfo, 1);
      final body = encodeDeviceSubReq(DeviceSubCommand.getDeviceInfo);
      expect(body, isNotEmpty);
      // DeviceReq { cmd: 1 } -> tag 0x08, value 0x01
      expect(body[0], 0x08);
      expect(body[1], 0x01);
    });

    test('the outer envelope carries cmd=DEVICE and the sub-request', () {
      final body = encodeDeviceSubReq(DeviceSubCommand.getDeviceInfo);
      final outer = encodeDeviceReq(DeviceCommand.device, body);
      // Field 1 (cmd) varint DEVICE=0 -> 0x08 0x00
      expect(outer[0], 0x08);
      expect(outer[1], 0x00);
      // Field 2 (request) length-delimited -> 0x12 <len>
      expect(outer[2], 0x12);
      expect(outer[3], body.length);
    });
  });
}
