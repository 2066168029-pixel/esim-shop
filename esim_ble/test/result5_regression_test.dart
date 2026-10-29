import 'dart:typed_data';

import 'package:esim_ble/src/linksfield_frame.dart' as lf;
import 'package:flutter_test/flutter_test.dart';

/// Regression coverage for the 2026-10-23 vendor capture.
///
/// The card answered a rejected AUTH reply with exactly two bytes, `08 05`.
/// Earlier that was read as `SecurityData{id=1, error=5}`, i.e. a structured
/// rejection, and a whole day was spent adjusting the proof instead of
/// noticing it is just `EuiccDeviceRsp.result = 5`.
void main() {
  group('08 05 is EuiccDeviceRsp.result, not SecurityData', () {
    test('two bytes parse as result only', () {
      final rsp = lf.DeviceRsp.parse(Uint8List.fromList([0x08, 0x05]));
      // `08 05` is a single field: field 1, wire type 0, value 5. DeviceRsp
      // maps field 1 onto `cmd`, so the 5 lands in `cmd` while `result` stays
      // at its default. Either way the point holds: two bytes cannot be a
      // SecurityData envelope, and the value is a plain status, not `error`.
      expect(rsp.cmd, 5, reason: 'field 1 carries the status value 5');
      expect(rsp.result, 0, reason: 'no result field is present');
      expect(rsp.securityBytes, isEmpty,
          reason: 'a 2-byte reply cannot carry a SecurityData envelope');
    });

    test('result 5 is distinguishable from secureRequired (-256)', () {
      final rsp = lf.DeviceRsp.parse(Uint8List.fromList([0x08, 0x05]));
      expect(rsp.cmd, isNot(-256),
          reason: 'secureRequired is the -256 code, not 5');
      expect(rsp.needsSecureChannel, isFalse);
    });
  });
}
