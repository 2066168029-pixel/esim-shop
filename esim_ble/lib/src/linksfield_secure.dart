/// Linksfield secure channel (AES-CCM session layer).
///
/// Reconstructed from `k3.java` / `n3.java` / `m3.java` in the vendor APK and
/// verified against the device's own answer: the card replies to a plaintext
/// request with `DeviceRsp{security: SecurityProtocol{type: ...}}`, i.e. "secure
/// channel required".
///
/// Exchange (three messages, all wrapped in `EuiccDeviceReq{cmd: SECURITY}`):
///
///   1. PC  → SecurityProtocol{type: AUTH}                      (start)
///      DEV → SecurityProtocol{type: AUTH, auth{random: 32B}}   (challenge)
///   2. PC  → SecurityProtocol{type: AUTH, auth{random: pcNonce,
///                                               auth: HMAC(psk,label,challenge,pcNonce)}}
///      DEV → SecurityProtocol{type: UPDATE, config{nonce 12, aad 16, auth 32}}
///   3. Session key = bytes 16..31 of that HMAC; the device proves it with
///      config.auth = HMAC(sessionKey, configNonce ++ configAad).
///
/// After that every request payload is wrapped:
///   SecurityData{ id: counter+1, enc: AES-CCM(key, nonce = initNonce+counter) }
///
/// Note on `type = 16`: the card answered with 16, which is not in the APK's
/// enum (AUTH=0/UPDATE=1/CONFIRM=2). It is treated as a firmware-extended
/// "secure required" marker; the handshake below is the vendor's documented
/// procedure and is tried verbatim rather than adapted to the unknown value.
library;

import 'dart:math';
import 'dart:typed_data';

import 'crypto.dart';
import 'linksfield_frame.dart' as lf;

/// Test-only constant: the firmware's factory password.
///
/// NOT a runtime fallback. `lpadDefaultPsk` used to be substituted whenever a
/// caller passed no password, which turned every provisioned card into a bogus
/// "protocol failure". That fallback is gone: callers must supply the card
/// password. This value stays only because the handshake tests need a fixed
/// input to prove derivation is deterministic and differs from a user password.
const String testFirmwarePsk = 'Linksfield@Esim#2025';

/// Label mixed into the PSK derivation.
///
/// ⚠ UNVERIFIED (2026-10-24). Neither `SecurePbChannel` nor any `SecurePb*`
/// substring exists in the APK's Dart AOT string table (`libapp.so`). The
/// original claim (`n3.a(String)`) could not be re-located in this build.
/// Four independent frame pairs from the 2026-10-23 log are consistent only
/// if the AES key is a 16-byte value derived some other way; see
/// `work/HANDSHAKE-ANALYSIS.md`.
const String pskLabel = 'SecurePbChannel';

/// AES-CCM tag length in bits, as the firmware uses it.
const int ccmTagBits = 32;

/// Active session keys.
class LpadSecureSession {
  final Uint8List sessionKey; // 16B AES key
  final Uint8List initNonce; // 12B
  final Uint8List aad; // 16B
  int counter; // message id

  LpadSecureSession({
    required this.sessionKey,
    required this.initNonce,
    required this.aad,
    this.counter = 0,
  });

