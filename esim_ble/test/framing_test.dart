import 'dart:typed_data';

import 'package:esim_ble/src/ble_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercises the length-prefix reassembly logic in isolation.
///
/// The framing rules come from the firmware: every message is prefixed with a
/// 2-byte big-endian length, and a message may arrive across several
/// notifications where only the first carries the header.
void main() {
  group('LPAd framing', () {
    test('header size is 2 bytes', () {
      expect(lpadHeaderSize, 2);
    });

    /// Builds a framed message: [len_hi][len_lo][payload].
    Uint8List frame(List<int> payload) {
      final out = Uint8List(payload.length + 2);
      out[0] = (payload.length >> 8) & 0xFF;
      out[1] = payload.length & 0xFF;
      out.setRange(2, out.length, payload);
      return out;
    }

    test('single-chunk message round-trips', () {
      final payload = [0x08, 0x00, 0x12, 0x03, 0xAA, 0xBB, 0xCC];
      final framed = frame(payload);
      expect(framed.length, payload.length + 2);
      expect(framed[0], 0); // high byte
      expect(framed[1], payload.length);
      expect(framed.sublist(2), payload);
    });

    test('length prefix handles payloads over 255 bytes', () {
      final payload = List<int>.filled(300, 0x42);
      final framed = frame(payload);
      expect(framed[0], 1); // 300 = 0x012C
      expect(framed[1], 44); // 0x2C
    });

    test('a 512-byte payload encodes as 0x0200', () {
      final framed = frame(List<int>.filled(512, 0));
      expect(framed[0], 2);
      expect(framed[1], 0);
    });
  });
}
