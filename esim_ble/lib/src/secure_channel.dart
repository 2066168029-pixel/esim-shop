/// Secure channel for LPAd devices (AES-CCM session layer).
///
/// The device only requires this when its `secureCommunication` ability is on.
/// Stock cards ship with secure mode *off*, but the handshake is cheap enough
/// that we probe it once and cache the answer.
///
/// Handshake (from the reference implementation's SecurePbChannel):
///
///   PC -> [AUTH] { random: 32 zero bytes }            COMMAND_SECURITY
///   DEV -> [AUTH] { random: 32B challenge, auth: X }
///        X = HMAC(left) where the PSK-derived key signs the challenge + our nonce
///   PC -> [AUTH] { random: ourNonce, auth: Y }        proves we know the PSK
///   DEV -> [UPDATE] { nonce(12), aad(16), auth(32) }  session established
///   ... then every payload is wrapped in SecurityData { id, enc } ...
///
/// PSK: the card's own password, HMAC-SHA256'd after derivation. There is no
/// built-in fallback in this library -- a guessed key produces a fresh
/// challenge instead of UPDATE, which is indistinguishable from a protocol bug.
library;

import 'dart:typed_data';

/// Keys derived from the PSK at handshake time.
class SecureSession {
  final int id;
  final Uint8List sessionKey; // 16 bytes, AES key
  final Uint8List initNonce; // 12 bytes
  final Uint8List aad; // 16 bytes

  SecureSession(this.id, this.sessionKey, this.initNonce, this.aad);

  /// Builds the per-message nonce: initNonce with the 4-byte big-endian counter
  /// added into its last 4 bytes (little-endian carry, as the reference does).
  Uint8List nonceFor(int counter) {
    final out = Uint8List.fromList(initNonce);
    var carry = 0;
    for (var i = 0; i < 4; i++) {
      final idx = 11 - i;
      final sum = (out[idx] & 0xFF) + ((counter >> (i * 8)) & 0xFF) + carry;
      out[idx] = sum & 0xFF;
      carry = sum >> 8;
    }
    for (var i = 4; carry > 0 && i < 12; i++) {
      final idx = 11 - i;
      final sum = (out[idx] & 0xFF) + carry;
      out[idx] = sum & 0xFF;
      carry = sum >> 8;
    }
    return out;
  }
}

/// Security protocol message types (SecurityProtocol.Type).
class SecurityType {
  static const int auth = 0;
  static const int update = 1;
  static const int confirm = 2;
}

/// Test-only constant: the firmware's factory password.
///
/// NOT a runtime fallback. Production code always takes the password from the
/// user (or from Keystore-backed storage) and never guesses. This value stays
/// because the PSK-derivation tests need a fixed input to prove that derivation
/// is deterministic and differs from a user password.
const String testFirmwarePsk = 'Linksfield@Esim#2025';

/// Label mixed into the PSK derivation.
const String pskContext = 'SecurePbChannel';

/// Size of the AES-CCM authentication tag, in bits.
const int ccmTagBits = 32;

/// Extracts the EID prefix that some provisioning flows need, kept here because
/// it is printed on the card next to the PSK.
String normalizeEid(String raw) =>
    raw.replaceAll(RegExp(r'[^0-9]'), '');
