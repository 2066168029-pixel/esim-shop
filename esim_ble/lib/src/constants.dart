/// SGP.22 constants shared by the session and LPA layers.
library;

import 'dart:typed_data';

/// SGP.22 ISD-R application identifier.
///
/// The card answers to A0000005591010FFFFFFFF8900000100. Selecting it on the
/// basic channel keeps the code identical for cards that require an explicit
/// logical channel, because MANAGE CHANNEL simply returns 1 in that case.
/// ISD-R AID (SGP.22).
///
/// Confirmed against the vendor's own binaries -- `libipad.so` and
/// `liblpaclient.so` both contain the literal string
/// `A0000005591010FFFFFFFF8900000100` -- so this is 16 bytes and matches the
/// SGP.22 spec. A hand-transcribed 17-byte variant from a log line was wrong
/// and the card answered it with `result = 511`.
final Uint8List isdrAid = Uint8List.fromList([
  0xA0, 0x00, 0x00, 0x05, 0x59, 0x10, 0x10, 0xFF,
  0xFF, 0xFF, 0xFF, 0x89, 0x00, 0x00, 0x01, 0x00,
]);

/// Maximum segment size the eUICC accepts in one ES10x command.
const int es10xMss = 120;
