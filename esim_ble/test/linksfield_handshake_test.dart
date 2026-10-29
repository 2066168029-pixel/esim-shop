import 'dart:typed_data';

import 'package:esim_ble/src/linksfield_frame.dart' as lf;
import 'package:esim_ble/src/linksfield_secure.dart' as sec;
import 'package:flutter_test/flutter_test.dart';

/// Offline simulation of the whole secure-channel exchange.
///
/// There is no BLE here: a fake device answers the three messages the way the
/// firmware should. This is the regression net for the handshake — if a change
/// breaks the derivation or the framing, it fails here instead of on a phone.
///
/// It also documents the exact byte contract between client and card, which is
/// what the real-device failures keep boiling down to.

/// The card's side of the handshake.
class FakeCard {
  final String psk;
  FakeCard(this.psk);

  /// Challenge handed to the client in the first AUTH reply.
  final Uint8List challenge =
      Uint8List.fromList(List<int>.generate(32, (i) => (i * 3 + 7) & 0xFF));

  bool challengeSent = false;
  bool authVerified = false;
  sec.LpadSecureSession? session;

  /// Handles one `EuiccDeviceReq{cmd: SECURITY}` payload; returns the reply
  /// payload (the bytes the device would put inside DeviceRsp.security).
  Uint8List? handleSecurity(Uint8List reqBytes) {
    // Envelope on the wire: `EuiccDeviceReq{cmd: SECURITY,
    // request: SecurityData{id, sec}}`. The `SecurityProtocol` body is at
    // SecurityData field 3, not at field 2 of the request directly -- reading it
    // one level too shallow is what produced `{field5: 5}` from the real card.
    final fields = lf.parseAllFields(reqBytes);
    final request = fields[2];
    if (request == null) return null;

    final dataFields = lf.parseAllFields(request);
    final secBytes = dataFields[3];
    if (secBytes == null) {
      return null;
    }

    final msg = sec.SecurityProtocolMsg.parse(secBytes);

    // Step 1: "start" -> answer with a challenge.
    if (msg.type == sec.SecurityType.auth &&
        msg.authRandom.isEmpty &&
        !challengeSent) {
      challengeSent = true;
      final auth = (lf.PbWriter()..bytes(1, challenge)).toBytes();
      return (lf.PbWriter()
            ..uint(1, sec.SecurityType.auth)
            ..bytes(2, auth))
          .toBytes();
    }

    // Step 2: the client proves the PSK.
    //
    // The reply is a **bare** `SecurityAuth{random, auth}` -- no `type` field.
    // `msg.type` therefore decodes as something else entirely, so the test card
    // must key off the presence of the two field-2 blobs rather than the enum.
    // (This is exactly the shape the vendor sends; see `k3.a` in the APK, and
    // the old test here agreed with our wrong encoder instead of the card.)
    if (challengeSent &&
        msg.authRandom.isNotEmpty &&
        msg.authValue.isNotEmpty) {
      final pcNonce = Uint8List.fromList(msg.authRandom);
      final proof = sec.buildProof(
        sec.derivePskKey(psk),
        challenge,
        pcNonce,
      );
      if (!_eq(proof, Uint8List.fromList(msg.authValue))) {
        return null; // wrong PSK: device stays silent
      }
      authVerified = true;

      // Step 3: device hands out the session config, MAC'd with the key.
      final sessionKey = Uint8List.sublistView(proof, 16, 32);
      final nonce = Uint8List.fromList(List<int>.generate(12, (i) => 0x30 + i));
      final aad = Uint8List.fromList(List<int>.generate(16, (i) => 0x50 + i));
      final mac = sec.hmacForTest(sessionKey, [nonce, aad]);
      session = sec.LpadSecureSession(
        sessionKey: Uint8List.fromList(sessionKey),
        initNonce: nonce,
        aad: aad,
      );

      final config = (lf.PbWriter()
            ..bytes(1, nonce)
            ..bytes(2, aad)
            ..bytes(3, mac))
          .toBytes();
      return (lf.PbWriter()
            ..uint(1, sec.SecurityType.update)
            ..bytes(3, config))
          .toBytes();
    }

    return null;
  }

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The client's side, mirroring LinksfieldTransport.startSecureChannel.
class FakeClient {
  final String psk;
  FakeClient(this.psk);

  sec.LpadSecureSession? session;
  String log = '';

  Uint8List step1() {
    // Same envelope the transport now sends: EuiccDeviceReq{cmd:3,
    // request: SecurityData{id, sec}}. The card reads `sec` at field 3, so a
    // bare protocol here would reproduce the old failure in the test too.
    _id += 1;
    final frame =
        lf.wrapSecurity(sec.encodeSecurityDataSec(_id, sec.encodeAuthStart()));
    log += 'send AUTH start\n';
    return frame;
  }

