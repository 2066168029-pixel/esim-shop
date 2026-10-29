/// SGP.22 ES10b/ES10c card-side operations over the ISD-R.
///
/// APDU framing follows the reference implementation (lpac's es10x_command):
/// the command is split into [es10xMss]-byte pieces, each carrying
///   CLA=0x80 INS=0xE2 P1=0x11 (more) / 0x91 (last) P2=<sequence number>
/// and the responses are concatenated in sequence.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'asn1.dart';
import 'constants.dart';
import 'euicc_transport.dart';
import 'sgp22.dart' as engine;

export 'constants.dart' show isdrAid, es10xMss;

/// Parsed `LPA:1$smdp.example.com$MATCHING-ID` activation code.
class ActivationCode {
  final String smdpAddress;
  final String matchingId;
  final String? oid;
  final bool confirmationCodeRequired;

  ActivationCode(
    this.smdpAddress,
    this.matchingId, {
    this.oid,
    this.confirmationCodeRequired = false,
  });

  /// Accepts `LPA:1$...` and bare `1$...`, and tolerates the `|ICCID:` suffix
  /// that some suppliers append to the activation code.
  static ActivationCode? tryParse(String raw) {
    var s = raw.trim();
    if (s.contains('|')) s = s.split('|').first;
    if (s.toUpperCase().startsWith('LPA:')) s = s.substring(4);

    final parts = s.split(r'$');
    if (parts.length < 3) return null;
    if (parts[0] != '1') return null; // only activation code version 1
    final address = parts[1];
    final matching = parts[2];
    if (address.isEmpty || matching.isEmpty) return null;
    // SGP.22: matchingId is alphanumeric + dash only.
    if (!RegExp(r'^[A-Za-z0-9-]+$').hasMatch(matching)) return null;

    return ActivationCode(
      address,
      matching,
      oid: parts.length > 3 && parts[3].isNotEmpty ? parts[3] : null,
      confirmationCodeRequired:
          parts.length > 4 && parts[4].isNotEmpty && parts[4] == '1',
    );
  }

  @override
  String toString() => 'LPA:1\$$smdpAddress\$$matchingId';
}

/// A profile as reported by ES10c GetProfilesInfo.
class ProfileSummary {
  final String iccid;
  final String isdpAid;
  final String nickname;
  final String serviceProvider;
  final String profileName;
  final int state;
  final String profileClass;

  ProfileSummary({
    required this.iccid,
    required this.isdpAid,
    required this.nickname,
    required this.serviceProvider,
    required this.profileName,
    required this.state,
    required this.profileClass,
  });

  bool get isEnabled => state == 1;

  @override
  String toString() =>
      'ProfileSummary($iccid, ${profileName.isEmpty ? nickname : profileName}, '
      '${isEnabled ? "enabled" : "disabled"})';
}

class LpaError implements Exception {
  final String message;
  final int? sw;
  LpaError(this.message, [this.sw]);
  @override
  String toString() => sw == null
      ? 'LpaError: $message'
      : 'LpaError: $message (SW=${sw!.toRadixString(16).toUpperCase()})';
}

/// Card-side SGP.22 operations.
///
/// The protocol work is done by [engine.EuiccSession], which speaks APDUs to an
/// [EuiccTransport]. That means the same `Lpa` drives a 9eSIM BLE reader, a
/// Linksfield card, a USB CCID reader or the phone's own eSIM slot -- the
/// transport is the only thing that changes.
class Lpa {
  final engine.EuiccSession _session;

  Lpa(engine.EuiccSession session) : _session = session;

  /// The session underneath (channel bookkeeping for the notification applet).
  engine.EuiccSession get session => _session;

  /// Logical channel the ES10x commands are addressed to.
  int get channel => _session.channel;

  // -- ES10b ---------------------------------------------------------------

  /// ES10b.GetEuiccData with the euiccChallenge tag (0xBF2E).
  Future<Uint8List> getEuiccChallenge() async {
    final rsp = await es10x(tlv(0xBF2E, const []));
    final node = findByTag(rsp, 0xBF2E);
    if (node == null) throw LpaError('No GetEuiccDataResponse');
    final challenge = findByTag(node.self, 0x80);
    if (challenge == null) throw LpaError('No euiccChallenge in response');
    return challenge.value;
  }