  /// Per-message nonce: initNonce with the 4-byte big-endian counter added into
  /// its last four bytes (the reference adds with carry, same as here).
  Uint8List nonceFor(int c) {
    final out = Uint8List.fromList(initNonce);
    var carry = 0;
    for (var i = 0; i < 4; i++) {
      final idx = 11 - i;
      final sum = (out[idx] & 0xFF) + ((c >> (i * 8)) & 0xFF) + carry;
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

  /// Wraps a request as `SecurityData{id: ++counter, enc: ...}`.
  Uint8List wrap(Uint8List plain) {
    counter += 1;
    final ct = aesCcmEncrypt(
      key: sessionKey,
      nonce: nonceFor(counter),
      plaintext: plain,
      aad: aad,
      tagBits: ccmTagBits,
    );
    return encodeSecurityData(counter, ct);
  }

  /// Unwraps a `SecurityData{enc}` reply, or returns null when the payload is
  /// not a SecurityData at all.
  Uint8List? unwrap(Uint8List raw) {
    final parsed = parseSecurityData(raw);
    if (parsed == null) return null;
    // The sender increments its own counter and stamps the value in `id`; the
    // nonce must be derived from THAT, not from our local counter.
    id = parsed.id;
    try {
      return aesCcmDecrypt(
        key: sessionKey,
        nonce: nonceFor(parsed.id),
        ciphertext: parsed.ciphertext,
        aad: aad,
        tagBits: ccmTagBits,
      );
    } catch (_) {
      return null;
    }
  }

  /// Last id seen on a received envelope (diagnostics only).
  int id = 0;
}

// ---------------------------------------------------------------------------
// SecurityProtocol / SecurityAuth / SecurityConfig / SecurityData
// ---------------------------------------------------------------------------

class SecurityType {
  static const int auth = 0;
  static const int update = 1;
  static const int confirm = 2;
}

/// `SecurityProtocol{type, auth{random, auth}, config{nonce, aad, auth}}`
class SecurityProtocolMsg {
  final int type;
  final List<int> authRandom;
  final List<int> authValue;
  final List<int> configNonce;
  final List<int> configAad;
  final List<int> configAuth;

  SecurityProtocolMsg({
    required this.type,
    this.authRandom = const <int>[],
    this.authValue = const <int>[],
    this.configNonce = const <int>[],
    this.configAad = const <int>[],
    this.configAuth = const <int>[],
  });

  static SecurityProtocolMsg parse(Uint8List data) {
    var type = -1;
    Uint8List random = Uint8List(0);
    Uint8List auth = Uint8List(0);
    Uint8List nonce = Uint8List(0);
    Uint8List aad = Uint8List(0);
    Uint8List mac = Uint8List(0);

    final r = lf.PbReader(data);
    while (true) {
      final t = r.nextTag();
      if (t == null) break;
      final (field, wire) = t;
      switch (field) {
        case 1:
          if (wire == 0) {
            type = r.readUint();
          } else if (wire == 2) {
            // A bare `SecurityAuth{random, auth}` arrives at the top level with
            // no `type` ahead of it. Field 1 is then the *random*, not an enum;
            // reading it as a varint would consume a length byte and leave the
            // reader stranded mid-message ("unsupported wire type 3").
            final blob = r.readBytes();
            if (random.isEmpty) random = blob;
          } else {
            r.skip(wire);
          }
        case 2:
          final body = r.readBytes();
          // Auth may be one or two wrappers deep (`2A 14 12 12 0A 10 …` on the
          // captured card). Walk down until a 16/32-byte leaf appears; that is
          // the challenge regardless of how many envelopes the firmware used.
          // Shape varies by firmware: `auth{random, auth}` directly, or the
          // same thing behind one or two length-delimited wrappers. Fill both
          // slots from what the body actually contains so the handshake code
          // does not have to care which shape arrived.
          final parsed = _parseAuthBody(body);
          // A bare `SecurityAuth{random, auth}` is field 1 = random, field 2 =
          // proof. Here field 2 is a *proof*, which is not an auth message, so
          // `_parseAuthBody` finds nothing in it. Overwriting `random` with that
          // empty result would silently erase the nonce captured at field 1.
          if (parsed.random.isNotEmpty || parsed.auth.isNotEmpty) {
            random = parsed.random;
            auth = parsed.auth;
          } else if (random.isNotEmpty && auth.isEmpty) {
            auth = body;
          }
          if (random.isEmpty && auth.isEmpty) {
            // The captured firmware nests auth one level up: field 5 holds a
            // 20-byte body whose own field 1/2 *are* `auth` (`2A 14 12 12 0A
            // 10 <16B>`). Treating that body as auth directly walks the wrong
            // level, so descend one more time before falling back to the raw
            // body. Without this the first frame -- the one that actually
            // carries the challenge -- parses as "no challenge".
            var inner = body;
            for (var depth = 0; depth < 2 && inner.isNotEmpty; depth++) {
              Uint8List? next;
              try {
                final br = lf.PbReader(inner);
                while (true) {
                  final t2 = br.nextTag();
                  if (t2 == null) break;
                  if (t2.$1 == 2 && t2.$2 == 2) {
                    next = br.readBytes();
                    break;
                  }
                  br.skip(t2.$2);
                }
              } on FormatException {
                break;
              }
              if (next == null) break;
              final deep = _parseAuthBody(next);
              if (deep.random.isNotEmpty || deep.auth.isNotEmpty) {
                random = deep.random;
                auth = deep.auth;
                break;
              }
              inner = next;
            }
          }
          if (random.isEmpty && auth.isEmpty) auth = body;
          // A body that carries a *well-formed* challenge but no explicit type
          // is an AUTH challenge: that is the only message the card sends
          // unprompted. A truncated body (announced 18, carried 16) is not one,
          // even though a leaf could be dug out of it.
          if (type < 0 && (random.length == 16 || random.length == 32)) {
            type = SecurityType.auth;
          }
        case 3:
        case 5:
          // Field 5 is `auth` in the *captured* card, field 3 is `config` in the
          // vendor schema. Both appear on the wire, and the body tells them
          // apart: an auth body digs out to a 16/32-byte leaf, a config body
          // has 12/16/32-byte fields. Trying auth first and config second keeps
          // one parser for both frame shapes.
          final blob = r.readBytes();
          final authTry = _parseAuthBody(blob);
          final hasLeaf = authTry.random.length == 16 ||
              authTry.random.length == 32 ||
              authTry.auth.length == 16 ||
              authTry.auth.length == 32;
          if (hasLeaf && (random.isEmpty && auth.isEmpty)) {
            random = authTry.random;
            auth = authTry.auth;
            if (type < 0) type = SecurityType.auth;
          }
          final inner = lf.PbReader(blob);
          var sawConfig = false;
          while (true) {
            final t2 = inner.nextTag();
            if (t2 == null) break;
            switch (t2.$1) {
              case 1:
                nonce = inner.readBytes();
                sawConfig = true;
              case 2:
                aad = inner.readBytes();
              case 3:
                mac = inner.readBytes();
              default:
                inner.skip(t2.$2);
            }
          }
          // A blob that only ever produced a 12-byte nonce is a config, not an
          // auth; do not keep it as a challenge.
          if (sawConfig && nonce.length == 12) {
            random = Uint8List(0);
            auth = Uint8List(0);
          }
        default:
          r.skip(wire);
      }
    }
    return SecurityProtocolMsg(
      type: type,
      authRandom: random,
      authValue: auth,
      configNonce: nonce,
      configAad: aad,
      configAuth: mac,
    );
  }






  /// Strict field walk: returns true only when every length fits exactly.
  ///
  /// `PbReader.readBytes` clamps a too-long field to the buffer, so a blob whose
  /// header announces 18 bytes with 16 behind it reads as "fine, 16 bytes" and
  /// gets trusted. That is how a corrupted payload became a 16-byte challenge.
  static bool _fieldsFitExactly(Uint8List data) {
    var i = 0;
    while (i < data.length) {
      final tag = data[i];
      i++;
      final field = tag >> 3;
      final wire = tag & 7;
      if (field == 0) return false;
      if (wire == 0) {
        var n = 0;
        while (i < data.length && (data[i] & 0x80) != 0 && n < 10) {
          i++;
          n++;
        }
        if (i >= data.length) return false;
        i++;
      } else if (wire == 2) {
        var len = 0, shift = 0;
        while (i < data.length) {
          final x = data[i];
          i++;
          len |= (x & 0x7F) << shift;
          if ((x & 0x80) == 0) break;
          shift += 7;
          if (shift > 28) return false;
        }
        if (i + len > data.length) return false;
        i += len;
      } else if (wire == 5) {
        if (i + 4 > data.length) return false;
        i += 4;
      } else if (wire == 1) {
        if (i + 8 > data.length) return false;
        i += 8;
      } else {
        return false;
      }
    }
    return true;
  }

  /// Reads an auth body however deeply it is wrapped.
  ///
  /// Observed shapes:
  ///   * `12 0A 0A 08 <8B>`                    — auth{random}
  ///   * `12 12 0A 10 <16B>`                    — auth{random:16}
  ///   * `12 12 0A 10 <16B>` behind one wrapper — the captured card
  ///
  /// A leaf is identified by size: 16 or 32 bytes is a nonce/proof, anything
  /// else is descended into if it parses as a message.
  static ({Uint8List random, Uint8List auth}) _parseAuthBody(Uint8List data) {
    final empty = Uint8List(0);
    // A body whose own lengths do not add up is corrupted; report nothing so no
    // handshake can start from it.
    if (!_fieldsFitExactly(data)) return (random: empty, auth: empty);

    // Direct shape: random at field 1, proof at field 2.
    var directRandom = empty;
    var directAuth = empty;
    var truncated = 0;
    try {
      final r = lf.PbReader(data);
      var sawField = false;
      while (true) {
        final t = r.nextTag();
        if (t == null) break;
        sawField = true;
        if (t.$2 == 2) {
          try {
            final b = r.readBytes();
            if (t.$1 == 1) directRandom = b;
            if (t.$1 == 2) directAuth = b;
          } on FormatException {
            // Announced length exceeds the buffer: the shape is a lie.
            truncated++;
            break;
          }
        } else {
          try {
            r.skip(t.$2);
          } on FormatException {
            truncated++;
            break;
          }
        }
      }
      // Direct shape wins whenever it is internally consistent: a complete
      // field 1 (and optional field 2) with nothing left over. Size is only a
      // tie-breaker for wrapped bodies, where a leaf could otherwise look like
      // a message.
      // A direct field 1 that announces more bytes than the body holds means
      // the blob is malformed (the capture had `12 12` with only 16 following),
      // so it must not be trusted as a challenge.
      if (sawField && directRandom.isNotEmpty && truncated == 0 &&
          _fieldsFitExactly(data)) {
        return (random: directRandom, auth: directAuth);
      }
    } on FormatException {
      // fall through to the wrapped shape
    }

    // Wrapped shape: descend one level at a time until a leaf shows up.
    var cur = data;
    for (var depth = 0; depth < 4; depth++) {
      Uint8List? best;
      var bestField = 0;
      try {
        final r = lf.PbReader(cur);
        while (true) {
          final t = r.nextTag();
          if (t == null) break;
          if (t.$2 == 2) {
            final b = r.readBytes();
            if (best == null || b.length > best.length) {
              best = b;
              bestField = t.$1;
            }
          } else {
            r.skip(t.$2);
          }
        }
      } on FormatException {
        // A malformed outer frame means any leaf we dug out is an artefact of
        // misreading, not a challenge. Bail out instead of guessing.
        return (random: empty, auth: empty);
      }
      if (best == null) break;
      if (best.length == 16 || best.length == 32) {
        // A 16/32-byte leaf inside a wrapper is a nonce or a proof. Anything
        // else (e.g. an 18-byte field that only carries 16 real bytes) is not
        // a valid challenge and must not start a handshake.
        return (
          random: bestField == 1 ? best : empty,
          auth: bestField == 2 ? best : empty,
        );
      }
      if (best.length >= cur.length) break;
      cur = best;
    }
    return (random: empty, auth: empty);
  }

  @override
  String toString() => 'SecurityProtocol(type=$type, '
      'authRandom=${authRandom.length}B, authValue=${authValue.length}B, '
      'config=${configNonce.length}/${configAad.length}/${configAuth.length}B)';
}

/// `SecurityProtocol{type: AUTH}` — start of the handshake.
Uint8List encodeAuthStart() =>
    (lf.PbWriter()..uint(1, SecurityType.auth)).toBytes();

/// `SecurityProtocol{type: AUTH, auth{random, auth}}` — the step-2 reply body.
///
/// Correction history, because both extremes were tried against a real card:
///   * `SecurityProtocol{type, auth{random, auth}}`            -> {field5: 5}
///   * bare `SecurityAuth{random, auth}`                       -> {field5: 5}
///
/// The bare form was a misreading of `k3.a`: it calls
/// `SecurityAuth.Builder.setRandom/setAuth`, then
/// `SecurityProtocol.Builder.setAuth(authBuilder)` -- i.e. the auth message is
/// nested *inside* a SecurityProtocol that still carries `type`. Dropping the
/// type produced a `SecurityProtocol` whose field 1 was a length-delimited
/// random blob, which the card reads as an invalid enum and rejects.
///
/// `random` is our own 32-byte nonce (`SecureRandom.nextBytes` in the vendor),
/// `auth` is the 32-byte proof.
Uint8List encodeAuthReply(Uint8List random, Uint8List auth) {
  final inner = (lf.PbWriter()
        ..bytes(1, random)
        ..bytes(2, auth))
      .toBytes();
  return (lf.PbWriter()
        ..uint(1, SecurityType.auth)
        ..bytes(2, inner))
      .toBytes();
}

/// `SecurityData{id, sec|enc|encsec}` — the per-message envelope.
///
/// Field numbers straight from the APK's `SecurityData` setters:
///   `setId` → 1, `setEnc` → 2, `setSec` → 3, `setEncsec` → 4
///
/// `sec` (3) carries a plaintext `SecurityProtocol` during the handshake; `enc`
/// (2) carries the AES-CCM ciphertext once a session exists. This builder is for
/// the plaintext case -- encrypted traffic goes through `LpadSecureSession`.
Uint8List encodeSecurityData(int id, Uint8List cipher) => (lf.PbWriter()
      ..uint(1, id)
      ..bytes(2, cipher))
    .toBytes();

/// `SecurityData{id, sec: SecurityProtocol}` — how the vendor sends every
/// handshake message.
///
/// `k3.a(SecurityProtocol.Builder)` builds `SecurityData`, sets `id` from the
/// message counter, sets `sec` to the protocol being negotiated, then wraps the
/// whole thing in `EuiccDeviceReq{cmd: COMMAND_SECURITY}`.
///
/// Skipping this envelope and sending the bare `SecurityProtocol` inside cmd=3
/// is what produced `{field5: 5}` from the card: it looked for `sec` at field 3,
/// found nothing it recognised, and answered with a status code instead of
/// UPDATE. This overload therefore always writes field 3.
Uint8List encodeSecurityDataSec(int id, Uint8List securityProtocol) =>
    (lf.PbWriter()
          ..uint(1, id)
          ..bytes(3, securityProtocol))
        .toBytes();

class ParsedSecurityData {
  final int id;
  final Uint8List ciphertext;
  final int error;
  ParsedSecurityData(this.id, this.ciphertext, this.error);
}

/// Reads `SecurityData{id, enc|encsec, error}`; null when the bytes are not one.
ParsedSecurityData? parseSecurityData(Uint8List data) {
  var id = 0;
  var cipher = Uint8List(0);
  var sawCipher = false;
  var error = 0;
  final r = lf.PbReader(data);
  try {
    while (true) {
      final t = r.nextTag();
      if (t == null) break;
      final (field, wire) = t;
      switch (field) {
        case 1:
          id = r.readUint();
        case 2:
        case 4:
          cipher = r.readBytes();
          sawCipher = true;
        case 5:
          error = r.readUint();
        default:
          r.skip(wire);
      }
    }
  } on FormatException {
    return null;
  }
  if (!sawCipher) return null;
  return ParsedSecurityData(id, cipher, error);
}

// ---------------------------------------------------------------------------
// Key derivation
// ---------------------------------------------------------------------------

/// Fills [out] with cryptographically random bytes.
///
/// The vendor derives the step-2 nonce from `java.security.SecureRandom`;
/// `Random.secure()` is the Dart equivalent.
void fillRandom(Uint8List out) {
  final r = Random.secure();
  for (var i = 0; i < out.length; i++) {
    out[i] = r.nextInt(256);
  }
}

/// `n3.a(String)`: HMAC-SHA256(password, "SecurePbChannel").
Uint8List derivePskKey(String password) => hmacSha256(
      Uint8List.fromList(password.codeUnits),
      [Uint8List.fromList(pskLabel.codeUnits)],
    );

/// Step-2 proof: HMAC(pskKey, label ++ challenge ++ pcNonce).
Uint8List buildProof(Uint8List pskKey, Uint8List challenge, Uint8List pcNonce) =>
    hmacSha256(pskKey, [
      Uint8List.fromList(pskLabel.codeUnits),
      challenge,
      pcNonce,
    ]);

/// Turns the device's UPDATE into a session, verifying its MAC.
///
/// Throws [FormatException] with an explanatory message when the derivation does
/// not line up (wrong password, or a firmware that salts differently).
LpadSecureSession deriveLpadSession({
  required Uint8List proof,
  required Uint8List updateNonce,
  required Uint8List updateAad,
  required Uint8List updateAuth,
}) {
  if (updateNonce.length != 12) {
    throw FormatException('UPDATE nonce 必须是 12 字节，实际 ${updateNonce.length}');
  }
  final key = Uint8List.sublistView(proof, 16, 32);
  final expected = hmacSha256(key, [updateNonce, updateAad]);
  if (!_equals(expected, updateAuth)) {
    throw FormatException(
      '设备 MAC 校验失败（密码不对，或固件用了不同的派生方式）\n'
      '  期望: ${_hex(expected)}\n'
      '  收到: ${_hex(updateAuth)}',
    );
  }
  return LpadSecureSession(
    sessionKey: Uint8List.fromList(key),
    initNonce: Uint8List.fromList(updateNonce),
    aad: Uint8List.fromList(updateAad),
  );
}

bool _equals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join();

/// Exposed for tests only: the same HMAC used to verify the device's UPDATE MAC.
Uint8List hmacForTest(Uint8List key, List<Uint8List> parts) => hmacSha256(key, parts);


/// Test hook: exposes the strictness check so a failing case can be inspected
/// without reading the parser.
bool debugFieldsFitExactly(Uint8List data) => SecurityProtocolMsg._fieldsFitExactly(data);

/// Test hook: the parsed auth body for a given security payload.
({Uint8List random, Uint8List auth}) debugParseAuthBody(Uint8List data) =>
    SecurityProtocolMsg._parseAuthBody(data);
