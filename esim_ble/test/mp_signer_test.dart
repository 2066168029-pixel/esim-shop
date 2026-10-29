import 'dart:convert';

import 'package:esim_ble/src/lpa_mp/mp_signer.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two vectors published in "Generating the signature" — if these fail,
/// every live call fails, so they are the first thing to run.
void main() {
  const credentials =
      MpCredentials(accessKey: 'user-key', secretKey: 'my-secret-key');

  group('documented vectors', () {
    test('Date participates in the signature', () {
      final sig = MpSigner.sign(
        credentials: credentials,
        method: 'GET',
        path: '/mp-api/api/esim/queryOrderStatus',
        query: const {
          'eid': '89049032000001000000128255728753',
          'resellerCode': 'SG00000010',
        },
        date: 'Tue, 19 Jan 2021 11:33:20 GMT',
      );
      expect(sig.value, 'P0IuBBMV6fsf4UhdMsF3St9gaxqcidO7YwJ2eAzTRCM=');
      expect(sig.signedHeaders, 'Accept-Language;Content-Type');
    });

    test('empty Date still signs (gateway accepts it)', () {
      final sig = MpSigner.sign(
        credentials: credentials,
        method: 'GET',
        path: '/mp-api/api/esim/queryOrderStatus',
        query: const {
          'eid': '89049032000001000000128255728753',
          'resellerCode': 'SG00000010',
        },
      );
      expect(sig.value, 'M8w5ai017BnWLoUFjbR2zaqapxj1gXK+Unll6twlDmg=');
    });

    test('signing string has the documented shape and trailing newline', () {
      final sig = MpSigner.sign(
        credentials: credentials,
        method: 'GET',
        path: '/mp-api/api/esim/queryOrderStatus',
        query: const {
          'eid': '89049032000001000000128255728753',
          'resellerCode': 'SG00000010',
        },
      );
      expect(
        sig.signingString,
        'GET\n'
        '/mp-api/api/esim/queryOrderStatus\n'
        'eid=89049032000001000000128255728753&resellerCode=SG00000010\n'
        'user-key\n'
        '\n'
        'Accept-Language:en-US\n'
        'Content-Type:application/json\n',
      );
      // The trailing newline is the classic omission; assert it explicitly.
      expect(sig.signingString.endsWith('\n'), isTrue);
      // 5 separators + trailing newline → 8 segments once split.
      expect(sig.signingString.split('\n').length, 8);
    });
  });

  group('canonical query string', () {
    test('sorts keys and keeps the values as given', () {
      expect(
        MpSigner.canonicalQueryString(
            const {'z': '1', 'a': '2', 'm': 'x%20y'}),
        'a=2&m=x%20y&z=1',
      );
    });

    test('is empty when there is no query', () {
      expect(MpSigner.canonicalQueryString(const {}), '');
    });

    test('a different key order does not change the signature', () {
      const a = {'eid': '89049032000001000000128255728753', 'resellerCode': 'SG00000010'};
      const b = {'resellerCode': 'SG00000010', 'eid': '89049032000001000000128255728753'};
      final s1 = MpSigner.sign(
          credentials: credentials,
          method: 'GET',
          path: '/mp-api/api/esim/queryOrderStatus',
          query: a);
      final s2 = MpSigner.sign(
          credentials: credentials,
          method: 'GET',
          path: '/mp-api/api/esim/queryOrderStatus',
          query: b);
      expect(s1.value, s2.value);
    });
  });

  group('signing string composition', () {
    test('missing terms become empty strings', () {
      final s = MpSigner.signingString(
        method: 'post',
        path: '/x',
        accessKey: 'k',
        signedHeaders: const {},
        headerOrder: const [],
      );
      expect(s, 'POST\n/x\n\nk\n\n');
    });

    test('extra signed headers are appended in order', () {
      final s = MpSigner.signingString(
        method: 'GET',
        path: '/x',
        accessKey: 'k',
        signedHeaders: const {
          'Accept-Language': 'en-US',
          'Content-Type': 'application/json',
          'X-Request-Id': 'abc',
        },
        headerOrder: const [
          'Accept-Language',
          'Content-Type',
          'X-Request-Id',
        ],
      );
      expect(s.endsWith('X-Request-Id:abc\n'), isTrue);
    });

    test('empty path becomes /', () {
      final s = MpSigner.signingString(
        method: 'GET',
        path: '',
        accessKey: 'k',
        signedHeaders: const {},
        headerOrder: const [],
      );
      expect(s.startsWith('GET\n/\n'), isTrue);
    });
  });

  group('auth headers', () {
    test('carry the four X-HMAC fields and omit Date when unsigned', () {
      final sig = MpSigner.sign(
        credentials: credentials,
        method: 'GET',
        path: '/x',
      );
      final h = MpSigner.authHeaders(credentials, sig);
      expect(h['X-HMAC-ALGORITHM'], 'hmac-sha256');
      expect(h['X-HMAC-ACCESS-KEY'], 'user-key');
      expect(h['X-HMAC-SIGNED-HEADERS'], 'Accept-Language;Content-Type');
      expect(h.containsKey('Date'), isFalse);
      expect(base64.decode(h['X-HMAC-SIGNATURE']!).length, 32);
    });
  });
}
