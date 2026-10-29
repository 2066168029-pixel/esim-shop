/// ES9+ HTTP client for the SM-DP+.
///
/// Endpoints (all POST, JSON, relative to https://<smdp>):
///   /gsma/rsp2/es9plus/initiateAuthentication
///   /gsma/rsp2/es9plus/authenticateClient
///   /gsma/rsp2/es9plus/getBoundProfilePackage
///   /gsma/rsp2/es9plus/cancelSession
///   /gsma/rsp2/es9plus/handleNotification
///
/// Headers are the ones the SGP.22 spec mandates and mirrors the reference
/// client:
///   User-Agent: gsma-rsp-lpad
///   X-Admin-Protocol: gsma/rsp/v2.2.2
///   Content-Type: application/json
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class SmdpError implements Exception {
  final String message;
  final String? subjectCode;
  final String? reasonCode;
  final int? httpStatus;

  SmdpError(this.message, {this.subjectCode, this.reasonCode, this.httpStatus});

  @override
  String toString() {
    final codes = [
      if (subjectCode != null) 'subject=$subjectCode',
      if (reasonCode != null) 'reason=$reasonCode',
      if (httpStatus != null) 'http=$httpStatus',
    ].join(', ');
    return 'SmdpError: $message${codes.isEmpty ? '' : ' ($codes)'}';
  }
}

/// Result of initiateAuthentication.
class AuthenticationData {
  final String transactionId;
  final Uint8List serverSigned1;
  final Uint8List serverSignature1;
  final Uint8List euiccCiPkIdToBeUsed;
  final Uint8List serverCertificate;

  AuthenticationData({
    required this.transactionId,
    required this.serverSigned1,
    required this.serverSignature1,
    required this.euiccCiPkIdToBeUsed,
    required this.serverCertificate,
  });
}

/// Result of authenticateClient.
class ClientAuthenticationData {
  final Uint8List profileMetadata;
  final Uint8List smdpSigned2;
  final Uint8List smdpSignature2;
  final Uint8List smdpCertificate;

  ClientAuthenticationData({
    required this.profileMetadata,
    required this.smdpSigned2,
    required this.smdpSignature2,
    required this.smdpCertificate,
  });
}

/// Profile metadata returned by authenticateClient, shown as a preview before
/// the profile is actually installed.
class ProfileMetadata {
  final String iccid;
  final String serviceProviderName;
  final String profileName;
  final String profileClass;

  ProfileMetadata({
    required this.iccid,
    required this.serviceProviderName,
    required this.profileName,
    required this.profileClass,
  });

  @override
  String toString() => 'ProfileMetadata($iccid, $serviceProviderName, $profileName)';
}

/// Talks to one SM-DP+ host for one download transaction.
class SmdpClient {
  final String address;
  final http.Client _http;
  final Duration timeout;

  SmdpClient(this.address, {http.Client? client, this.timeout = const Duration(seconds: 60)})
      : _http = client ?? http.Client();

  static const _headers = {
    'User-Agent': 'gsma-rsp-lpad',
    'X-Admin-Protocol': 'gsma/rsp/v2.2.2',
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  Uri _endpoint(String path) {
    // Some SM-DP+ addresses already include a scheme; most are bare hosts.
    final base = address.contains('://') ? address : 'https://$address';
    return Uri.parse('${base.replaceAll(RegExp(r'/+$'), '')}$path');
  }

  /// POSTs [body] and returns the decoded JSON object, or throws [SmdpError].
  ///
  /// SGP.22 servers signal application-level failure with a 200 response whose
  /// functionExecutionStatus.statusCodeData carries subject/reason codes, so a
  /// 2xx does NOT mean success. Both layers are checked here.
  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final uri = _endpoint(path);
    http.Response rsp;
    try {
      rsp = await _http.post(
        uri,
        headers: _headers,
        body: jsonEncode(body),
      ).timeout(timeout);
    } on TimeoutException {
      throw SmdpError('$address timed out after ${timeout.inSeconds}s');
    } catch (e) {
      throw SmdpError('Could not reach $address: $e');
    }

    if (rsp.statusCode < 200 || rsp.statusCode >= 300) {
      throw SmdpError(
        'SM-DP+ returned HTTP ${rsp.statusCode}',
        httpStatus: rsp.statusCode,
      );
    }

    if (rsp.body.isEmpty) {
      throw SmdpError('SM-DP+ returned an empty body', httpStatus: rsp.statusCode);
    }

    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(rsp.body);
      if (decoded is! Map<String, dynamic>) {
        throw SmdpError('SM-DP+ returned non-object JSON');
      }
      json = decoded;
    } on FormatException {
      throw SmdpError('SM-DP+ returned malformed JSON');
    }

