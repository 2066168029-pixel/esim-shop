import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Reassembles length-prefixed messages, mirroring CardConnection._onChunk.
///
/// Duplicated here (rather than exported) because the real implementation is
/// private and coupled to a live GATT connection; the algorithm is what needs
/// testing.
class Reassembler {
  final _incoming = <int>[];
  int? _expected;
  final messages = <Uint8List>[];

  static const int headerSize = 2;

  void add(List<int> chunk) {
    if (chunk.isNotEmpty) _incoming.addAll(chunk);

    while (true) {
      if (_expected == null) {
        if (_incoming.length < headerSize) return;
        final len = (_incoming[0] << 8) | _incoming[1];
        _expected = headerSize + len;
      }
      final expected = _expected!;
      if (_incoming.length < expected) return;

      messages.add(Uint8List.fromList(_incoming.sublist(headerSize, expected)));
      _incoming.removeRange(0, expected);
      _expected = null;
    }
  }
}

Uint8List frame(List<int> payload) {
  final out = Uint8List(payload.length + 2);
  out[0] = (payload.length >> 8) & 0xFF;
  out[1] = payload.length & 0xFF;
  out.setRange(2, out.length, payload);
  return out;
}

void main() {
  group('message reassembly', () {
    test('one notification carrying a whole message', () {
      final r = Reassembler()..add(frame([1, 2, 3]));
      expect(r.messages.length, 1);
      expect(r.messages.single, [1, 2, 3]);
    });

    test('a message split across notifications', () {
      final framed = frame(List.generate(300, (i) => i % 256));
      final r = Reassembler();
      // First chunk: header + 100 bytes
      r.add(framed.sublist(0, 102));
      expect(r.messages, isEmpty);
      // Second chunk: continuation
      r.add(framed.sublist(102, 200));
      expect(r.messages, isEmpty);
      // Final chunk completes it
      r.add(framed.sublist(200));
      expect(r.messages.length, 1);
      expect(r.messages.single.length, 300);
      expect(r.messages.single[0], 0);
      expect(r.messages.single[299], 299 % 256);
    });

    test('the length header itself split across two notifications', () {
      final framed = frame([9, 8, 7]);
      final r = Reassembler();
      r.add([framed[0]]); // only the high byte
      expect(r.messages, isEmpty);
      r.add(framed.sublist(1));
      expect(r.messages.single, [9, 8, 7]);
    });

    test('two complete messages in one notification', () {
      final a = frame([1, 1]);
      final b = frame([2, 2, 2]);
      final r = Reassembler()..add([...a, ...b]);
      expect(r.messages.length, 2);
      expect(r.messages[0], [1, 1]);
      expect(r.messages[1], [2, 2, 2]);
    });

    test('tail of one message plus head of the next in one notification', () {
      final a = frame([5, 5]);
      final b = frame([6, 6, 6, 6]);
      final r = Reassembler();
      // Deliver all of A plus the first 3 bytes of B together.
      r.add([...a, ...b.sublist(0, 3)]);
      expect(r.messages.length, 1);
      expect(r.messages.single, [5, 5]);
      // Then the rest of B.
      r.add(b.sublist(3));
      expect(r.messages.length, 2);
      expect(r.messages[1], [6, 6, 6, 6]);
    });

    test('an empty payload is a valid message', () {
      final r = Reassembler()..add(frame([]));
      expect(r.messages.length, 1);
      expect(r.messages.single, isEmpty);
    });

    test('a 511-byte payload is not confused with a truncated frame', () {
      // 511 = 0x01FF, the value that showed up as a bogus field length when
      // the header position was wrong.
      final payload = List.generate(511, (i) => i % 256);
      final r = Reassembler()..add(frame(payload));
      expect(r.messages.length, 1);
      expect(r.messages.single.length, 511);
    });
  });
}
