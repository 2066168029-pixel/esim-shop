/// LPAd secure-channel handshake.
///
/// The device advertises a `secureCommunication` ability. When it is on, every
/// ES10b/SCARD payload must be wrapped in `SecurityData { id, enc }` with
/// AES-CCM, and the session keys come from this exchange:
///
///   1. PC  -> COMMAND_SECURITY / SecurityProtocol { type: AUTH,
///                                                   auth.random: 32 zero bytes }
///      DEV -> SecurityProtocol { type: AUTH,
///                                auth.random: challenge(32),
///                                auth.auth:   proof(32) }
///   2. PC derives its own nonce, proves PSK possession:
///        pcProof = HMAC(pskKey, "SecurePbChannel", challenge, pcNonce)  -> 32B
///      PC  -> SecurityProtocol { type: AUTH,
///                                auth.random: pcNonce(32),
///                                auth.auth:   pcProof(32) }
///   3. DEV -> SecurityProtocol { type: UPDATE,
///                                config.nonce(12), config.aad(16),
///                                config.auth(32) }
///      The session key is the second half of the pcProof hash; the device
///      proves the same derivation by returning a MAC we verify.
///
/// After that, message counter `id` starts at 0 and increments per message.
library;

import 'dart:typed_data';

import 'crypto.dart';
import 'proto_codec.dart';
import 'secure_channel.dart';

/// Marker for a handshake failure with enough detail to debug from a screenshot.
class SecureChannelException implements Exception {
  final String message;
  SecureChannelException(this.message);
  @override
  String toString() => 'SecureChannelException: $message';
}

/// Encodes `SecurityProtocol { type, auth: {random, auth} }`.
Uint8List encodeAuthReq(Uint8List random, Uint8List auth) {
  final authMsg = (ProtoWriter()
        ..bytes(1, random)
        ..bytes(2, auth))
      .toBytes();
  return (ProtoWriter()
        ..int32(1, SecurityType.auth)
        ..message(2, authMsg))
      .toBytes();
}

/// Encodes the initial `SecurityProtocol { type: AUTH }` with no auth block,
/// which the firmware treats as "start the handshake".
Uint8List encodeAuthStart() {
  return (ProtoWriter()..int32(1, SecurityType.auth)).toBytes();
}

/// Parsed `SecurityProtocol` reply.
class SecurityProtocolReply {
  final int type;
  final Uint8List authRandom;
  final Uint8List authValue;
  final Uint8List configNonce;
  final Uint8List configAad;
  final Uint8List configAuth;

  SecurityProtocolReply({
    required this.type,
    required this.authRandom,
    required this.authValue,
    required this.configNonce,
    required this.configAad,
    required this.configAuth,
  });

  static SecurityProtocolReply parse(Uint8List data) {
    var type = -1;
    var authRandom = Uint8List(0);
    var authValue = Uint8List(0);
    var configNonce = Uint8List(0);
    var configAad = Uint8List(0);
    var configAuth = Uint8List(0);

    final r = ProtoReader(data);
    while (true) {
      final tag = r.nextTag();
      if (tag == null) break;
      final (field, wire) = tag;
      switch (field) {
        case 1:
          type = r.readInt32();
        case 2:
          final inner = ProtoReader(r.readBytes());
          while (true) {
            final t2 = inner.nextTag();
            if (t2 == null) break;
            if (t2.$1 == 1) {
              authRandom = inner.readBytes();
            } else if (t2.$1 == 2) {
              authValue = inner.readBytes();
            } else {
              inner.skip(t2.$2);
            }
          }
        case 3:
          final inner = ProtoReader(r.readBytes());
          while (true) {
            final t2 = inner.nextTag();
            if (t2 == null) break;
            switch (t2.$1) {
              case 1:
                configNonce = inner.readBytes();
              case 2:
                configAad = inner.readBytes();
              case 3:
                configAuth = inner.readBytes();
              default:
                inner.skip(t2.$2);
            }
          }
        default:
          r.skip(wire);
      }
    }

    return SecurityProtocolReply(
      type: type,
      authRandom: authRandom,
      authValue: authValue,
      configNonce: configNonce,
      configAad: configAad,
      configAuth: configAuth,
    );
  }
}

/// Runs the handshake against a device that already sent its AUTH challenge.
///
/// [challenge] is `reply.authRandom` from the device's first AUTH message.
/// Returns the established session, or throws [SecureChannelException].
SecureSession deriveSession({
  required Uint8List challenge,
  required Uint8List pskKey,
  required Uint8List pcNonce,
  Uint8List? deviceConfigNonce,
  Uint8List? deviceConfigAad,
  Uint8List? deviceConfigAuth,
  Uint8List? previousProof,
}) {
  if (challenge.isEmpty) {
    throw SecureChannelException('Device sent an empty challenge');
  }

  // pcProof = HMAC(pskKey, label, challenge, pcNonce)
  final proof = hmacSha256(pskKey, [
    Uint8List.fromList(pskContext.codeUnits),
    challenge,
    pcNonce,
  ]);

  // Without the device's UPDATE we cannot finish; the caller uses [proof] to
  // build the second AUTH message and calls this again with the UPDATE data.
  if (deviceConfigNonce == null || deviceConfigAad == null) {
    throw SecureChannelException(
      'Incomplete handshake: device UPDATE not received yet',
    );
  }
  if (deviceConfigNonce.length != 12) {
    throw SecureChannelException(
      'Device nonce must be 12 bytes, got ${deviceConfigNonce.length}',
    );
  }

  // Session key is the second 16 bytes of the proof hash.
  final sessionKey = Uint8List.sublistView(proof, 16, 32);

  // Device proves the same derivation: HMAC(sessionKey, nonce, aad) truncated
  // to 32 bytes must equal config.auth.
  if (deviceConfigAuth != null && deviceConfigAuth.isNotEmpty) {
    final expected = hmacSha256(sessionKey, [deviceConfigNonce, deviceConfigAad]);
    if (!_constantTimeEquals(expected, deviceConfigAuth) &&
        !_constantTimeEquals(
          Uint8List.sublistView(expected, 0, 16),
          Uint8List.sublistView(deviceConfigAuth, 0, 16),
        )) {
      throw SecureChannelException(
        'Device MAC did not verify — wrong password?',
      );
    }
  }

  return SecureSession(0, sessionKey, deviceConfigNonce, deviceConfigAad);
}

/// Builds the proof bytes the device expects in the second AUTH message.
Uint8List buildProof(Uint8List pskKey, Uint8List challenge, Uint8List pcNonce) {
  return hmacSha256(pskKey, [
    Uint8List.fromList(pskContext.codeUnits),
    challenge,
    pcNonce,
  ]);
}

/// Compares two byte lists without leaking timing information.
bool _constantTimeEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
