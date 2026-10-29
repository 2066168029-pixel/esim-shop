import 'dart:convert';

import 'package:esim_ble/src/lpa_mp/mp_client.dart';
import 'package:esim_ble/src/lpa_mp/mp_signer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Exercises the client's wire behaviour with a stub transport: what goes out
/// (method, path, headers, body) and how failures surface.
void main() {
  const creds = MpCredentials(accessKey: 'user-key', secretKey: 'my-secret-key');

  Map<String, dynamic> ok(Object? data) =>
      {'code': 200, 'msg': 'Success', 'data': data, 'requestId': null};

  MpClient clientWith(
    Future<http.Response> Function(http.Request) handler, {
    MpCredentials credentials = creds,
  }) =>
      MpClient(
        credentials: credentials,
        client: MockClient((req) => handler(req)),
      );

  group('request signing', () {
    test('GET carries the four X-HMAC headers and a valid signature', () async {
      late http.Request seen;
      final c = clientWith((req) async {
        seen = req;
        return http.Response(jsonEncode(ok(const [])), 200);
      });

      await c.queryOrderStatus(orderCode: 'ORDER_1');

      expect(seen.method, 'GET');
      expect(seen.url.path, '/mp-api/api/esim/queryOrderStatus');
      expect(seen.url.queryParameters['orderCode'], 'ORDER_1');
      expect(seen.headers['X-HMAC-ALGORITHM'], 'hmac-sha256');
      expect(seen.headers['X-HMAC-ACCESS-KEY'], 'user-key');
      expect(seen.headers['X-HMAC-SIGNED-HEADERS'],
          'Accept-Language;Content-Type');
      expect(seen.headers['Accept-Language'], 'en-US');

      // Recompute what the server would: same path/query, no Date.
      final expectSig = MpSigner.sign(
        credentials: creds,
        method: 'GET',
        path: '/mp-api/api/esim/queryOrderStatus',
        query: {'orderCode': 'ORDER_1'},
      ).value;
      expect(seen.headers['X-HMAC-SIGNATURE'], expectSig);
    });

    test('POST sends a JSON body and signs only the path', () async {
      late http.Request seen;
      final c = clientWith((req) async {
        seen = req;
        return http.Response(
            jsonEncode(ok({'iccid': '8985', 'qrCode': r'LPA:1$x$y', 'orderCode': 'O'})),
            200);
      });

      await c.activationCode(productId: 5, orderQuantity: 1);

      expect(seen.method, 'POST');
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['productId'], 5);
      expect(body['orderQuantity'], 1);
      final expectSig = MpSigner.sign(
        credentials: creds,
        method: 'POST',
        path: '/mp-api/api/esim/v2/activationCode',
      ).value;
      expect(seen.headers['X-HMAC-SIGNATURE'], expectSig);
    });
  });

  group('responses', () {
    test('parses activationCode into iccid / qrCode / orderCode', () async {
      final c = clientWith((_) async => http.Response(
            jsonEncode(ok({
              'iccid': '8943108169999589689',
              'qrCode': 'LPA:1\$rsp-0001.linksfield.net\$FJW99-WC5AS',
              'orderCode': 'ORDER_1726522312360550400',
            })),
            200,
          ));
      final a = await c.activationCode(productId: 5);
      expect(a.iccid, '8943108169999589689');
      expect(a.qrCode, startsWith('LPA:1\$'));
      expect(a.orderCode, 'ORDER_1726522312360550400');
    });

    test('maps order status codes to labels', () async {
      final c = clientWith((_) async => http.Response(
            jsonEncode(ok([
              {'packageCode': 'LP1', 'status': '1', 'eid': '8999'},
            ])),
            200,
          ));
      final s = await c.queryOrderStatus(orderCode: 'O');
      expect(s.single.status, '1');
      expect(s.single.statusLabel, '使用中');
      expect(s.single.eid, '8999');
    });

    test('tolerates null data rows', () async {
      final c = clientWith((_) async => http.Response(
            jsonEncode(ok([
              {
                'packageCode': null,
                'status': null,
                'actualStartTime': null,
                'plannedEndTime': null,
                'eid': null
              }
            ])),
            200,
          ));
      final s = await c.queryOrderStatus(orderCode: 'O');
      expect(s.single.packageCode, isNull);
      expect(s.single.statusLabel, '未知');
    });

    test('product stock parses and exposes allowed cycles', () async {
      final c = clientWith((_) async => http.Response(
            jsonEncode(ok([
              {
                'goodsId': 37,
                'productId': 6,
                'goodsName': 'CHINA_Test',
                'productName': 'test',
                'coverCountry': '460',
                'coverCountryName': 'China',
                'validity': '1',
                'validityUnit': 'Monthly',
                'flow': '1',
                'flowUnit': 'GB',
                'stock': 5,
                'orderQuantity': '3,4',
              }
            ])),
            200,
          ));
      final p = await c.purchaseItem();
      expect(p.single.stock, 5);
      expect(p.single.allowedQuantities, [3, 4]);
      expect(p.single.label, 'test');
    });
  });

  group('errors', () {
    test('business failure in a 200 response throws with its code', () async {
      final c = clientWith((_) async => http.Response(
            jsonEncode({'code': 500, 'msg': 'No ICCID found', 'data': null}),
            200,
          ));
      expect(
        () => c.activationCode(productId: 5, orderQuantity: 99),
        throwsA(isA<MpError>()
            .having((e) => e.code, 'code', 500)
            .having((e) => e.message, 'message', contains('No ICCID'))),
      );
    });

    test('401 is reported as a signature problem', () async {
      final c = clientWith((_) async => http.Response('denied', 401));
      expect(
        () => c.queryOrderStatus(orderCode: 'O'),
        throwsA(isA<MpError>()
            .having((e) => e.httpStatus, 'httpStatus', 401)
            .having((e) => e.message, 'message', contains('签名'))),
      );
    });

    test('missing credentials fail before any network call', () async {
      var called = false;
      final c = clientWith(
        (_) async {
          called = true;
          return http.Response('{}', 200);
        },
        credentials: const MpCredentials(accessKey: '', secretKey: ''),
      );
      await expectLater(
        c.queryOrderStatus(orderCode: 'O'),
        throwsA(isA<MpError>()),
      );
      expect(called, isFalse);
    });
  });
}
