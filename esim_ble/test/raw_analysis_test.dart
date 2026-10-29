import 'package:esim_ble/src/raw_analysis.dart';
import 'package:flutter_test/flutter_test.dart';

/// Captured from the real reader on 2026-10-22: two back-to-back frames, the
/// first carrying SecurityProtocol{AUTH, random}, the second DeviceInfo.
const captured = [
  0x00, 0x18, 0x08, 0x01, 0x2A, 0x14, 0x12, 0x12, 0x0A, 0x10, 0x98, 0xF7,
  0x92, 0x0F, 0xFB, 0x17, 0xFA, 0xC1, 0xD2, 0x02, 0x88, 0x70, 0x4D, 0x5E,
  0xC4, 0xD7,
  0x00, 0x16, 0x1A, 0x14, 0x12, 0x12, 0x0A, 0x10, 0xDC, 0xF7, 0xCC, 0xBC,
  0x2F, 0x27, 0x2A, 0x23, 0x36, 0xA5, 0x9D, 0x3E, 0x21, 0x07, 0xD2, 0x13,
];

void main() {
  group('length-prefixed framing over a stream', () {
    test('two 2-byte-BE frames are both recognised', () {
      final h = hypotheses(captured).firstWhere(
          (x) => x.name.contains('2 字节长度头（BE）'));
      expect(h.plausible, isTrue, reason: h.detail);
      expect(h.detail, contains('2 帧'));
    });

    test('the wrong byte order is rejected', () {
      final h = hypotheses(captured).firstWhere(
          (x) => x.name.contains('2 字节长度头（LE）'));
      expect(h.plausible, isFalse);
    });

    test('a lone frame still parses', () {
      final one = captured.sublist(0, 26);
      final h = hypotheses(one).firstWhere(
          (x) => x.name.contains('2 字节长度头（BE）'));
      expect(h.plausible, isTrue);
      expect(h.detail, contains('1 帧'));
    });

    test('a truncated tail after a complete frame is not a failure', () {
      final cut = [...captured.sublist(0, 26), 0x00, 0x16, 0x1A];
      final h = hypotheses(cut).firstWhere(
          (x) => x.name.contains('2 字节长度头（BE）'));
      expect(h.plausible, isTrue);
      expect(h.detail, contains('尾部'));
    });

    test('content-free junk is not called protobuf', () {
      final junk = List<int>.generate(40, (i) => (i * 37) & 0xFF);
      final h = hypotheses(junk).firstWhere((x) => x.name.contains('裸 protobuf'));
      expect(h.plausible, isFalse);
    });
  });

  group('protobuf reading of the captured bodies', () {
    test('first frame is DeviceRsp{cmd=1, security=…}', () {
      // Body only: drop the 2-byte header.
      // analyseRawBytes explains the message inside the frame once framing is
      // explained; asking it to re-parse a headerless body only tests the
      // length-prefix heuristics.
      final p = analyseRawBytes(captured).join('\n');
      expect(p, contains('第 1 帧内容'), reason: p);
      expect(p, contains('cmd=1'), reason: p);
      expect(p, contains('security'), reason: p);
      expect(p, contains('random(16B)'), reason: p);
    });

    test('analysis always ends with the raw hex', () {
      final out = analyseRawBytes(captured);
      expect(out.last, anyOf(contains('原始'), contains('ASCII')));
      expect(out.join('\n'), contains('原始 50B'));
    });
  });
}
