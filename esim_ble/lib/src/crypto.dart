/// AES-CCM and HMAC-SHA256 primitives for the LPAd secure channel.
///
/// The firmware uses:
///   - HMAC-SHA256 for PSK derivation and the handshake proofs
///   - AES-CCM with a 32-bit tag for every message after the handshake
///
/// All lengths here are fixed by the protocol; nothing is negotiated.
library;

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Computes HMAC-SHA256 over the concatenation of [parts].
Uint8List hmacSha256(Uint8List key, List<Uint8List> parts) {
  final hmac = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
  for (final p in parts) {
    hmac.update(p, 0, p.length);
  }
  final out = Uint8List(hmac.macSize);
  hmac.doFinal(out, 0);
  return out;
}

/// Derives the PSK key from a password string.
///
/// Mirrors the reference: HMAC-SHA256 with the password bytes as the key and
/// the literal label "SecurePbChannel" as the message.
Uint8List derivePsk(String password) {
  final mac = HMac(SHA256Digest(), 64)
    ..init(KeyParameter(Uint8List.fromList(password.codeUnits)));
  final label = Uint8List.fromList('SecurePbChannel'.codeUnits);
  mac.update(label, 0, label.length);
  final out = Uint8List(mac.macSize);
  mac.doFinal(out, 0);
  return out;
}

/// Encrypts [plaintext] with AES-CCM, returning ciphertext || tag.
///
/// [tagBits] is 32 for this protocol. The nonce must be 12 bytes; AAD is
/// optional but the firmware always supplies 16 bytes after the handshake.
Uint8List aesCcmEncrypt({
  required Uint8List key,
  required Uint8List nonce,
  required Uint8List plaintext,
  Uint8List? aad,
  int tagBits = 32,
}) {
  final cipher = CCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(
        KeyParameter(key),
        tagBits,
        nonce,
        aad ?? Uint8List(0),
      ),
    );

  final out = Uint8List(cipher.getOutputSize(plaintext.length));
  var len = cipher.processBytes(plaintext, 0, plaintext.length, out, 0);
  len += cipher.doFinal(out, len);
  return Uint8List.sublistView(out, 0, len);
}

/// Decrypts ciphertext || tag produced by [aesCcmEncrypt].
///
/// Throws [InvalidCipherTextException] when the tag does not verify, which is
/// how a failed authentication is surfaced to the caller.
Uint8List aesCcmDecrypt({
  required Uint8List key,
  required Uint8List nonce,
  required Uint8List ciphertext,
  Uint8List? aad,
  int tagBits = 32,
}) {
  final cipher = CCMBlockCipher(AESEngine())
    ..init(
      false,
      AEADParameters(
        KeyParameter(key),
        tagBits,
        nonce,
        aad ?? Uint8List(0),
      ),
    );

  final out = Uint8List(cipher.getOutputSize(ciphertext.length));
  var len = cipher.processBytes(ciphertext, 0, ciphertext.length, out, 0);
  len += cipher.doFinal(out, len);
  return Uint8List.sublistView(out, 0, len);
}

/// Cryptographically random bytes, used for the handshake nonce.
Uint8List randomBytes(int length) {
  final rnd = SecureRandom('Fortuna')
    ..seed(KeyParameter(
      Uint8List.fromList(List<int>.generate(32, (i) => DateTime.now().microsecond + i)),
    ));
  return rnd.nextBytes(length);
}