  /// ES10b.GetEUICCInfo1 (0xBF20). Returns the full EUICCInfo1 TLV, which is
  /// what gets base64'd into the ES9+ initiateAuthentication call.
  Future<Uint8List> getEuiccInfo1() async {
    final rsp = await es10x(tlv(0xBF20, const []));
    final node = findByTag(rsp, 0xBF20);
    if (node == null) throw LpaError('No GetEuiccInfo1Response');
    return node.self;
  }

  /// ES10b.AuthenticateServer (0xBF38). [serverSigned1] etc. come from the
  /// SM-DP+ initiateAuthentication response.
  Future<Uint8List> authenticateServer({
    required Uint8List serverSigned1,
    required Uint8List serverSignature1,
    required Uint8List euiccCiPkIdToBeUsed,
    required Uint8List serverCertificate,
    required String matchingId,
    String? imei,
  }) async {
    final request = tlvChildren(0xBF38, [
      tlvChildren(0x30, [
        serverSigned1, // signed1 already carries its own 0x30 wrapper
        serverSignature1,
        euiccCiPkIdToBeUsed,
        serverCertificate,
      ]),
      if (imei != null && imei.isNotEmpty) tlv(0x82, utf8.encode(imei)),
      utf8String(matchingId),
    ]);
    final rsp = await es10x(request);
    final node = findByTag(rsp, 0xBF38);
    if (node == null) throw LpaError('No AuthenticateServerResponse');
    return node.self;
  }

  /// ES10b.PrepareDownload (0xBF21).
  Future<Uint8List> prepareDownload({
    required Uint8List smdpSigned2,
    required Uint8List smdpSignature2,
    required Uint8List smdpCertificate,
    String? confirmationCode,
  }) async {
    final request = tlvChildren(0xBF21, [
      tlvChildren(0x30, [smdpSigned2, smdpSignature2, smdpCertificate]),
      if (confirmationCode != null && confirmationCode.isNotEmpty)
        utf8String(confirmationCode),
    ]);
    final rsp = await es10x(request);
    final node = findByTag(rsp, 0xBF21);
    if (node == null) throw LpaError('No PrepareDownloadResponse');
    return node.self;
  }

  /// ES10b.LoadBoundProfilePackage. [bpp] is the full BoundProfilePackage TLV
  /// (0xBF36) exactly as returned by the SM-DP+.
  ///
  /// This is the step that actually installs the profile on the card.
  Future<void> loadBoundProfilePackage(Uint8List bpp) async {
    final rsp = await es10x(bpp);
    // Success carries a ProfileInstallationResult (0xBF37); failure carries an
    // error / bppCommandId we surface to the caller.
    final result = findByTag(rsp, 0xBF37);
    if (result == null) {
      throw LpaError('Card did not return a ProfileInstallationResult');
    }
    final status = findByTag(result.value, 0x80);
    // profileInstallationResult ends with a success/failure OCTET STRING; the
    // first byte 0x00 means success, anything else is an error reason.
    if (status != null && status.value.isNotEmpty && status.value.first != 0) {
      throw LpaError(
        'Profile installation failed (reason 0x'
        '${status.value.first.toRadixString(16).toUpperCase()})',
      );
    }
  }

  /// ES10b.CancelSession, used when a download is abandoned midway.
  Future<Uint8List> cancelSession(int reason) async {
    final rsp = await es10x(tlv(0xBF41, [reason]));
    return rsp;
  }
  // -- ES10c ---------------------------------------------------------------

  /// ES10c.GetProfilesInfo.
  Future<List<ProfileSummary>> listProfiles() async {
    final rsp = await es10x(tlv(0xBF2D, const []));
    return _parseProfiles(rsp);
  }

  Future<void> enableProfile(String iccid) =>
      _profileOp(0xBF31, iccid);

  Future<void> disableProfile(String iccid) =>
      _profileOp(0xBF32, iccid);

  Future<void> deleteProfile(String iccid) =>
      _profileOp(0xBF33, iccid);

  Future<void> setNickname(String iccid, String nickname) async {
    final request = tlvChildren(0xBF29, [
      tlv(0x5A, _iccidBcd(iccid)),
      utf8String(nickname),
    ]);
    await es10x(request);
  }

  Future<void> _profileOp(int tag, String iccid) async {
    final request = tlvChildren(tag, [tlv(0x5A, _iccidBcd(iccid))]);
    final rsp = await es10x(request);
    final node = findByTag(rsp, tag);
    // ProfileOperationResponse carries a result byte: 0 = success.
    if (node != null) {
      final result = findByTag(node.value, 0x80);
      if (result != null && result.value.isNotEmpty && result.value.first != 0) {
        throw LpaError('Profile operation failed (result 0x'
            '${result.value.first.toRadixString(16).toUpperCase()})');
      }
    }
  }

