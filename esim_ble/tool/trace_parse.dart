import 'dart:typed_data';

import 'package:esim_ble/src/linksfield_frame.dart' as lf;
import 'package:esim_ble/src/linksfield_secure.dart' as sec;

/// Replays the exact body the captured card sends and checks every hop the
/// handshake takes through it. Run with `dart run tool/trace_parse.dart`.
void main() {
  final bodies = <String, List<int>>{
    'frame1 (08 01 2A 14 …)': [
      0x08, 0x01, 0x2A, 0x14, 0x12, 0x12, 0x0A, 0x10, //
      0xF9, 0x65, 0xD2, 0x7C, 0xD8, 0x90, 0xB0, 0x9E,
      0x3B, 0x4C, 0x16, 0xBD, 0x12, 0x66, 0xD4, 0x99,
    ],
    'frame2 (1A 14 …)': [
      0x1A, 0x14, 0x12, 0x12, 0x0A, 0x10, //
      0x8D, 0x34, 0xFC, 0xCF, 0x1C, 0x75, 0xCE, 0x2B,
      0x6F, 0xAF, 0x2A, 0xB3, 0x76, 0x0C, 0x8D, 0x4B,
    ],
  };

  for (final entry in bodies.entries) {
    final b = Uint8List.fromList(entry.value);
    print('--- ${entry.key} ---');
    final r = lf.PbReader(b);
    while (true) {
      final t = r.nextTag();
      if (t == null) break;
      print('  tag field=${t.$1} wire=${t.$2}');
      if (t.$2 != 2) {
        r.skip(t.$2);
        continue;
      }
      final body = r.readBytes();
      print('  body ${body.length}B');
      final direct = sec.debugParseAuthBody(body);
      print('  _parseAuthBody(body): random=${direct.random.length}B '
          'auth=${direct.auth.length}B');
      if (body.length >= 2) {
        final deep = sec.debugParseAuthBody(Uint8List.sublistView(body, 2));
        print('  _parseAuthBody(body[2:]): random=${deep.random.length}B '
            'auth=${deep.auth.length}B');
      }
    }
    print('  SecurityProtocolMsg.parse: ${sec.SecurityProtocolMsg.parse(b)}');
  }
}