  int _id = 0;

  Uint8List? step2(Uint8List deviceSecurity) {
    final msg = sec.SecurityProtocolMsg.parse(deviceSecurity);
    if (msg.type != sec.SecurityType.auth || msg.authRandom.isEmpty) {
      log += 'step1 bad: type=${msg.type} random=${msg.authRandom.length}\n';
      return null;
    }
    final pcNonce =
        Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + 3) & 0xFF));
    final proof = sec.buildProof(
      sec.derivePskKey(psk),
      Uint8List.fromList(msg.authRandom),
      pcNonce,
    );
    log += 'got challenge (${msg.authRandom.length}B), sending proof\n';
    _id += 1;
    return lf.wrapSecurity(
      sec.encodeSecurityDataSec(_id, sec.encodeAuthReply(pcNonce, proof)),
    );
  }

  bool step3(Uint8List deviceSecurity, Uint8List proof) {
    final msg = sec.SecurityProtocolMsg.parse(deviceSecurity);
    if (msg.type != sec.SecurityType.update || msg.configNonce.isEmpty) {
      log += 'step2 bad: type=${msg.type}\n';
      return false;
    }
    try {
      session = sec.deriveLpadSession(
        proof: proof,
        updateNonce: Uint8List.fromList(msg.configNonce),
        updateAad: Uint8List.fromList(msg.configAad),
        updateAuth: Uint8List.fromList(msg.configAuth),
      );
      log += 'session established\n';
      return true;
    } on FormatException catch (e) {
      log += 'derive failed: ${e.message}\n';
      return false;
    }
  }
}

void main() {
  group('secure channel, end to end (offline)', () {
    test('a card with the default PSK completes the handshake', () {
      final card = FakeCard(sec.testFirmwarePsk);
      final client = FakeClient(sec.testFirmwarePsk);

      // Step 1
      final start = client.step1();
      final sec1 = card.handleSecurity(start);
      expect(sec1, isNotNull, reason: 'card must answer with a challenge');

      // Step 2
      final step2 = client.step2(sec1!);
      expect(step2, isNotNull);
      final sec2 = card.handleSecurity(step2!);
      expect(sec2, isNotNull, reason: 'card must answer with UPDATE');
      expect(card.authVerified, isTrue);

      // Step 3
      final msg = sec.SecurityProtocolMsg.parse(sec2!);
      final proof = sec.buildProof(
        sec.derivePskKey(sec.testFirmwarePsk),
        card.challenge,
        Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + 3) & 0xFF)),
      );
      expect(client.step3(sec2, proof), isTrue);
      expect(client.session, isNotNull);
      expect(client.session!.sessionKey.length, 16);
    });

    test('a wrong PSK leaves the card silent', () {
      final card = FakeCard(sec.testFirmwarePsk);
      final client = FakeClient('180651'); // wrong password

      final sec1 = card.handleSecurity(client.step1())!;
      final step2 = client.step2(sec1)!;
      final sec2 = card.handleSecurity(step2);
      expect(sec2, isNull, reason: 'card must not answer a bad proof');
      expect(card.authVerified, isFalse);
    });

    test('once the session exists both sides talk encrypted', () {
      final card = FakeCard(sec.testFirmwarePsk);
      final client = FakeClient(sec.testFirmwarePsk);

      final sec1 = card.handleSecurity(client.step1())!;
      final step2 = client.step2(sec1)!;
      final sec2 = card.handleSecurity(step2)!;

      final proof = sec.buildProof(
        sec.derivePskKey(sec.testFirmwarePsk),
        card.challenge,
        Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + 3) & 0xFF)),
      );
      expect(client.step3(sec2, proof), isTrue);

      // A normal request after the handshake.
      final request = lf.encodeGetDeviceInfo();
      final wrapped = client.session!.wrap(request);
      final parsed = sec.parseSecurityData(wrapped)!;
      expect(parsed.id, 1);

      // The card decrypts with the same counter.
      final back = card.session!.unwrap(wrapped);
      expect(back, orderedEquals(request));
    });

    test('tampering with a handshake message is rejected', () {
      final card = FakeCard(sec.testFirmwarePsk);
      final client = FakeClient(sec.testFirmwarePsk);

      final sec1 = card.handleSecurity(client.step1())!;
      final step2 = client.step2(sec1)!;

      // Flip a byte in the proof before the card sees it.
      final bad = Uint8List.fromList(step2);
      bad[bad.length - 1] ^= 0xFF;
      expect(card.handleSecurity(bad), isNull);
    });
  });
}
