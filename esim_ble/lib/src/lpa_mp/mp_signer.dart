/// Linksfield MP (Market Place) API signing.
///
/// Documented at mp-docs.linksfield.net → "Generating the signature":
///
///   signature = Base64(HMAC-SHA256(secret_key, signing_string))
///
///   signing_string = METHOD \n
///                    URI \n
///                    canonical_query_string \n
///                    access_key \n
///                    Date \n
///                    header1:value1 \n
///                    header2:value2 \n
///
/// Details that the docs call out and that this file encodes:
///
///  * The URI starts with `/` and never includes the scheme or host.
///  * The canonical query string is the raw query **sorted** the way the gateway
///    canonicalises it; the doc example keeps the order it appears in the URL,
///    so this sorts keys and leaves values encoded as given.
///  * Signed headers are listed in `X-HMAC-SIGNED-HEADERS` separated by `;`,
///    and each contributes `Name:value` (no space after the colon).
///  * Missing terms become empty strings — including `Date`, which the gateway
///    currently does not enforce, so passing it as empty is supported and is
///    what the second documented test vector does.
///  * **The string ends with a trailing newline.** Omitting it produces a
///    signature that looks plausible and is always rejected.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/api.dart';

/// Credentials issued by Linksfield when the reseller account is created.
class MpCredentials {
  final String accessKey;
  final String secretKey;

  const MpCredentials({required this.accessKey, required this.secretKey});

  bool get isConfigured => accessKey.isNotEmpty && secretKey.isNotEmpty;

  @override
  String toString() =>
      'MpCredentials(accessKey=${accessKey.isEmpty ? "(empty)" : "${accessKey.substring(0, accessKey.length > 4 ? 4 : accessKey.length)}…"}, '
      'secret=***)';
}

/// One request's signature material.
class MpSignature {
  final String value;
  final String algorithm;
  final String signedHeaders;
  final String signingString;

  const MpSignature({
    required this.value,
    required this.algorithm,
    required this.signedHeaders,
    required this.signingString,
  });

  @override
  String toString() => 'MpSignature($value)';
}

class MpSigner {
  /// hmac-sha256 is what every documented endpoint uses.
  static const String algorithm = 'hmac-sha256';

  /// Headers the gateway always includes for API-gateway endpoints.
  static const List<String> defaultSignedHeaders = [
    'Accept-Language',
    'Content-Type',
  ];

  static const String _acceptLanguage = 'en-US';
  static const String _contentType = 'application/json';

  /// Builds the exact string that gets HMAC'd.
  ///
  /// Exposed so tests (and anyone debugging a 401) can print it: a signature
  /// mismatch is almost always a whitespace or ordering difference here, not a
  /// wrong key.
  static String signingString({
    required String method,
    required String path,
    Map<String, String> query = const {},
    required String accessKey,
    String date = '',
    Map<String, String>? signedHeaders,
    List<String> headerOrder = defaultSignedHeaders,
  }) {
    final canonicalQuery = canonicalQueryString(query);
    final headers = signedHeaders ?? _defaultHeaderValues();

    final b = StringBuffer()
      ..write(method.toUpperCase())
      ..write('\n')
      ..write(path.isEmpty ? '/' : path)
      ..write('\n')
      ..write(canonicalQuery)
      ..write('\n')
      ..write(accessKey)
      ..write('\n')
      ..write(date)
      ..write('\n');

    for (final name in headerOrder) {
      final value = headers[name] ?? '';
      b
        ..write('$name:$value')
        ..write('\n');
    }
    return b.toString();
  }

  static Map<String, String> _defaultHeaderValues() => const {
        'Accept-Language': _acceptLanguage,
        'Content-Type': _contentType,
      };

  /// `a=1&b=2` with keys sorted; values keep whatever encoding the caller gave.
  ///
  /// Percent-encoding is the caller's job because the canonical form must match
  /// the bytes actually sent on the wire: re-encoding here would double-encode
  /// anything already escaped.
  static String canonicalQueryString(Map<String, String> query) {
    if (query.isEmpty) return '';
    final keys = query.keys.toList()..sort();
    return keys.map((k) => '$k=${query[k] ?? ''}').join('&');
  }

  /// Computes the signature for one request.
  ///
  /// [date] defaults to empty, which the gateway accepts (documented: the time
  /// offset check is disabled). Pass an RFC-1123 GMT string to have it signed.
  static MpSignature sign({
    required MpCredentials credentials,
    required String method,
    required String path,
    Map<String, String> query = const {},
    String date = '',
    Map<String, String> extraSignedHeaders = const {},
  }) {
    final headerOrder = [...defaultSignedHeaders, ...extraSignedHeaders.keys];
    final headerValues = Map<String, String>.from(_defaultHeaderValues())
      ..addAll(extraSignedHeaders);

    final s = signingString(
      method: method,
      path: path,
      query: query,
      accessKey: credentials.accessKey,
      date: date,
      signedHeaders: headerValues,
      headerOrder: headerOrder,
    );

    final mac = HMac(SHA256Digest(), 64)
      ..init(KeyParameter(utf8.encode(credentials.secretKey)));
    final digest = mac.process(Uint8List.fromList(utf8.encode(s)));

    return MpSignature(
      value: base64.encode(digest),
      algorithm: algorithm,
      signedHeaders: headerOrder.join(';'),
      signingString: s,
    );
  }

  /// Headers a signed request must carry, on top of the business ones.
  static Map<String, String> authHeaders(
    MpCredentials credentials,
    MpSignature sig, {
    String date = '',
  }) =>
      {
        'X-HMAC-SIGNATURE': sig.value,
        'X-HMAC-ALGORITHM': sig.algorithm,
        'X-HMAC-ACCESS-KEY': credentials.accessKey,
        'X-HMAC-SIGNED-HEADERS': sig.signedHeaders,
        'Accept-Language': _acceptLanguage,
        'Content-Type': _contentType,
        if (date.isNotEmpty) 'Date': date,
      };
}
