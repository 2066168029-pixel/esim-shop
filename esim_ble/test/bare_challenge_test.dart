import 'dart:typed_data';

import 'package:esim_ble/src/linksfield_frame.dart' as lf;
import 'package:esim_ble/src/linksfield_secure.dart' as sec;
import 'package:flutter_test/flutter_test.dart';

/// The 2026-10-22 capture, as it actually arrives: **bare** SecurityProtocol
/// frames with no `DeviceRsp` wrapper.
///
///   stream: `00 18 <24B>` then `00 16 <22B>` then `00 16 <22B>`
///
/// The first body is `08 01 2A 14 12 12 0A 10 <16B>` -- field 1 = type (1),
/// field 5 = the 20-byte auth blob. The two that follow are
/// `1A 14 12 12 0A 10 <16B>` -- field 3 = a 20-byte blob, which is the same
/// auth message under a different outer field number.
///
/// The bug this pins down: the handshake code went through `DeviceRsp.parse`,
/// looked for `securityBytes` (field 5), and treated the *two field-3 frames* as
/// "no SecurityProtocol" and gave up. The card was answering the whole time.
final bareChallenge = Uint8List.fromList([
  0x08, 0x01, 0x2A, 0x14, 0x12, 0x12, 0x0A, 0x10, //
  0xF9, 0x65, 0xD2, 0x7C, 0xD8, 0x90, 0xB0, 0x9E,
  0x3B, 0x4C, 0x16, 0xBD, 0x12, 0x66, 0xD4, 0x99,
]);

final bareChallenge2 = Uint8List.fromList([
  0x1A, 0x14, 0x12, 0x12, 0x0A, 0x10, //
  0x8D, 0x34, 0xFC, 0xCF, 0x1C, 0x75, 0xCE, 0x2B,
  0x6F, 0xAF, 0x2A, 0xB3, 0x76, 0x0C, 0x8D, 0x4B,
]);

final bareChallenge3 = Uint8List.fromList([
  0x1A, 0x14, 0x12, 0x12, 0x0A, 0x10, //
  0x61, 0xD1, 0x30, 0xBA, 0xA0, 0xEE, 0x54, 0x3D,
  0xE3, 0x52, 0x6A, 0xA3, 0x1A, 0xF2, 0x94, 0x4C,
]);

const raw = [
  0x00, 0x18, 0x08, 0x01, 0x2A, 0x14, 0x12, 0x12, 0x0A, 0x10, 0xF9, 0x65, //
  0xD2, 0x7C, 0xD8, 0x90, 0xB0, 0x9E, 0x3B, 0x4C, 0x16, 0xBD, 0x12, 0x66,
  0xD4, 0x99,
  0x00, 0x16, 0x1A, 0x14, 0x12, 0x12, 0x0A, 0x10, 0x8D, 0x34, 0xFC, 0xCF,
  0x1C, 0x75, 0xCE, 0x2B, 0x6F, 0xAF, 0x2A, 0xB3, 0x76, 0x0C, 0x8D, 0x4B,
  0x00, 0x16, 0x1A, 0x14, 0x12, 0x12, 0x0A, 0x10, 0x61, 0xD1, 0x30, 0xBA,
  0xA0, 0xEE, 0x54, 0x3D, 0xE3, 0x52, 0x6A, 0xA3, 0x1A, 0xF2, 0x94, 0x4C,
];

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join();

void main() {
  group('bare challenge capture (2026-10-22)', () {
    test('the stream splits into the three frames the log showed', () {
      final frames = lf.FrameAssembler().push(raw);
      expect(frames.length, 3);
      expect(frames[0].length, 24);
      expect(frames[1].length, 22);
      expect(frames[2].length, 22);
      expect(frames[0], equals(bareChallenge));
      expect(frames[1], equals(bareChallenge2));
      expect(frames[2], equals(bareChallenge3));
    });

    test('the 16-byte random is recoverable from every frame', () {
      for (final frame in [bareChallenge, bareChallenge2, bareChallenge3]) {
        final p = sec.SecurityProtocolMsg.parse(frame);
        final leaf = p.authRandom.length == 16
            ? p.authRandom
            : p.authValue.length == 16
                ? p.authValue
                : const <int>[];
        expect(leaf.length, 16, reason: 'no 16-byte leaf in ${hex(frame)}');
      }
    });

    test('frame 1 keeps its challenge in authRandom, not authValue', () {
      // Field 5 of the first body holds the auth blob. Its field numbers are
      // auth's own (1/2), so a challenge must land in the random slot -- the
      // handshake uses exactly that value for the proof.
      final p = sec.SecurityProtocolMsg.parse(bareChallenge);
      expect(hex(p.authRandom), 'F965D27CD890B09E3B4C16BD1266D499');
    });

    test('a field-5-only reader finds security in frame 1 but not in 2/3', () {
      // This is the shape of the old failure: DeviceRsp.parse only looks at
      // field 5, so the two follow-up frames looked like "no SecurityProtocol"
      // and the handshake reported "设备未返回 SecurityProtocol". They are not
      // empty; they merely carry the auth blob at field 3.
      expect(lf.DeviceRsp.parse(bareChallenge).securityBytes, isNotEmpty);
      expect(lf.DeviceRsp.parse(bareChallenge2).securityBytes, isEmpty);
      expect(lf.DeviceRsp.parse(bareChallenge3).securityBytes, isEmpty);
      // But the challenge is there all the same, once the field number is not
      // the thing being looked at.
      for (final frame in [bareChallenge2, bareChallenge3]) {
        final p = sec.SecurityProtocolMsg.parse(frame);
        final leaf = p.authRandom.isNotEmpty ? p.authRandom : p.authValue;
        expect(leaf.length, 16);
      }
    });

    test('three distinct nonces: the card is not repeating one answer', () {
      final seen = <String>{};
      for (final frame in [bareChallenge, bareChallenge2, bareChallenge3]) {
        final p = sec.SecurityProtocolMsg.parse(frame);
        seen.add(hex(p.authRandom.isNotEmpty ? p.authRandom : p.authValue));
      }
      expect(seen.length, 3);
    });
  });
}
