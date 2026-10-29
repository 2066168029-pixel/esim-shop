import 'dart:convert';
import 'dart:typed_data';

import 'package:esim_ble/src/asn1.dart';
import 'package:esim_ble/src/notifications.dart';
import 'package:esim_ble/src/lpa.dart';
import 'package:esim_ble/src/smdp_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apdu_test.dart' show FakeSession, ApduView;

void main() {
  group('ES10b notifications', () {
    test('listNotifications parses seq numbers', () async {
      // BF28 { A0 { 02 01 01, 02 01 05 } }
      final fake = FakeSession()
        ..reply(tlvChildren(0xBF28, [
          tlvChildren(0xA0, [
            tlv(0x02, [0x01]),
            tlv(0x02, [0x05]),
          ]),
        ]));

      expect(await Lpa(fake).listNotifications(), [1, 5]);
    });

    test('listNotifications returns empty when nothing is queued', () async {
      final fake = FakeSession()..reply(tlvChildren(0xBF28, [tlv(0xA0, const [])]));
      expect(await Lpa(fake).listNotifications(), isEmpty);
    });

    test('retrieveNotification extracts address and payload', () async {
      // BF2B { A0 { BF37 { BF27 { BF2F { 0C "smdp.test" } } } } }
      final metadata = tlvChildren(0xBF2F, [
        tlv(0x0C, 'smdp.test'.codeUnits),
        tlv(0x02, [0x01]),
      ]);
      final installResult = tlvChildren(0xBF37, [
        tlvChildren(0xBF27, [metadata]),
      ]);
      final fake = FakeSession()
        ..reply(tlvChildren(0xBF2B, [
          tlvChildren(0xA0, [installResult]),
        ]));

      final pending = await Lpa(fake).retrieveNotification(1);

      expect(pending, isNotNull);
      expect(pending!.notificationAddress, 'smdp.test');
      expect(pending.isInstallationResult, isTrue);
      expect(pending.seqNumber, 1);
      // The base64 payload must decode back to the ProfileInstallationResult.
      final decoded = base64Decode(pending.pendingNotificationB64);
      expect(decoded[0], 0xBF);
      expect(decoded[1], 0x37);
    });

    test('retrieveNotification handles otherSignedNotification (0x30)',
        () async {
      final metadata = tlvChildren(0xBF2F, [tlv(0x0C, 'ds.test'.codeUnits)]);
      final other = tlvChildren(0x30, [metadata]);
      final fake = FakeSession()
        ..reply(tlvChildren(0xBF2B, [
          tlvChildren(0xA0, [other]),
        ]));

      final pending = await Lpa(fake).retrieveNotification(2);
      expect(pending?.notificationAddress, 'ds.test');
      expect(pending?.isInstallationResult, isFalse);
    });

    test('retrieveNotification returns null for an empty list', () async {
      final fake = FakeSession()..reply(tlvChildren(0xBF2B, [tlv(0xA0, const [])]));
      expect(await Lpa(fake).retrieveNotification(3), isNull);
    });

    test('notificationSent acknowledges with BF30', () async {
      final fake = FakeSession()..reply(tlv(0xBF30, const []));
      await Lpa(fake).notificationSent(4);

      final apdu = fake.sent.single;
      expect(apdu.instruction, 0xE2);
      expect(apdu.dataHex.startsWith('BF30'), isTrue);
    });

    test('flushNotifications posts then acknowledges each entry', () async {
      final meta1 = tlvChildren(0xBF2F, [tlv(0x0C, 'smdp.test'.codeUnits)]);
      final n1 = tlvChildren(0xBF37, [tlvChildren(0xBF27, [meta1])]);
      final meta2 = tlvChildren(0xBF2F, [tlv(0x0C, 'ds.test'.codeUnits)]);
      final n2 = tlvChildren(0x30, [meta2]);

      final fake = FakeSession();
      final scripted = <Uint8List>[
        // listNotifications
        tlvChildren(0xBF28, [tlvChildren(0xA0, [tlv(0x02, [0x01]), tlv(0x02, [0x02])])]),
        // retrieve 1
        tlvChildren(0xBF2B, [tlvChildren(0xA0, [n1])]),
        // ack 1
        tlv(0xBF30, const []),
        // retrieve 2
        tlvChildren(0xBF2B, [tlvChildren(0xA0, [n2])]),
        // ack 2
        tlv(0xBF30, const []),
      ];
      fake.replySequence(scripted);

      final client = FakeSmdpClient('smdp.test');
      final drain = await Lpa(fake).flushNotifications(
        clientFactory: (_) => client,
      );

      expect(drain.delivered, 2);
      expect(drain.isClean, isTrue);
      expect(client.posted.length, 2);
      expect(fake.sent.where((a) => a.dataHex.startsWith('BF30')).length, 2);
    });

    test('a failing SM-DP+ leaves the notification unacknowledged', () async {
      final meta = tlvChildren(0xBF2F, [tlv(0x0C, 'dead.test'.codeUnits)]);
      final n1 = tlvChildren(0xBF37, [tlvChildren(0xBF27, [meta])]);

      final fake = FakeSession();
      final scripted = <Uint8List>[
        tlvChildren(0xBF28, [tlvChildren(0xA0, [tlv(0x02, [0x01])])]),
        tlvChildren(0xBF2B, [tlvChildren(0xA0, [n1])]),
      ];
      fake.replySequence(scripted);

      final drain = await Lpa(fake).flushNotifications(
        clientFactory: (addr) => FakeSmdpClient(addr, fail: true),
      );

      expect(drain.delivered, 0);
      expect(drain.isClean, isFalse);
      expect(drain.errors.single, contains('dead.test'));
      // No ack should be sent when delivery failed.
      expect(fake.sent.any((a) => a.dataHex.startsWith('BF30')), isFalse);
    });
  });
}

/// Stand-in for SmdpClient that records handleNotification calls.
class FakeSmdpClient extends SmdpClient {
  final bool fail;
  final posted = <String>[];

  FakeSmdpClient(String address, {this.fail = false}) : super(address);

  @override
  Future<void> handleNotification(String pendingNotificationB64) async {
    if (fail) throw SmdpError('unreachable');
    posted.add(pendingNotificationB64);
  }

  @override
  void close() {}
}
