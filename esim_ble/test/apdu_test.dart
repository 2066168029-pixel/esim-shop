import 'dart:typed_data';

import 'package:esim_ble/src/asn1.dart';
import 'package:esim_ble/src/euicc_transport.dart';
import 'package:esim_ble/src/lpa.dart';
import 'package:esim_ble/src/sgp22.dart';
import 'package:flutter_test/flutter_test.dart';

/// Card stub at the transport boundary: records every APDU and replays
/// scripted payloads. Everything above it (LPA framing, 61XX handling, ASN.1
/// parsing) is the real code.
class FakeSession extends EuiccSession {
  FakeSession() : super(_RecordingTransport());

  /// Payload returned with SW=9000 when no builder is set.
  Uint8List response = Uint8List(0);

  /// Produces the next payload; lets a test script a sequence.
  Uint8List Function()? responseBuilder;

  int channel = 0;

  List<Uint8List> get sent => (transport as _RecordingTransport).sent;

  /// Sets the payload every subsequent transmit will answer with.
  void reply(Uint8List payload) {
    response = payload;
    (transport as _RecordingTransport).response = payload;
  }

  /// Scripts a sequence of payloads, one per transmit, for multi-step flows.
  void replySequence(List<Uint8List> payloads) {
    var i = 0;
    responseBuilder =
        () => payloads[(i++).clamp(0, payloads.length - 1)];
    (transport as _RecordingTransport).responseBuilder = responseBuilder;
  }
}

class _RecordingTransport implements EuiccTransport {
  final sent = <Uint8List>[];
  Uint8List response = Uint8List(0);
  Uint8List Function()? responseBuilder;

  @override
  String get kind => 'fake';

  @override
  String get description => 'fake card';

  @override
  bool get isOpen => true;

  @override
  Future<void> open() async {}

  @override
  Future<ApduResponse> transmit(Uint8List apdu) async {
    sent.add(Uint8List.fromList(apdu));
    final payload = responseBuilder?.call() ?? response;
    return ApduResponse(payload, 0x9000);
  }

  @override
  Future<int> openChannel(Uint8List aid) async => 0;

  /// Single-session fake: no second channel, like the Linksfield card.
  @override
  Future<int> addChannel(Uint8List aid) =>
      throw UnsupportedError('fake exposes one channel');

  @override
  Future<bool> closeChannelOnCard(int channel) async => true;

  @override
  Future<void> closeChannel(int channel) async {}

  @override
  Future<void> close() async {}
}

/// Test-side view of a raw APDU so assertions read by name.
extension ApduView on Uint8List {
  int get cla => this[0];
  int get instruction => this[1];
  int get p1 => this[2];
  int get p2 => this[3];
  int get p3 => this[4];

  String get dataHex => sublist(5)
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join();
}

void main() {
  group('ES10x APDU segmentation', () {
    test('a short request is one APDU with P1=0x91 and P2=0', () async {
      final fake = FakeSession();
      fake.reply(tlvChildren(0xBF2E, [tlv(0x80, [0x01, 0x02])]));

      await Lpa(fake).getEuiccChallenge();

      expect(fake.sent.length, 1);
      final a = fake.sent.single;
      expect(a.cla, 0x80);
      expect(a.instruction, 0xE2);
      expect(a.p1, 0x91); // single segment == final segment
      expect(a.p2, 0); // sequence number
      expect(a.p3, 3); // BF2E 00
    });

    test('a 300-byte request splits into 3 APDUs with incrementing P2',
        () async {
      final fake = FakeSession();
      fake.reply(tlvChildren(0xBF37, [tlv(0x80, [0x00])]));

      await Lpa(fake).loadBoundProfilePackage(Uint8List(300));

      expect(fake.sent.length, 3);
      expect(fake.sent[0].p1, 0x11, reason: 'not the last segment');
      expect(fake.sent[0].p2, 0);
      expect(fake.sent[0].p3, 120);

      expect(fake.sent[1].p1, 0x11);
      expect(fake.sent[1].p2, 1);
      expect(fake.sent[1].p3, 120);

      expect(fake.sent[2].p1, 0x91, reason: 'last segment');
      expect(fake.sent[2].p2, 2);
      expect(fake.sent[2].p3, 60);
    });

    test('exactly 120 bytes is a single final segment', () async {
      final fake = FakeSession();
      fake.reply(tlvChildren(0xBF37, [tlv(0x80, [0x00])]));

      await Lpa(fake).loadBoundProfilePackage(Uint8List(120));

      expect(fake.sent.length, 1);
      expect(fake.sent.single.p1, 0x91);
      expect(fake.sent.single.p3, 120);
    });

    test('241 bytes splits into 120 + 120 + 1', () async {
      final fake = FakeSession();
      fake.reply(tlvChildren(0xBF37, [tlv(0x80, [0x00])]));

      await Lpa(fake).loadBoundProfilePackage(Uint8List(241));

      expect(fake.sent.map((a) => a.p3).toList(), [120, 120, 1]);
      expect(fake.sent.last.p1, 0x91);
    });
  });

  group('Profile list parsing', () {
    test('parses a ProfileInfoListResult with one enabled profile', () async {
      // BF2D { A0 { 30 { 5A iccid, 4F aid, 90 nickname, 9F70 { 02 01 }, ... } } }
      final profile = tlvChildren(0x30, [
        tlv(0x5A, [0x98, 0x85, 0x21]),
        tlv(0x4F, [0xA0, 0x00]),
        tlv(0x90, 'MyTravel'.codeUnits),
        tlv(0x91, 'ACME'.codeUnits),
        tlv(0x92, 'ACME 5GB'.codeUnits),
        tlvChildren(0x9F70, [tlv(0x02, [0x01])]),
      ]);
      final fake = FakeSession();
      fake.reply(tlvChildren(0xBF2D, [tlvChildren(0xA0, [profile])]));

      final profiles = await Lpa(fake).listProfiles();

      expect(profiles.length, 1);
      expect(profiles.single.iccid, '988521');
      expect(profiles.single.nickname, 'MyTravel');
      expect(profiles.single.serviceProvider, 'ACME');
      expect(profiles.single.isEnabled, isTrue);
    });

    test('parses an empty list without throwing', () async {
      final fake = FakeSession();
      fake.reply(tlvChildren(0xBF2D, [tlv(0xA0, const [])]));
      expect(await Lpa(fake).listProfiles(), isEmpty);
    });
  });

  group('ES10c profile operations', () {
    test('enableProfile sends BF31 with a BCD-swapped ICCID', () async {
      final fake = FakeSession();
      fake.reply(tlv(0xBF31, const []));

      await Lpa(fake).enableProfile('89852122501035019387');

      final apdu = fake.sent.single;
      expect(apdu.instruction, 0xE2);
      expect(apdu.dataHex.startsWith('BF31'), isTrue);
      expect(apdu.dataHex.contains('5A'), isTrue);
      // ICCID 898521... -> nibble-swapped: 98 58 12 ...
      expect(apdu.dataHex.contains('9858'), isTrue);
    });

    test('deleteProfile uses BF33', () async {
      final fake = FakeSession();
      fake.reply(tlv(0xBF33, const []));

      await Lpa(fake).deleteProfile('89852122501035019387');

      expect(fake.sent.single.dataHex.startsWith('BF33'), isTrue);
    });
  });
}