    _checkStatus(json);
    return json;
  }

  /// Reads header.functionExecutionStatus and throws when the function failed.
  void _checkStatus(Map<String, dynamic> json) {
    final header = json['header'];
    if (header is! Map) {
      throw SmdpError('Response has no "header" object');
    }
    final status = header['functionExecutionStatus'];
    if (status is! Map) {
      throw SmdpError('Response has no functionExecutionStatus');
    }

    final statusData = status['statusCodeData'];
    String? subject;
    String? reason;
    String? message;

    if (statusData is Map) {
      subject = statusData['subjectCode'] as String?;
      reason = statusData['reasonCode'] as String?;
      message = statusData['message'] as String?;
    }

    // "Executed-Success" is the only success value.
    final statusValue = status['status'] as String?;
    final succeeded = statusValue == 'Executed-Success' ||
        // Some SM-DP+ implementations omit `status` on success.
        (statusValue == null && reason == null && subject == null);

    if (!succeeded) {
      throw SmdpError(
        message ?? 'Function execution failed',
        subjectCode: subject,
        reasonCode: reason,
      );
    }
  }

  /// Wraps a base64 field from the response, tolerating whitespace/newlines
  /// that SM-DP+ servers insert into long values.
  static Uint8List _b64Field(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw SmdpError('Response is missing "$key"');
    }
    final cleaned = value.replaceAll(RegExp(r'[\r\n\t ]'), '');
    try {
      return base64Decode(cleaned);
    } on FormatException {
      throw SmdpError('Field "$key" is not valid base64');
    }
  }

  static String _strField(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw SmdpError('Response is missing "$key"');
    }
    return value.replaceAll(RegExp(r'[\r\n\t ]'), '');
  }

  // -- ES9+ ----------------------------------------------------------------

  Future<AuthenticationData> initiateAuthentication({
    required String euiccChallengeB64,
    required String euiccInfo1B64,
  }) async {
    final json = await _post('/gsma/rsp2/es9plus/initiateAuthentication', {
      'smdpAddress': address,
      'euiccChallenge': euiccChallengeB64,
      'euiccInfo1': euiccInfo1B64,
    });

    return AuthenticationData(
      transactionId: _strField(json, 'transactionId'),
      serverSigned1: _b64Field(json, 'serverSigned1'),
      serverSignature1: _b64Field(json, 'serverSignature1'),
      euiccCiPkIdToBeUsed: _b64Field(json, 'euiccCiPKIdToBeUsed'),
      serverCertificate: _b64Field(json, 'serverCertificate'),
    );
  }

  Future<ClientAuthenticationData> authenticateClient({
    required String transactionId,
    required String authenticateServerResponseB64,
  }) async {
    final json = await _post('/gsma/rsp2/es9plus/authenticateClient', {
      'transactionId': transactionId,
      'authenticateServerResponse': authenticateServerResponseB64,
    });

    return ClientAuthenticationData(
      profileMetadata: _b64Field(json, 'profileMetadata'),
      smdpSigned2: _b64Field(json, 'smdpSigned2'),
      smdpSignature2: _b64Field(json, 'smdpSignature2'),
      smdpCertificate: _b64Field(json, 'smdpCertificate'),
    );
  }

  Future<Uint8List> getBoundProfilePackage({
    required String transactionId,
    required String prepareDownloadResponseB64,
  }) async {
    final json = await _post('/gsma/rsp2/es9plus/getBoundProfilePackage', {
      'transactionId': transactionId,
      'prepareDownloadResponse': prepareDownloadResponseB64,
    });
    return _b64Field(json, 'boundProfilePackage');
  }

  Future<void> cancelSession({
    required String transactionId,
    required String cancelSessionResponseB64,
  }) async {
    await _post('/gsma/rsp2/es9plus/cancelSession', {
      'transactionId': transactionId,
      'cancelSessionResponse': cancelSessionResponseB64,
    });
  }

  Future<void> handleNotification(String pendingNotificationB64) async {
    await _post('/gsma/rsp2/es9plus/handleNotification', {
      'pendingNotification': pendingNotificationB64,
    });
  }

  void close() => _http.close();
}
