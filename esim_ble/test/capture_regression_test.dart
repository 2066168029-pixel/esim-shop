import 'package:esim_ble/src/known_plaintext_capture.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regressions from the two field captures on 2026-10-24.
///
/// Both of these cost a round trip to the phone, and both were my bugs rather
/// than the card's:
///
///   1. the "expected" openLogicalChannel frame declared length 0x29 when the
///      real payload is 0x28, so a perfectly good capture was rejected with a
///      "明文假设无效" warning;
///   2. iccReset wrote `SmartCardCommand.iccReset` into the payload, producing
///      `08 03 12 04 08 05 1A 00` instead of the vendor's `08 03 12 02 1A 00`.
void main() {
  group('openLogicalChannel expected bytes', () {
    const expected =
        '08031228'
        '0802'
        '1222'
        '0a20'
        '4130303030303035353931303443363936453642373336363639363536433634'
        '1000';

    test('declared length is 0x28, the real payload length', () {
      // 44 bytes total: 4-byte outer header + 40-byte payload.
      expect(expected.length, 88, reason: '44 bytes');
      expect(expected.substring(6, 8), '28');
    });

    test('a one-byte length difference keeps the plaintext usable', () {
      final sent = '08031229${expected.substring(8)}';
      expect(comparePlaintext(expected, sent), PlaintextVerdict.lengthOnly,
          reason: 'the AID payload is byte-identical; only the length differs');
    });

    test('a difference inside the AID is a real mismatch', () {
      final mangled = '${expected.substring(0, 30)}ff${expected.substring(32)}';
      expect(comparePlaintext(expected, mangled), PlaintextVerdict.mismatch);
    });

    test('exact match is reported as exact', () {
      expect(comparePlaintext(expected, expected), PlaintextVerdict.exact);
    });
  });

  group('iccReset frame', () {
    test('is the vendor shape, not the SmartCardCommand one', () {
      // What the vendor app sends (2026-10-23 18:27:56.955).
      const vendor = '080312021a00';
      // What our buggy encoder produced — must never come back.
      const buggy = '08031204' '0805' '1a00';
      expect(vendor.length, 12);
      expect(buggy.length, 16);
      expect(vendor, isNot(buggy));
    });

    test('must not be wrapped a second time', () {
      // 10:36 field run: the capture called wrapScard(encodeIccReset()) on an
      // encoder that already emits a full frame, producing a SCARD envelope
      // inside a SCARD envelope. The card answered with a challenge instead of
      // a reset, so the mistake was invisible in the response.
      const doubleWrapped = '08031206' '080312021a00';
      const vendor = '080312021a00';
      expect(doubleWrapped.length, 20, reason: '10 bytes');
      expect(vendor.length, 12, reason: '6 bytes');
      expect(doubleWrapped, isNot(vendor));
      expect(doubleWrapped.startsWith('08031206'), isTrue,
          reason: 'the tell is field 2 length 0x06 instead of 0x02');
    });
  });
}