  /// ES10c.GetEuiccConfiguredAddresses -- default SM-DP+ address.
  Future<String?> getDefaultDpAddress() async {
    try {
      final rsp = await es10x(tlv(0xBF3C, const []));
      final node = findByTag(rsp, 0xBF3C);
      if (node == null) return null;
      final addr = findByTag(node.value, 0x80);
      return addr == null ? null : utf8.decode(addr.value, allowMalformed: true);
    } on LpaError {
      return null;
    }
  }

  /// Reads the EID from ES10b.GetEuiccData (tag 0x5A inside 0xBF3E).
  Future<String> readEid() async {
    final rsp = await es10x(tlvChildren(0xBF3E, [tlv(0x5C, const [0x5A])]));
    final node = findByTag(rsp, 0xBF3E);
    if (node == null) throw LpaError('No GetEuiccDataResponse');
    final eid = findByTag(node.self, 0x5A);
    if (eid == null) throw LpaError('Card did not return an EID');
    return _hex(eid.value);
  }

  // -- APDU transport ------------------------------------------------------

  /// Sends a DER request as one or more ES10x APDUs and concatenates responses.
  ///
  /// Framing lives in [engine.EuiccSession.es10x]: 120-byte segments,
  /// `P1=0x11`/`0x91`, `P2` = segment index, 61XX drained with GET RESPONSE.
  ///
  /// Public so sibling modules (notifications) can reuse the same framing.
  Future<Uint8List> es10x(Uint8List der) => _session.es10x(der);

  /// Drains a 61XX chain with GET RESPONSE.
  Future<Uint8List> getResponse(int le) => _session.getResponse(le);

  // -- parsing -------------------------------------------------------------

  List<ProfileSummary> _parseProfiles(Uint8List raw) {
    final out = <ProfileSummary>[];
    final root = findByTag(raw, 0xBF2D);
    if (root == null) return out;

    // ProfileInfoListOk ::= SEQUENCE OF ProfileInfo (tag 0xA0)
    final seq = findByTag(root.value, 0xA0);
    if (seq == null) return out;

    var pos = 0;
    while (pos < seq.value.length) {
      DerNode node;
      try {
        node = parseNode(seq.value, pos);
      } on FormatException {
        break;
      }
      pos += node.self.length;
      if (node.tag != 0x30) continue;

      out.add(ProfileSummary(
        iccid: _hexNullable(findByTag(node.value, 0x5A)),
        isdpAid: _hexNullable(findByTag(node.value, 0x4F)),
        nickname: _strNullable(findByTag(node.value, 0x90)),
        serviceProvider: _strNullable(findByTag(node.value, 0x91)),
        profileName: _strNullable(findByTag(node.value, 0x92)),
        state: _readProfileState(node.value),
        profileClass: _strNullable(findByTag(node.value, 0x93)),
      ));
    }
    return out;
  }

  int _readProfileState(Uint8List body) {
    // profileState is [9F70] EXPLICIT with an INTEGER inside.
    final node = findByTag(body, 0x9F70);
    if (node == null) return 0;
    final intNode = findByTag(node.value, 0x02);
    if (intNode != null && intNode.value.isNotEmpty) return intNode.value.last;
    if (node.value.isNotEmpty) return node.value.last;
    return 0;
  }

  static Uint8List _iccidBcd(String iccid) {
    final digits = iccid.replaceAll(RegExp(r'[^0-9]'), '');
    final padded = digits.length.isOdd ? '${digits}F' : digits;
    final out = <int>[];
    for (var i = 0; i + 1 < padded.length; i += 2) {
      final hi = int.parse(padded[i], radix: 16);
      final lo = int.parse(padded[i + 1], radix: 16);
      out.add((lo << 4) | hi); // nibble-swapped per SGP.02
    }
    return Uint8List.fromList(out);
  }

  static String _hexNullable(DerNode? n) => n == null ? '' : _hex(n.value);

  static String _strNullable(DerNode? n) {
    if (n == null) return '';
    return utf8.decode(n.value, allowMalformed: true);
  }

  static String _hex(List<int> b) =>
      b.map((e) => e.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
}
