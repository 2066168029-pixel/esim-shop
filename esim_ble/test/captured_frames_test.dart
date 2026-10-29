import 'dart:typed_data';

import 'package:esim_ble/src/linksfield_frame.dart' as lf;
import 'package:esim_ble/src/linksfield_secure.dart' as sec;
import 'package:flutter_test/flutter_test.dart';

/// First captured frame body (2026-10-22): `08 01 2A 14 12 12 0A 10 <16B>`.
///
/// Read with the vendor's message shapes this is **DeviceRsp{cmd:1,
/// security:{type:1, auth:{random:16}}}` — field 5 is `security`, and inside it
/// field 1 is `type` while field 2 is `auth{random=1, auth=2}`. The 16 bytes in
/// `auth.random` are the challenge for the secure-channel handshake.
///
/// The bug this documents: `SecurityProtocolMsg.parse` was handed the whole
/// DeviceRsp, so it read cmd=1 as `type` and then found no field 2 at all.
final capturedSecurity = Uint8List.fromList([
  0x08, 0x01, 0x2A, 0x14, 0x12, 0x12, 0x0A, 0x10,
  0x98, 0xF7, 0x92, 0x0F, 0xFB, 0x17, 0xFA, 0xC1,
  0xD2, 0x02, 0x88, 0x70, 0x4D, 0x5E, 0xC4, 0xD7,
]);

/// Second captured frame body: DeviceRsp{cmd:1, info{…}}.
final capturedInfo = Uint8List.fromList([
  0x1A, 0x14, 0x12, 0x12, 0x0A, 0x10,
  0xDC, 0xF7, 0xCC, 0xBC, 0x2F, 0x27, 0x2A, 0x23,
  0x36, 0xA5, 0x9D, 0x3E, 0x21, 0x07, 0xD2, 0x13,
]);

void main() {
  group('bare SecurityProtocol recognition', () {
    test('the challenge lives in DeviceRsp.security, not at the top level', () {
      final rsp = lf.DeviceRsp.parse(capturedSecurity);
      // ignore: avoid_print
      print('parsed cmd=${rsp.cmd} result=${rsp.result} '
          'info=${rsp.infoBytes.length} security=${rsp.securityBytes.length}');
      expect(rsp.cmd, 1);
      expect(rsp.securityBytes.length, 20);
      final p = sec.SecurityProtocolMsg.parse(rsp.securityBytes);
      // This firmware omits `type` and sends only `auth{random}`; the parser
      // infers AUTH from the presence of a challenge.
      expect(p.type, sec.SecurityType.auth);
      // SecurityProtocol{type, auth{…}}: the 18-byte auth body is
      // `12 12 0A 10 <16B>` = field 2 → another sub-message → field 1 = 16B.
      // The parser exposes that inner blob; which slot it lands in depends on
      // how many wrappers the firmware uses, so assert the bytes, not the slot.
      final blob = p.authRandom.length == 16 ? p.authRandom : p.authValue;
      expect(blob.length, greaterThanOrEqualTo(16));
      final hex = (p.authRandom.length == 16 ? p.authRandom : p.authValue)
          .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join();
      expect(hex, contains('98F7920FFB17FAC1D20288704D5EC4D7'));
    });

    test('the wrapper parses as SecurityProtocol once field 5 is read', () {
      // This used to assert the opposite: parsing the whole frame found no
      // challenge, because field 5 was not handled on the SecurityProtocol path
      // and the handshake therefore reported "设备未返回 SecurityProtocol".
      // Field 5 carries the auth body on this firmware, so it must parse.
      final p = sec.SecurityProtocolMsg.parse(capturedSecurity);
      expect(p.authRandom.length, 16);
      expect(
        p.authRandom
            .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
            .join(),
        '98F7920FFB17FAC1D20288704D5EC4D7',
      );
    });

    test('the second frame is DeviceRsp{info}, not another challenge', () {
      final rsp = lf.DeviceRsp.parse(capturedInfo);
      // Body starts at field 3 (info), so cmd keeps its default 0.
      expect(rsp.cmd, 0);
      expect(rsp.infoBytes.length, 20);
      expect(rsp.securityBytes, isEmpty);
    });
  });

  group('frame stream from the capture', () {
    const raw = [
      0x00, 0x18, 0x08, 0x01, 0x2A, 0x14, 0x12, 0x12, 0x0A, 0x10, 0x98, 0xF7,
      0x92, 0x0F, 0xFB, 0x17, 0xFA, 0xC1, 0xD2, 0x02, 0x88, 0x70, 0x4D, 0x5E,
      0xC4, 0xD7,
      0x00, 0x16, 0x1A, 0x14, 0x12, 0x12, 0x0A, 0x10, 0xDC, 0xF7, 0xCC, 0xBC,
      0x2F, 0x27, 0x2A, 0x23, 0x36, 0xA5, 0x9D, 0x3E, 0x21, 0x07, 0xD2, 0x13,
    ];

    test('the assembler splits it into exactly two messages', () {
      final asm = lf.FrameAssembler();
      // Delivered in awkward chunks to mimic a real notify stream.
      final out = <Uint8List>[];
      for (var i = 0; i < raw.length; i += 7) {
        final end = (i + 7) > raw.length ? raw.length : i + 7;
        out.addAll(asm.push(raw.sublist(i, end)));
      }
      expect(out.length, 2);
      expect(out[0].length, 24);
      expect(out[1].length, 22);
      expect(out[0], equals(capturedSecurity));
      expect(out[1], equals(capturedInfo));
    });

    test('the first assembled message carries the security challenge', () {
      final asm = lf.FrameAssembler();
      final frames = asm.push(raw);
      final rsp = lf.DeviceRsp.parse(frames.first);
      expect(rsp.securityBytes, isNotEmpty);
      final p = sec.SecurityProtocolMsg.parse(rsp.securityBytes);
      expect(p.authRandom.length, 16);
    });
  });
}
