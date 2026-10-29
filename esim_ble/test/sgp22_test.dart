import 'dart:typed_data';

import 'package:esim_ble/src/euicc_transport.dart';
import 'package:esim_ble/src/sgp22.dart';
import 'package:flutter_test/flutter_test.dart';

/// A transport that records what the engine sent, so the ES10x framing and the
/// 61XX handling can be checked without a card.
class FakeTransport implements EuiccTransport {
  final List<Uint8List> sent = [];
  int openCalls = 0;
  int closeCalls = 0;
  int channel = 1;

  /// Answers for successive transmits, by INS.
  final Map<int, List<ApduResponse>> _script = {};

  @override
  String get kind => 'fake';

  @override
  String get description => 'fake card';

  @override
  bool get isOpen => openCalls > closeCalls;

  void script(int ins, List<ApduResponse> responses) {
    _script[ins] = [...responses];
  }

  @override
  Future<void> open() async {
    openCalls++;
  }

  @override
  Future<ApduResponse> transmit(Uint8List apdu) async {
    sent.add(Uint8List.fromList(apdu));
    final queue = _script[apdu[1]];
    if (queue == null || queue.isEmpty) return ApduResponse(Uint8List(0), 0x9000);
    return queue.removeAt(0);
  }

  @override
  Future<int> openChannel(Uint8List aid) async => channel;

  /// Set to a number to simulate a card with a second, notification-only
  /// session; stays null for single-session firmware.
  int? secondChannel;
  int addChannelCalls = 0;

  @override
  Future<int> addChannel(Uint8List aid) async {
    addChannelCalls++;
    final ch = secondChannel;
    if (ch == null) throw UnsupportedError('one session only');
    return ch;
  }

  /// Channels closed through the ISO MANAGE CHANNEL path.
  final closeOnCardCalls = <int>[];

  @override
  Future<bool> closeChannelOnCard(int channel) async {
    closeOnCardCalls.add(channel);
    return true;
  }

