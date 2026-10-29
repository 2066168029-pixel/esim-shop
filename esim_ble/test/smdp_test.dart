import 'dart:convert';

import 'package:esim_ble/src/smdp_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  Map<String, dynamic> successBody(Map<String, dynamic> extra) => {
        'header': {
          'functionExecutionStatus': {'status': 'Executed-Success'},
        },
        ...extra,
      };

  group('SmdpClient ES9+ wire format', () {
    test('initiateAuthentication posts the required fields and headers',
        () async {
      late http.Request captured;
      final client = SmdpClient(
        'rsp-0001.linksfield.net',
        client: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode(successBody({
              'transactionId': 'TX-1',
              'serverSigned1': base64Encode([1, 2, 3]),
              'serverSignature1': base64Encode([4, 5]),
              'euiccCiPKIdToBeUsed': base64Encode([6]),
              'serverCertificate': base64Encode([7, 8]),
            })),
            200,
          );
        }),
      );

      final result = await client.initiateAuthentication(
        euiccChallengeB64: 'Q0hBTEdF',
        euiccInfo1B64: 'SU5GTzE=',
      );

      expect(captured.url.toString(),
          'https://rsp-0001.linksfield.net/gsma/rsp2/es9plus/initiateAuthentication');
      expect(captured.headers['User-Agent'], 'gsma-rsp-lpad');
      expect(captured.headers['X-Admin-Protocol'], 'gsma/rsp/v2.2.2');
      expect(captured.headers['Content-Type'], startsWith('application/json'));

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['smdpAddress'], 'rsp-0001.linksfield.net');
      expect(body['euiccChallenge'], 'Q0hBTEdF');
      expect(body['euiccInfo1'], 'SU5GTzE=');

      expect(result.transactionId, 'TX-1');
      expect(result.serverSigned1, [1, 2, 3]);
      expect(result.serverCertificate, [7, 8]);
      client.close();
    });

    test('authenticateClient posts transactionId + response', () async {
      late http.Request captured;
      final client = SmdpClient(
        'smdp.test',
        client: MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode(successBody({
              'profileMetadata': base64Encode([9]),
              'smdpSigned2': base64Encode([10]),
              'smdpSignature2': base64Encode([11]),
              'smdpCertificate': base64Encode([12]),
            })),
            200,
          );
        }),
      );

      final result = await client.authenticateClient(
        transactionId: 'TX-9',
        authenticateServerResponseB64: 'UlNQ',
      );

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['transactionId'], 'TX-9');
      expect(body['authenticateServerResponse'], 'UlNQ');
      expect(result.smdpSigned2, [10]);
      client.close();
    });

    test('getBoundProfilePackage returns decoded bytes', () async {
      final client = SmdpClient(
        'smdp.test',
        client: MockClient((req) async => http.Response(
              jsonEncode(successBody({
                'boundProfilePackage': base64Encode([0xBF, 0x36, 0x00]),
              })),
              200,
            )),
      );
      final bpp = await client.getBoundProfilePackage(
        transactionId: 'TX-1',
        prepareDownloadResponseB64: 'UFJFUEFSRQ==',
      );
      expect(bpp, [0xBF, 0x36, 0x00]);
      client.close();
    });

    test('a 200 response with a failure status still throws', () async {
      final client = SmdpClient(
        'smdp.test',
        client: MockClient((req) async => http.Response(
              jsonEncode({
                'header': {
                  'functionExecutionStatus': {
                    'status': 'Failed',
                    'statusCodeData': {
                      'subjectCode': '8.1.1',
                      'reasonCode': '3.8',
                      'message': 'Matching ID does not exist',
                    },
                  },
                },
              }),
              200,
            )),
      );

      expect(
        () => client.initiateAuthentication(
            euiccChallengeB64: 'A', euiccInfo1B64: 'B'),
        throwsA(isA<SmdpError>()
            .having((e) => e.subjectCode, 'subjectCode', '8.1.1')
            .having((e) => e.reasonCode, 'reasonCode', '3.8')
            .having((e) => e.message, 'message', 'Matching ID does not exist')),
      );
      client.close();
    });

    test('HTTP 500 is surfaced with the status code', () async {
      final client = SmdpClient(
        'smdp.test',
        client: MockClient((req) async => http.Response('boom', 500)),
      );
      expect(
        () => client.initiateAuthentication(
            euiccChallengeB64: 'A', euiccInfo1B64: 'B'),
        throwsA(isA<SmdpError>()
            .having((e) => e.httpStatus, 'httpStatus', 500)),
      );
      client.close();
    });

    test('base64 with embedded whitespace is tolerated', () async {
      final client = SmdpClient(
        'smdp.test',
        client: MockClient((req) async => http.Response(
              jsonEncode(successBody({
                'transactionId': 'TX\n1',
                'serverSigned1': 'AQ\nID',
                'serverSignature1': 'BAU=',
                'euiccCiPKIdToBeUsed': 'Bg==',
                'serverCertificate': 'Bwg=',
              })),
              200,
            )),
      );
      final r = await client.initiateAuthentication(
          euiccChallengeB64: 'A', euiccInfo1B64: 'B');
      expect(r.transactionId, 'TX1');
      expect(r.serverSigned1, [1, 2, 3]);
      client.close();
    });
  });
}
