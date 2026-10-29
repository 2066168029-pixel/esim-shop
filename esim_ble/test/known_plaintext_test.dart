import 'dart:typed_data';

import 'package:esim_ble/src/known_plaintext.dart';
import 'package:flutter_test/flutter_test.dart';

/// The known-plaintext plan only works if the bytes we "expect to see" are
/// actually derivable. These tests compute them instead of trusting the
/// comment, so a wrong AID or a wrong field length fails here rather than in
/// a log we cannot repeat.
void main() {
  group('known-plaintext capture plan', () {
    test('Linksfield AID is a real vendor constant', () {
      // A00000055910 + ASCII "Linksfield"; found in libapp.so at offset 577799.
      expect(linksfieldAid, 'A000000559104C696E6B736669656C64');
      expect(linksfieldAid.length, 32, reason: '16-byte AID');
      // AID = 16 packed bytes = 32 hex chars. The last 10 bytes are the ASCII
      // string "Linksfield", so the hex from index 12 onward decodes to it:
      // A00000055910 [4C 69 6E 6B 73 66 69 65 6C 64]. Note the prefix is
      // A0 00 00 05 59 10 = 12 hex chars, not 10 -- indexing at 10 gives
      // "\x10Linksfiel", which is the off-by-one this caught.
      final tail = String.fromCharCodes(
        List.generate(
          10,
          (i) => int.parse(
            linksfieldAid.substring(12 + i * 2, 14 + i * 2),
            radix: 16,
          ),
        ),
      );
      expect(tail, 'Linksfield');
    });

    test('the AID travels as an ASCII hex string on the wire', () {
      final body = linksfieldOpenChannelBody();
      // 08 02 | 12 <len> | 0A 20 | 32 ASCII chars | 10 00
      expect(body[0], 0x08);
      expect(body[1], 0x02, reason: 'openLogicalChannel');
      expect(body[3], 0x22,
          reason: 'openChannel = 0A 20 <32 chars> 10 00 = 36 bytes');
      final ascii = String.fromCharCodes(body.sublist(6, 38));
      expect(ascii, linksfieldAid);
      expect(body.sublist(38), [0x10, 0x00], reason: 'p2 = 0');
    });

    test('the full request bytes match what the plan claims', () {
      final case0 = knownPlaintextCases[0];
      final body = linksfieldOpenChannelBody();
      // Build 08 03 12 <len> <body>. `len` is the real body length (0x28), not
      // body+1: the field card's own output proved it, and the +1 assumption
      // made a valid capture look wrong.
      final wrapped = <int>[
        0x08, 0x03,
        0x12, body.length,
        ...body,
      ];
      final expected = case0.expectedRequestHex.toLowerCase();
      expect(wrapped.length * 2, expected.length,
          reason: 'declared length must match the real frame');
      expect(
        wrapped.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        expected,
        reason: 'the documented expected request must equal the built one',
      );
    });

    test('iccReset expected frame matches the vendor capture', () {
      expect(knownPlaintextCases[1].expectedRequestHex, '080312021a00');
    });
  });
}
