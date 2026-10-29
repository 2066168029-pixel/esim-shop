import 'package:esim_app/lpad_errors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DetailedCode.parse', () {
    test('splits operation and error code', () {
      // op=3 (EUICC_CARD), error=10004 (insufficient memory)
      final code = (3 << 24) | 10004;
      final d = DetailedCode.parse(code);
      expect(d.operation, OperationCode.euiccCard);
      expect(d.errorCode, 10004);
      expect(d.subjectCode, isNull);
    });

    test('decodes SMDX subject/reason instead of an error code', () {
      // 0xA8B1051 -> subject 8.11.1, reason 5.1 (the vendor's own example)
      final d = DetailedCode.parse(0xA8B1051);
      expect(d.operation, OperationCode.smdxSubjectReason);
      expect(d.subjectCode, '8.11.1');
      expect(d.reasonCode, '5.1');
    });

    test('strips leading zero groups', () {
      // Nibbles are read back-to-front: 0x000003 is subject 0.0.0 / reason 0.0.3,
      // which collapse to "0" and "3".
      final d = DetailedCode.parse((10 << 24) | 0x000003);
      expect(d.subjectCode, '0');
      expect(d.reasonCode, '3');
    });

    test('keeps multi-section codes intact', () {
      // subject 8.1.1 / reason 3.8.0 -> nibbles 8,1,1,3,8,0
      final d = DetailedCode.parse((10 << 24) | 0x811380);
      expect(d.subjectCode, '8.1.1');
      expect(d.reasonCode, '3.8.0');
    });

    test('operation 10 does not fall through to the error-code branch', () {
      final d = DetailedCode.parse((10 << 24) | 0x000012);
      expect(d.errorCode, 0);
      expect(d.subjectCode, isNotNull);
    });

    test('unknown operation is null rather than throwing', () {
      final d = DetailedCode.parse((99 << 24) | 5);
      expect(d.operation, isNull);
      expect(d.errorCode, 5);
    });
  });

  group('DetailedErrorMessages', () {
    ErrorMessages forCode(int c, {String? carrier, String? tel}) =>
        DetailedErrorMessages(carrierName: carrier, csTel: tel).forCode(c);

    test('insufficient memory on the card', () {
      final m = forCode((7 << 24) | 10004, carrier: 'Orange');
      expect(m.title, '无法激活 Orange');
      expect(m.bodyText, contains('空间不足'));
      expect(m.errorDetails, contains('删除'));
    });

    test('already-downloaded profile via SMDX 8.2 / 1.2', () {
      // subject 8.2.0 -> "8.2"; reason 1.2.0 -> "1.2"
      final packed = (10 << 24) | 0x082012;
      final m = forCode(packed, carrier: 'Orange');
      expect(m.title, '套餐已下载');
      expect(m.bodyText, contains('Orange'));
    });

    test('invalid activation code points at the QR, not the network', () {
      final m = forCode((6 << 24) | 10001);
      expect(m.title, '二维码无效');
      expect(m.bodyText, contains('二维码'));
    });

    test('carrier locked explains how to unlock', () {
      final m = forCode((5 << 24) | 10000, carrier: 'Vodafone', tel: '123');
      expect(m.title, '无法激活 Vodafone');
      expect(m.errorDetails, contains('Vodafone'));
      expect(m.errorDetails, contains('123'));
    });

    test('HTTP 100-999 becomes a network message', () {
      final m = forCode((11 << 24) | 404);
      expect(m.title, '未连接网络');
    });

    test('HTTP with a real error code is NOT treated as a network error', () {
      // error 10015 is outside 100..999, so it must reach the general branch.
      final m = forCode((11 << 24) | 10015);
      expect(m.title, isNot('未连接网络'));
    });

    test('unknown combination still names both codes for support', () {
      final m = forCode((1 << 24) | 99999);
      expect(m.title, '激活失败');
      expect(m.errorDetails, contains('Operation Code: 1'));
      expect(m.errorDetails, contains('Error Code: 99999'));
    });

    test('missing carrier name still produces usable text', () {
      final m = forCode((5 << 24) | 10000);
      expect(m.title, '无法激活服务');
      expect(m.bodyText, isNotEmpty);
      expect(m.errorDetails, contains('运营商'));
    });
  });
}
