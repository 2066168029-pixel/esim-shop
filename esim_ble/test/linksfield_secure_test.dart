import 'dart:typed_data';

import 'package:esim_ble/src/linksfield_frame.dart' as lf;
import 'package:esim_ble/src/linksfield_secure.dart' as sec;
import 'package:flutter_test/flutter_test.dart';

/// Offline vectors for the Linksfield secure channel.
///
/// No device, no BLE: these only exercise key derivation, the message shapes and
/// the AES-CCM envelope, so a regression shows up here rather than on hardware.
void main() {
  group('PSK derivation', () {
    test('is deterministic and 32 bytes', () {
      final a = sec.derivePskKey(sec.testFirmwarePsk);
      final b = sec.derivePskKey(sec.testFirmwarePsk);
      expect(a.length, 32);
      expect(a, orderedEquals(b));
    });

    test('different passwords give different keys', () {
      expect(
        sec.derivePskKey(sec.testFirmwarePsk),
        isNot(orderedEquals(sec.derivePskKey('180651'))),
      );
    });
  });

  group('SecurityProtocol encoding', () {
    test('AUTH start is type 0 only', () {
      // SecurityProtocol{type:0} -> field 1 varint 0 -> 08 00
      expect(sec.encodeAuthStart(), orderedEquals([0x08, 0x00]));
    });

    test('AUTH reply is SecurityProtocol{type: AUTH, auth{random, auth}}', () {
      // Both extremes were tried against the real card and both got
      // `{field5: 5}`:
      //   * bare `SecurityAuth` (no type)          -> invalid enum at field 1
      //   * no `SecurityData` envelope             -> sec not found at field 3
      // The vendor nests auth inside a SecurityProtocol that still carries
      // `type`, and puts that whole thing in SecurityData.sec.
      final msg = sec.encodeAuthReply(
        Uint8List.fromList([0x01, 0x02]),
        Uint8List.fromList([0xAA, 0xBB]),
      );
      expect(
        msg,
        orderedEquals([
          0x08, 0x00, // type = AUTH
          0x12, 0x08, // auth {
          0x0A, 0x02, 0x01, 0x02, //   random
          0x12, 0x02, 0xAA, 0xBB, //   auth
        ]),
      );

      final parsed = sec.SecurityProtocolMsg.parse(msg);
      expect(parsed.authRandom, orderedEquals([0x01, 0x02]));
      expect(parsed.authValue, orderedEquals([0xAA, 0xBB]));
    });

    test('SecurityData puts sec at field 3, not field 2', () {
      // setId=1, setEnc=2, setSec=3, setEncsec=4 -- straight from the APK's
      // SecurityData setters. Field 2 is the encrypted payload, so a handshake
      // message written there is invisible to the card.
      final data = sec.encodeSecurityDataSec(7, Uint8List.fromList([0x08, 0x00]));
      expect(
        data,
        orderedEquals([
          0x08, 0x07, // id = 7
          0x1A, 0x02, 0x08, 0x00, // sec = {type: AUTH}  -> field 3 = 0x1A
        ]),
      );
    });

    test('parses the UPDATE reply shape', () {
      // SecurityProtocol{type:1, config{nonce:12B, aad:16B, auth:32B}}
      final nonce = Uint8List.fromList(List.filled(12, 0x11));
      final aad = Uint8List.fromList(List.filled(16, 0x22));
      final mac = Uint8List.fromList(List.filled(32, 0x33));
      final config = (lf.PbWriter()
            ..bytes(1, nonce)
            ..bytes(2, aad)
            ..bytes(3, mac))
          .toBytes();
      final msg = (lf.PbWriter()
            ..uint(1, sec.SecurityType.update)
            ..bytes(3, config))
          .toBytes();

      final p = sec.SecurityProtocolMsg.parse(msg);
      expect(p.type, sec.SecurityType.update);
      expect(p.configNonce.length, 12);
      expect(p.configAad.length, 16);
      expect(p.configAuth.length, 32);
    });

    test('the captured 20-byte security blob is a nested 16-byte challenge', () {
      // Verbatim from the card:
      //   DeviceRsp.security = 12 12 0A 10 CB FE 1D F9 62 8E DB 08
      //                        9D FB 8B E2 EC 5F 2F 7A
      // Read as protobuf: field 2 announces 18 bytes, and those 18 are
      // `0A 10 <16 bytes>` -- a nested field carrying the challenge. An earlier
      // version of this test assumed the 18 was an overrun; the device proves
      // otherwise, and the bytes are what the handshake needs.
      final security = Uint8List.fromList([
        0x12, 0x12, 0x0A, 0x10,
        0xCB, 0xFE, 0x1D, 0xF9, 0x62, 0x8E, 0xDB, 0x08,
        0x9D, 0xFB, 0x8B, 0xE2, 0xEC, 0x5F, 0x2F, 0x7A,
      ]);

      final parsed = sec.SecurityProtocolMsg.parse(security);
      expect(parsed.authRandom.length, 16);
      expect(
        parsed.authRandom
            .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
            .join(),
        'CBFE1DF9628EDB089DFB8BE2EC5F2F7A',
      );
    });

    test('a well-formed AUTH challenge has a 32-byte random and a proof', () {
      // What the handshake expects to see once the device answers properly.
      final challenge = Uint8List.fromList(List.filled(32, 0xA1));
      final proof = Uint8List.fromList(List.filled(32, 0xB2));
      final auth = (lf.PbWriter()
            ..bytes(1, challenge)
            ..bytes(2, proof))
          .toBytes();
      final raw = (lf.PbWriter()
            ..uint(1, sec.SecurityType.auth)
            ..bytes(2, auth))
          .toBytes();

      final p = sec.SecurityProtocolMsg.parse(raw);
      expect(p.type, sec.SecurityType.auth);
      expect(p.authRandom.length, 32);
      expect(p.authValue.length, 32);
    });
  });

  group('SecurityData envelope', () {
    test('wraps id + enc and parses back', () {
      final wrapped = sec.encodeSecurityData(3, Uint8List.fromList([0xDE, 0xAD]));
      final parsed = sec.parseSecurityData(wrapped);
      expect(parsed, isNotNull);
      expect(parsed!.id, 3);
      expect(parsed.ciphertext, orderedEquals([0xDE, 0xAD]));
    });

    test('non SecurityData bytes are rejected', () {
      expect(sec.parseSecurityData(Uint8List.fromList([0x08, 0x01])), isNull);
      expect(sec.parseSecurityData(Uint8List(0)), isNull);
    });
  });

  group('session', () {
    sec.LpadSecureSession newSession() => sec.LpadSecureSession(
          sessionKey: Uint8List.fromList(List.generate(16, (i) => i)),
          initNonce: Uint8List.fromList(List.generate(12, (i) => 0x10 + i)),
          aad: Uint8List.fromList(List.generate(16, (i) => 0x40 + i)),
        );

    test('wrap increments the counter and round-trips', () {
      final s = newSession();
      final plain = Uint8List.fromList([0x08, 0x01, 0x12, 0x02]);

      final wire = s.wrap(plain);
      expect(s.counter, 1);

      final parsed = sec.parseSecurityData(wire)!;
      expect(parsed.id, 1);

      // The peer uses the same counter value to decrypt.
      final back = s.unwrap(wire);
      expect(back, orderedEquals(plain));
    });

    test('nonce advances with the counter', () {
      final s = newSession();
      final n1 = s.nonceFor(1);
      final n2 = s.nonceFor(2);
      expect(n1, isNot(orderedEquals(n2)));
      expect(n1.length, 12);
    });

    test('tampered ciphertext fails to unwrap', () {
      final s = newSession();
      final wire = s.wrap(Uint8List.fromList([1, 2, 3, 4]));
      wire[wire.length - 1] ^= 0xFF;
      expect(s.unwrap(wire), isNull);
    });
  });

  group('session derivation', () {
    test('derives a session when the MAC matches', () {
      final psk = sec.derivePskKey(sec.testFirmwarePsk);
      final challenge = Uint8List.fromList(List.filled(32, 0x0A));
      final pcNonce = Uint8List.fromList(List.filled(32, 0x0B));
      final proof = sec.buildProof(psk, challenge, pcNonce);

      final nonce = Uint8List.fromList(List.filled(12, 0x01));
      final aad = Uint8List.fromList(List.filled(16, 0x02));
      // Device side of the derivation: HMAC(sessionKey, nonce ++ aad).
      final key = Uint8List.sublistView(proof, 16, 32);
      final expected = sec.hmacForTest(key, [nonce, aad]);

      final session = sec.deriveLpadSession(
        proof: proof,
        updateNonce: nonce,
        updateAad: aad,
        updateAuth: expected,
      );
      expect(session.sessionKey.length, 16);
      expect(session.initNonce.length, 12);
    });

    test('rejects a MAC that does not match', () {
      final psk = sec.derivePskKey(sec.testFirmwarePsk);
      final proof = sec.buildProof(
        psk,
        Uint8List.fromList(List.filled(32, 0x0A)),
        Uint8List.fromList(List.filled(32, 0x0B)),
      );
      expect(
        () => sec.deriveLpadSession(
          proof: proof,
          updateNonce: Uint8List.fromList(List.filled(12, 1)),
          updateAad: Uint8List.fromList(List.filled(16, 2)),
          updateAuth: Uint8List.fromList(List.filled(32, 0xFF)),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a nonce of the wrong length', () {
      final proof = Uint8List(32);
      expect(
        () => sec.deriveLpadSession(
          proof: proof,
          updateNonce: Uint8List(8),
          updateAad: Uint8List(16),
          updateAuth: Uint8List(32),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
