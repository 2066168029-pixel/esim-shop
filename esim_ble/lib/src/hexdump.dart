/// Hex-dump helpers used when a protocol error needs to be diagnosed from a
/// screenshot of the phone. Keeping the dump short and wrapped matters: the
/// text has to be readable on a 390pt screen.
library;

import 'dart:typed_data';

/// Formats up to [maxBytes] of [data] as spaced hex, wrapped every [perLine]
/// bytes. Trailing bytes are elided with a "+N more" suffix.
String hexDump(
  Uint8List data, {
  int maxBytes = 96,
  int perLine = 16,
}) {
  final shown = data.length > maxBytes ? data.sublist(0, maxBytes) : data;
  final buf = StringBuffer();
  for (var i = 0; i < shown.length; i++) {
    if (i > 0) buf.write(i % perLine == 0 ? '\n' : ' ');
    buf.write(shown[i].toRadixString(16).padLeft(2, '0').toUpperCase());
  }
  if (data.length > maxBytes) {
    buf.write('\n… +${data.length - maxBytes} bytes');
  }
  return buf.toString();
}

/// Compact one-line hex, for log lines rather than UI.
String hexLine(List<int> data, {int maxBytes = 4096}) {
  final shown = data.length > maxBytes ? data.sublist(0, maxBytes) : data;
  final out = shown
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join();
  return data.length > maxBytes ? '$out…(+${data.length - maxBytes})' : out;
}
