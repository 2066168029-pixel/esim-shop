import 'dart:convert';
import 'dart:typed_data';

import 'package:esim_ble/src/crypto.dart';
import 'package:esim_ble/src/secure_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HMAC-SHA256', () {
    test('matches the RFC 4231 test vector 1', () {
      // key = 20 bytes of 0x0b, data = "Hi There"
      final key = Uint8List.fromList(List.filled(20, 0x0b));
      final data = Uint8List.fromList(utf8.encode('Hi There'));
      final mac = hmacSha256(key, [data]);
      expect(
        mac
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
        'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
      );
    });

    test('concatenates multiple parts like a single buffer', () {
      final key = Uint8List.fromList(List.filled(20, 0x0b));
      final a = Uint8List.fromList([1, 2, 3]);
      final b = Uint8List.fromList([4, 5, 6]);
      final joined = Uint8List.fromList([1, 2, 3, 4, 5, 6]);

      expect(hmacSha256(key, [a, b]), hmacSha256(key, [joined]));
    });
  });

  group('PSK derivation', () {
    test('is deterministic for the same password', () {
      final a = derivePsk(testFirmwarePsk);
      final b = derivePsk(testFirmwarePsk);
      expect(a, b);
      expect(a.length, 32);
    });

    test('differs for different passwords', () {
      expect(derivePsk(testFirmwarePsk), isNot(derivePsk('180651')));
    });
  });

  group('AES-CCM', () {
    final key = Uint8List.fromList(List.generate(16, (i) => i));
    final nonce = Uint8List.fromList(List.generate(12, (i) => 0xA0 + i));
    final aad = Uint8List.fromList(List.generate(16, (i) => i * 2));

    test('encrypt then decrypt round-trips', () {
      final plaintext = Uint8List.fromList(utf8.encode('hello card'));
      final ct = aesCcmEncrypt(
        key: key,
        nonce: nonce,
        plaintext: plaintext,
        aad: aad,
      );
      // Ciphertext must be longer than plaintext by the 32-bit tag.
      expect(ct.length, plaintext.length + 4);

      final pt = aesCcmDecrypt(
        key: key,
        nonce: nonce,
        ciphertext: ct,
        aad: aad,
      );
      expect(pt, plaintext);
    });

    test('a corrupted tag fails to decrypt', () {
      final plaintext = Uint8List.fromList([1, 2, 3, 4]);
      final ct = aesCcmEncrypt(
        key: key,
        nonce: nonce,
        plaintext: plaintext,
        aad: aad,
      );
      ct[ct.length - 1] ^= 0xFF;
      expect(
        () => aesCcmDecrypt(
          key: key,
          nonce: nonce,
          ciphertext: ct,
          aad: aad,
        ),
        throwsA(anything),
      );
    });

    test('wrong AAD fails authentication', () {
      final plaintext = Uint8List.fromList([9, 9, 9]);
      final ct = aesCcmEncrypt(
        key: key,
        nonce: nonce,
        plaintext: plaintext,
        aad: aad,
      );
      final wrongAad = Uint8List(16);
      expect(
        () => aesCcmDecrypt(
          key: key,
          nonce: nonce,
          ciphertext: ct,
          aad: wrongAad,
        ),
        throwsA(anything),
      );
    });

    test('different nonces produce different ciphertexts', () {
      final plaintext = Uint8List.fromList([7, 7, 7, 7]);
      final n2 = Uint8List.fromList(nonce)..[11] = 0xFF;
      final c1 = aesCcmEncrypt(key: key, nonce: nonce, plaintext: plaintext);
      final c2 = aesCcmEncrypt(key: key, nonce: n2, plaintext: plaintext);
      expect(c1, isNot(c2));
    });
  });

  group('Session nonce counter', () {
    test('counter is added into the last 4 bytes, big-endian', () {
      final initNonce = Uint8List.fromList(
        List.generate(12, (i) => i == 11 ? 0x01 : 0x00),
      );
      final session = SecureSession(0, Uint8List(16), initNonce, Uint8List(16));

      expect(session.nonceFor(0)[11], 0x01);
      expect(session.nonceFor(1)[11], 0x02);
      expect(session.nonceFor(255)[11], 0x00); // 0x01 + 0xFF = 0x100
      expect(session.nonceFor(255)[10], 0x01); // carry into byte 10
    });

    test('carries propagate across the full 4-byte window', () {
      final initNonce = Uint8List(12);
      final session = SecureSession(0, Uint8List(16), initNonce, Uint8List(16));
      final n = session.nonceFor(0x01000000);
      expect(n[8], 0x01);
      expect(n[9], 0x00);
      expect(n[10], 0x00);
      expect(n[11], 0x00);
    });
  });

  group('EID normalisation', () {
    test('strips non-digits', () {
      expect(
        normalizeEid('8904404593000000000002196180651'),
        '8904404593000000000002196180651',
      );
      expect(normalizeEid(' 8904 4045-9300 '), '890440459300');
    });
  });
}
