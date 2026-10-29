import 'dart:typed_data';

import 'package:esim_ble/src/linksfield_frame.dart' as lf;
import 'package:flutter_test/flutter_test.dart';

/// Encodes a varint the way protobuf does for a negative int32: sign-extended
/// to 64 bits, so `-1` becomes the ten-byte `FF FF FF FF FF FF FF FF FF 01`.
List<int> signedVarint(int value) {
  var v = value & 0xFFFFFFFFFFFFFFFF; // two's complement, 64-bit
  final out = <int>[];
  while (true) {
    final b = v & 0x7F;
    // Dart's int is 64-bit signed; shifting an unsigned-looking value needs a
    // logical shift, which is what the mask + divide reproduces.
    v = (v >> 7) & 0x01FFFFFFFFFFFFFF;
    if (v == 0) {
      out.add(b);
      return out;
    }
    out.add(b | 0x80);
  }
}

void main() {
  group('signed result codes', () {
    test('SmartCardRsp result -1 round-trips as -1, not 511', () {
      // This is the value a real card returns for an unsupported command.
      // Reading it unsigned once produced `result=511`, which sent the
      // investigation looking for a field-number problem that did not exist.
      final bytes = Uint8List.fromList([
        0x08, 0x01, // cmd = 1
        0x10, ...signedVarint(-1), // result = -1
      ]);
      final rsp = lf.SmartCardRsp.parse(bytes);
      expect(rsp.cmd, 1);
      expect(rsp.result, -1);
    });

    test('SmartCardRsp result -256 is recognised as secureRequired', () {
      final bytes = Uint8List.fromList([
        0x08, 0x01,
        0x10, ...signedVarint(-256),
      ]);
      final rsp = lf.SmartCardRsp.parse(bytes);
      expect(rsp.result, -256);
      expect(rsp.needsSecureChannel, isTrue);
    });

    test('positive results are unaffected', () {
      final bytes = Uint8List.fromList([0x08, 0x01, 0x10, 0x00]);
      expect(lf.SmartCardRsp.parse(bytes).result, 0);
    });

    test('DeviceRsp result -256 is recognised as secureRequired', () {
      final bytes = Uint8List.fromList([
        0x08, 0x01,
        0x10, ...signedVarint(-256),
      ]);
      final rsp = lf.DeviceRsp.parse(bytes);
      expect(rsp.result, -256);
      expect(rsp.needsSecureChannel, isTrue);
    });
  });
}
