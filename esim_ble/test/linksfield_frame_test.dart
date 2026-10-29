import 'dart:typed_data';

import 'package:esim_ble/src/linksfield_frame.dart' as lf;
import 'package:flutter_test/flutter_test.dart';

/// Offline vectors for the Linksfield frame format.
///
/// Everything here is pure byte manipulation: no BLE, no device, no APDU. The
/// expected values come from `docs/esim-ble-frame-protocol.md`, which was
/// produced by static analysis of the vendor APK.
void main() {
  group('protobuf envelope', () {
    test('getDeviceInfo serialises to 08 00 12 02 08 01', () {
      expect(lf.encodeGetDeviceInfo(),
          orderedEquals([0x08, 0x00, 0x12, 0x02, 0x08, 0x01]));
    });

    test('inner DeviceReq{cmd:1} is 08 01', () {
      expect(lf.encodeDeviceReq(1), orderedEquals([0x08, 0x01]));
    });

    test('DeviceRsp parses cmd/result/info', () {
      // DeviceRsp{cmd:1, result:1, info:{vendor:"ACME"}}
      final info = (Uint8List.fromList([0x0A, 0x04, 0x41, 0x43, 0x4D, 0x45]));
      final rsp = <int>[0x08, 0x01, 0x10, 0x01, 0x1A, info.length, ...info];
      final parsed = lf.DeviceRsp.parse(Uint8List.fromList(rsp));
      expect(parsed.cmd, 1);
      expect(parsed.result, 1);
      expect(parsed.info?.vendor, 'ACME');
    });

    test('DeviceRsp carries the -256 secure-channel sentinel', () {
      // -256 as protobuf int32 = 10-byte varint
      final rsp = <int>[
        0x08, 0x00, // cmd
        0x10, // field 2
        0x80, 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01,
      ];
      final parsed = lf.DeviceRsp.parse(Uint8List.fromList(rsp));
      expect(parsed.result, -256);
      expect(parsed.needsSecureChannel, isTrue);
    });

    test('TransmitApdu carries data as a hex string', () {
      final bytes = lf.encodeTransmitApdu(
        channel: 1,
        cla: 0x81,
        instruction: 0xA4,
        p1: 0x04,
        p2: 0x00,
        p3: 0x02,
        dataHex: 'AABB',
      );
      // Find the ASCII "AABB" inside the message.
      expect(String.fromCharCodes(bytes).contains('AABB'), isTrue);
    });
  });

  group('length header', () {
    test('2-byte big-endian, payload length only', () {
      final frame = lf.framePayload(
        Uint8List.fromList(lf.encodeGetDeviceInfo()),
        mtu: 517,
      );
      expect(frame.length, 1);
      // header 00 06 (six payload bytes), then 08 00 12 02 08 01
      expect(frame.first.sublist(0, 2), orderedEquals([0x00, 0x06]));
      expect(frame.first.sublist(2),
          orderedEquals([0x08, 0x00, 0x12, 0x02, 0x08, 0x01]));
      expect(frame.first.length, 8);
    });

    test('4-byte header is big-endian too', () {
      final frame = lf.framePayload(
        Uint8List(300),
        mtu: 517,
        lengthHeaderSize: 4,
      );
      expect(frame.first.sublist(0, 4),
          orderedEquals([0x00, 0x00, 0x01, 0x2C])); // 300
    });

    test('only the first chunk carries the header', () {
      final frames = lf.framePayload(Uint8List(40), mtu: 23);
      expect(frames.length, greaterThan(1));
      expect(frames[0].length, 18); // mtu-5 = 18, header 2 + 16 payload
      expect(frames[1].length, 20); // mtu-3
      expect(frames[1].sublist(0, 2), isNot(orderedEquals([0x00, 0x28])));
    });

    test('rejects a payload too large for a 2-byte header', () {
      expect(
        () => lf.framePayload(Uint8List(0x10000), mtu: 517),
        throwsArgumentError,
      );
    });
  });

  group('fragmentation boundaries', () {
    test('exactly fills one chunk at mtu=512', () {
      final frames = lf.framePayload(Uint8List(505), mtu: 512);
      expect(frames.length, 1);
      expect(frames.first.length, 507); // 2 + 505
    });

    test('one byte over the first chunk spills exactly one byte', () {
      final frames = lf.framePayload(Uint8List(506), mtu: 512);
      expect(frames.length, 2);
      expect(frames[0].length, 507);
      expect(frames[1].length, 1);
    });

    test('continuation chunks respect the ATT limit', () {
      final frames = lf.framePayload(Uint8List(2000), mtu: 23);
      for (final f in frames.skip(1)) {
        expect(f.length, lessThanOrEqualTo(20)); // mtu-3
      }
    });

    test('mtu too small is rejected rather than emitting a bad frame', () {
      expect(
        () => lf.framePayload(Uint8List(10), mtu: 6),
        throwsArgumentError,
      );
    });
  });

  group('reassembly', () {
    lf.FrameAssembler newAssembler({int header = 2}) =>
        lf.FrameAssembler(lengthHeaderSize: header);

    test('single complete message', () {
      final a = newAssembler();
      final out = a.push([0x00, 0x02, 0xAA, 0xBB]);
      expect(out.length, 1);
      expect(out.first, orderedEquals([0xAA, 0xBB]));
    });

    test('message split across notifications', () {
      final a = newAssembler();
      expect(a.push([0x00, 0x04, 0x01, 0x02]), isEmpty);
      final out = a.push([0x03, 0x04]);
      expect(out.single, orderedEquals([0x01, 0x02, 0x03, 0x04]));
    });

    test('header split across notifications', () {
      final a = newAssembler();
      expect(a.push([0x00]), isEmpty);
      final out = a.push([0x02, 0xEE, 0xFF]);
      expect(out.single, orderedEquals([0xEE, 0xFF]));
    });

    test('two messages in one notification', () {
      final a = newAssembler();
      final out = a.push([0x00, 0x01, 0xAA, 0x00, 0x01, 0xBB]);
      expect(out.length, 2);
      expect(out[0], orderedEquals([0xAA]));
      expect(out[1], orderedEquals([0xBB]));
    });

    test('tail of one message plus head of the next', () {
      final a = newAssembler();
      expect(a.push([0x00, 0x03, 0x01]), isEmpty);
      final out = a.push([0x02, 0x03, 0x00, 0x01, 0x99]);
      // The second message's header (00 01) is complete too, so it is emitted
      // with its body: two messages in, two messages out.
      expect(out.length, 2);
      expect(out[0], orderedEquals([0x01, 0x02, 0x03]));
      expect(out[1], orderedEquals([0x99]));
      expect(a.buffered, 0);
    });

    test('4-byte header reassembly', () {
      final a = newAssembler(header: 4);
      final out = a.push([0x00, 0x00, 0x00, 0x02, 0x11, 0x22]);
      expect(out.single, orderedEquals([0x11, 0x22]));
    });

    test('garbage header is rejected, not buffered forever', () {
      final a = newAssembler();
      final out = a.push([0x00, 0x00, 0x33]);
      expect(out, isEmpty);
      expect(a.rejectedHeaders, 1);
    });

    test('reset clears partial state between requests', () {
      final a = newAssembler();
      a.push([0x00, 0x04, 0x01]);
      a.reset();
      final out = a.push([0x00, 0x01, 0x77]);
      expect(out.single, orderedEquals([0x77]));
      expect(a.buffered, 0);
    });

    test('empty chunk is a no-op', () {
      final a = newAssembler();
      expect(a.push(const []), isEmpty);
      expect(a.buffered, 0);
    });
  });

  group('round trip', () {
    test('frame then reassemble returns the original payload', () {
      final payload = Uint8List.fromList(lf.encodeGetDeviceInfo());
      for (final mtu in [23, 100, 185, 517]) {
        final frames = lf.framePayload(payload, mtu: mtu);
        final a = lf.FrameAssembler();
        final got = <Uint8List>[];
        for (final f in frames) {
          got.addAll(a.push(f));
        }
        expect(got.length, 1, reason: 'mtu=$mtu');
        expect(got.single, orderedEquals(payload), reason: 'mtu=$mtu');
      }
    });

    test('4-byte header round trip', () {
      final payload = Uint8List(700);
      final frames = lf.framePayload(payload, mtu: 100, lengthHeaderSize: 4);
      final a = lf.FrameAssembler(lengthHeaderSize: 4);
      final got = <Uint8List>[];
      for (final f in frames) {
        got.addAll(a.push(f));
      }
      expect(got.single.length, 700);
    });
  });
}