  @override
  Future<void> closeChannel(int channel) async {}

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

void main() {
  group('EuiccSession.open', () {
    test('preferBasicChannel selects ISD-R on channel 0 without opening one',
        () async {
      final t = FakeTransport()..secondChannel = 2;
      final s = EuiccSession(t)..preferBasicChannel = true;

      await s.open();

      expect(s.channel, 0);
      expect(s.isIsdrSelected, isTrue);
      expect(s.notificationChannel, isNull);
      expect(t.addChannelCalls, 0); // nothing left behind on the card
      expect(t.sent.single[0], 0x00); // SELECT with CLA channel 0
      expect(t.sent.single[1], 0xA4);
    });

    test('opens a channel and selects ISD-R on it', () async {
      final t = FakeTransport();
      final s = EuiccSession(t);

      await s.open();

      expect(t.openCalls, 1);
      expect(s.channel, 1);
      expect(s.isIsdrSelected, isTrue);

      final select = t.sent.single;
      expect(select[0], 0x01); // CLA with channel ORed in
      expect(select[1], 0xA4); // SELECT
      expect(select[2], 0x04);
      expect(select[3], 0x00);
      expect(select[4], 16); // ISD-R AID length
    });

    test('falls back to the basic channel when SELECT is rejected there', () async {
      final t = FakeTransport();
      t.channel = 0;
      final s = EuiccSession(t);

      await s.open();

      expect(s.channel, 0);
      expect(s.isIsdrSelected, isTrue);
      expect(t.sent.single[0], 0x00);
    });

    test('opens a notification channel when the card offers one', () async {
      final t = FakeTransport()..secondChannel = 2;
      final s = EuiccSession(t);

      await s.open();

      expect(s.notificationChannel, 2);
      expect(t.addChannelCalls, 1);
    });

    test('a single-session card leaves the notification channel unset', () async {
      final t = FakeTransport();
      final s = EuiccSession(t);

      await s.open();

      // Not an error: notification reads then share the ISD-R channel.
      expect(s.notificationChannel, isNull);
      expect(s.isIsdrSelected, isTrue);
      expect(t.addChannelCalls, 1);
    });

    test('ES10x on the notification channel uses that channel in CLA', () async {
      final t = FakeTransport()..secondChannel = 2;
      final s = EuiccSession(t);
      await s.open();

      t.script(0xE2, [ApduResponse(Uint8List.fromList([0xBF, 0x28, 0x00]), 0x9000)]);
      await s.es10xOnChannel(Uint8List.fromList([0xBF, 0x28, 0x00]), 2);

      final last = t.sent.last;
      expect(last[1], 0xE2);
      expect(last[0] & 0x0F, 2);

      // And the ISD-R channel is untouched.
      await s.es10x(Uint8List.fromList([0xBF, 0x2D, 0x00]));
      expect(t.sent.last[0] & 0x0F, 1);
    });
  });

  group('ES10x framing', () {
    test('one short command is a single APDU', () async {
      final t = FakeTransport();
      final s = EuiccSession(t)..channel = 1;
      t.script(0xE2, [ApduResponse(Uint8List.fromList([0xBF, 0x2D, 0x00]), 0x9000)]);

      final der = Uint8List.fromList([0xBF, 0x2D, 0x00]);
      final rsp = await s.es10x(der);

      expect(rsp, [0xBF, 0x2D, 0x00]);
      final apdu = t.sent.single;
      expect(apdu[0], 0x81); // CLA 0x80 | channel 1
      expect(apdu[1], 0xE2);
      expect(apdu[2], 0x91); // last segment
      expect(apdu[3], 0x00); // segment 0
      expect(apdu[4], 3);
      expect(apdu.sublist(5), der);
    });

    test('long commands are segmented with P1 0x11 / 0x91 and growing P2', () async {
      final t = FakeTransport();
      final s = EuiccSession(t)..channel = 0;
      t.script(0xE2, [
        ApduResponse(Uint8List(0), 0x9000),
        ApduResponse(Uint8List(0), 0x9000),
        ApduResponse(Uint8List(0), 0x9000),
      ]);

      await s.es10x(Uint8List(300)); // 120 + 120 + 60

      expect(t.sent.length, 3);
      expect(t.sent[0][2], 0x11);
      expect(t.sent[1][2], 0x11);
      expect(t.sent[2][2], 0x91);
      expect(t.sent.map((a) => a[3]), [0, 1, 2]);
      expect(t.sent.map((a) => a[4]), [120, 120, 60]);
    });

    test('61XX is drained with GET RESPONSE before continuing', () async {
      final t = FakeTransport();
      final s = EuiccSession(t)..channel = 1;
      t.script(0xE2, [
        ApduResponse(Uint8List.fromList([0x01]), 0x6110),
        ApduResponse(Uint8List.fromList([0x02, 0x90, 0x00]), 0x9000),
      ]);

      final der = Uint8List.fromList([0xBF, 0x2D, 0x00]);
      await s.es10x(der);

      expect(t.sent.length, 2);
      expect(t.sent[0][1], 0xE2);
      final get = t.sent[1];
      expect(get[1], 0xC0); // GET RESPONSE
      expect(get[0], 0x81); // same logical channel
      expect(get[3], 0x00); // P2
    });

    test('a rejected segment throws with the status word', () async {
      final t = FakeTransport();
      final s = EuiccSession(t)..channel = 1;
      t.script(0xE2, [ApduResponse(Uint8List(0), 0x6A82)]);

      expect(
        () => s.es10x(Uint8List.fromList([0xBF, 0x2D, 0x00])),
        throwsA(isA<EuiccError>().having((e) => e.sw, 'sw', 0x6A82)),
      );
    });

    test('6CXX re-issues the APDU with the suggested length', () async {
      final t = FakeTransport();
      final s = EuiccSession(t)..channel = 1;

      // First answer: wrong Le, card says "use 0x10".
      t.script(0xC0, [
        ApduResponse(Uint8List(0), 0x6C10),
        ApduResponse(Uint8List(0), 0x9000),
      ]);

      await s.transmit(Uint8List.fromList([0x81, 0xC0, 0x00, 0x00, 0x20]));

      expect(t.sent.length, 2);
      expect(t.sent[1][4], 0x10);
    });
  });
}
