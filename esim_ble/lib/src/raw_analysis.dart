/// Raw-byte analysis for a reader whose framing we do not know yet.
///
/// When `[len][protobuf]` fails, the question stops being "which protocol" and
/// becomes "what are these bytes?" — answered by trying every plausible reading
/// of the same buffer and reporting each verdict. Pure functions: no BLE, so the
/// rules can be tested against captured bytes from a real device.
library;

import 'dart:convert';

import 'transport_linksfield.dart' show LpadGatt;

/// One interpretation of the captured stream.
class RawHypothesis {
  final String name;
  final bool plausible;
  final String detail;

  const RawHypothesis(this.name, this.plausible, this.detail);

  String get line => '${plausible ? "✓" : "✗"} $name：$detail';
}

/// Runs every hypothesis over [bytes].
///
/// Ordered cheapest-first so the output reads like a decision tree: length
/// prefixes, then bare protobuf, then text, then "is this even a message".
List<String> analyseRawBytes(List<int> bytes) {
  if (bytes.isEmpty) return ['（没有收到任何字节）'];
  final out = <String>[];
  final all = hypotheses(bytes);
  for (final h in all) {
    out.add(h.line);
  }

  // Once a length prefix explains the stream, the interesting part is the
  // message *inside* a frame -- that is where the protocol shows itself.
  final framing = all.firstWhere(
    (h) => h.plausible && h.name.contains('长度头'),
    orElse: () => const RawHypothesis('', false, ''),
  );
  if (framing.plausible) {
    final first = _firstFrameBody(bytes, framing.name);
    if (first != null && first.isNotEmpty) {
      final p = _walkProto(first);
      out.add('— 第 1 帧内容（${first.length}B）—');
      out.add(p.ok ? '  protobuf: ${p.detail}' : '  非 protobuf: ${p.detail}');
      out.add('  字段释义: ${_explainDeviceRsp(first)}');
    }
  }
  out.add('原始 ${bytes.length}B：${_hexAll(bytes)}');
  final ascii = _asciiOf(bytes);
  if (ascii.isNotEmpty) out.add('ASCII 可见：$ascii');
  return out;
}

List<RawHypothesis> hypotheses(List<int> b) {
  final result = <RawHypothesis>[];

  // -- length-prefixed readings ------------------------------------------
  result.add(_lengthPrefixed(b, 2, bigEndian: true));
  result.add(_lengthPrefixed(b, 2, bigEndian: false));
  result.add(_lengthPrefixed(b, 4, bigEndian: true));
  result.add(_lengthPrefixed(b, 4, bigEndian: false));

  // -- bare payload readings ---------------------------------------------
  result.add(_bareProtobuf(b));
  result.add(_bareText(b));

  // -- structural observations -------------------------------------------
  final sw = _looksLikeApdu(b);
  if (sw != null) result.add(RawHypothesis('APDU 响应（SW 在末尾）', true, sw));

  return result;
}

/// Frames one stream under a length-prefix hypothesis.
///
/// The first version compared the declared length against the whole buffer and
/// called "declares 24, 24 bytes left over" a failure. That is exactly what two
/// correct frames back-to-back look like. Frames are a *stream*: cut one, then
/// continue from the next header, and only report failure when a frame cannot
/// be completed.
RawHypothesis _lengthPrefixed(List<int> b, int size,
    {required bool bigEndian}) {
  final label = '$size 字节长度头（${bigEndian ? "BE" : "LE"}）';
  if (b.length < size) {
    return RawHypothesis(label, false, '数据不足 $size 字节');
  }

  final frames = <List<int>>[];
  var i = 0;
  while (i + size <= b.length) {
    var len = 0;
    if (bigEndian) {
      for (var k = 0; k < size; k++) {
        len = (len << 8) | b[i + k];
      }
    } else {
      for (var k = size - 1; k >= 0; k--) {
        len = (len << 8) | b[i + k];
      }
    }
    if (len <= 0 || len > 0xFFFFF) {
      if (frames.isEmpty) {
        return RawHypothesis(label, false, '首帧长度 $len 无效');
      }
      break;
    }
    final bodyStart = i + size;
    if (bodyStart + len > b.length) {
      if (frames.isEmpty) {
        return RawHypothesis(
            label, false, '首帧声明 $len，只剩 ${b.length - bodyStart} 字节');
      }
      // A truncated tail after complete frames is normal during a partial read.
      final parts = frames.map(_describeFrame).join(' | ');
      return RawHypothesis(
          label, true, '${frames.length} 帧完整（$parts），尾部还差 '
          '${bodyStart + len - b.length} 字节');
    }
    frames.add(b.sublist(bodyStart, bodyStart + len));
    i = bodyStart + len;
  }

  if (frames.isEmpty) return RawHypothesis(label, false, '没有完整帧');
  final leftover = b.length - i;
  final detail = '${frames.length} 帧（${frames.map(_describeFrame).join(" | ")}）'
      '${leftover > 0 ? "，尾部 $leftover 字节不完整" : ""}';
  return RawHypothesis(label, true, detail);
}

/// One-line description of a frame body: protobuf fields when it parses.
String _describeFrame(List<int> body) {
  final p = _walkProto(body);
  return p.ok ? '${body.length}B protobuf[${p.detail}]' : '${body.length}B 非 protobuf';
}

RawHypothesis _bareProtobuf(List<int> b) {
  final t = _walkProto(b);
  if (t.ok) {
    return RawHypothesis('裸 protobuf', true, t.detail);
  }
  return RawHypothesis('裸 protobuf', false, t.detail);
}

/// Walks the buffer as protobuf fields; returns where it stopped and why.
({bool ok, String detail}) _walkProto(List<int> b) {
  var i = 0;
  final fields = <String>[];
  while (i < b.length) {
    final tag = b[i];
    i++;
    final field = tag >> 3;
    final wire = tag & 7;
    if (field == 0) return (ok: false, detail: '偏移 ${i - 1} 处 tag=0，不是 protobuf');
    switch (wire) {
      case 0:
        var v = 0;
        var shift = 0;
        while (i < b.length) {
          final x = b[i];
          i++;
          v |= (x & 0x7F) << shift;
          if ((x & 0x80) == 0) break;
          shift += 7;
          if (shift > 63) return (ok: false, detail: '字段 $field varint 过长');
        }
        fields.add('$field=varint($v)');
      case 2:
        if (i >= b.length) return (ok: false, detail: '字段 $field 缺长度');
        var len = 0;
        var shift = 0;
        while (i < b.length) {
          final x = b[i];
          i++;
          len |= (x & 0x7F) << shift;
          if ((x & 0x80) == 0) break;
          shift += 7;
          if (shift > 28) return (ok: false, detail: '字段 $field 长度过长');
        }
        if (i + len > b.length) {
          return (
            ok: false,
            detail: '字段 $field 声明 $len 字节，只剩 ${b.length - i}'
          );
        }
        final body = b.sublist(i, i + len);
        fields.add('$field=bytes($len)${_peek(body)}');
        i += len;
      case 5:
        if (i + 4 > b.length) return (ok: false, detail: '字段 $field 缺 4 字节');
        i += 4;
        fields.add('$field=fixed32');
      case 1:
        if (i + 8 > b.length) return (ok: false, detail: '字段 $field 缺 8 字节');
        i += 8;
        fields.add('$field=fixed64');
      default:
        return (ok: false, detail: '偏移 ${i - 1} 处 wire type=$wire 非法');
    }
  }
  return (ok: true, detail: fields.join(', '));
}

String _peek(List<int> body) {
  if (body.isEmpty) return '';
  final txt = _printableRun(body);
  if (txt.length >= 3) return ' {"$txt"}';
  return '';
}

RawHypothesis _bareText(List<int> b) {
  final s = utf8.decode(b, allowMalformed: true).trim();
  final printable = s.runes.where((r) => r >= 0x20 && r != 0x7F).length;
  if (s.isEmpty) return const RawHypothesis('裸文本', false, '空');
  final ratio = printable / s.runes.length;
  if (ratio > 0.9 && s.length >= 3) {
    return RawHypothesis('裸文本', true, '“${s.length > 60 ? "${s.substring(0, 60)}…" : s}”');
  }
  return RawHypothesis('裸文本', false, '不可打印占 ${((1 - ratio) * 100).round()}%');
}

String? _looksLikeApdu(List<int> b) {
  if (b.length < 2) return null;
  final sw = (b[b.length - 2] << 8) | b[b.length - 1];
  final sw1 = (sw >> 8) & 0xFF;
  const okSw1 = {0x90, 0x61, 0x62, 0x63, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F};
  if (!okSw1.contains(sw1)) return null;
  return 'SW=0x${sw.toRadixString(16).padLeft(4, '0').toUpperCase()}'
      '（前面 ${b.length - 2}B 数据）';
}

String _printableRun(List<int> b) {
  final sb = StringBuffer();
  for (final c in b) {
    if (c >= 0x20 && c < 0x7F) {
      sb.writeCharCode(c);
    } else {
      break;
    }
  }
  return sb.toString();
}

String _asciiOf(List<int> b) {
  final sb = StringBuffer();
  var run = 0;
  for (final c in b) {
    if (c >= 0x20 && c < 0x7F) {
      sb.writeCharCode(c);
      run++;
    } else {
      if (run >= 3) sb.write(' ');
      run = 0;
    }
  }
  final s = sb.toString().trim();
  return s.length > 100 ? '${s.substring(0, 100)}…' : s;
}

String _hexAll(List<int> b) {
  final shown = b.length > 96 ? b.sublist(0, 96) : b;
  final s = shown
      .map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
  return b.length > 96 ? '$s …(+${b.length - 96}B)' : s;
}

/// GATT tree summary, for the case where the service layout itself is the
/// surprise (a reader that is not NUS at all).
String describeServices(List<({String uuid, List<String> chars})> services) {
  if (services.isEmpty) return '（没有发现任何服务）';
  final b = StringBuffer();
  for (final s in services) {
    final isNus = s.uuid.toLowerCase() == LpadGatt.service ||
        s.uuid.toLowerCase() == LpadGatt.service32;
    b.writeln('${isNus ? "★" : " ·"} ${s.uuid}');
    for (final c in s.chars) {
      b.writeln('     $c');
    }
  }
  return b.toString();
}

/// Body of the first complete frame under the winning length-prefix rule.
List<int>? _firstFrameBody(List<int> b, String hypothesisName) {
  final size = hypothesisName.contains('4 字节') ? 4 : 2;
  final bigEndian = hypothesisName.contains('BE');
  if (b.length < size) return null;
  var len = 0;
  if (bigEndian) {
    for (var k = 0; k < size; k++) {
      len = (len << 8) | b[k];
    }
  } else {
    for (var k = size - 1; k >= 0; k--) {
      len = (len << 8) | b[k];
    }
  }
  if (len <= 0 || size + len > b.length) return null;
  return b.sublist(size, size + len);
}

/// Maps the known Linksfield response fields onto their meaning.
///
/// Field numbers come from the vendor APK's protobuf descriptors:
///   EuiccDeviceRsp { cmd=1, request=2 }
///   DeviceRsp      { cmd=1, result=2, info=3, extend=4, security=5 }
///   SecurityProtocol { type=1, auth{random=1, auth=2}, config{nonce=1, aad=2, auth=3} }
String _explainDeviceRsp(List<int> body) {
  final fields = <String>[];
  var i = 0;
  while (i < body.length) {
    final tag = body[i];
    i++;
    final field = tag >> 3;
    final wire = tag & 7;
    if (wire == 0) {
      var v = 0, shift = 0;
      while (i < body.length) {
        final x = body[i];
        i++;
        v |= (x & 0x7F) << shift;
        if ((x & 0x80) == 0) break;
        shift += 7;
      }
      fields.add(field == 1 ? 'cmd=$v' : field == 2 ? 'result=$v' : 'f$field=$v');
    } else if (wire == 2) {
      var len = 0, shift = 0;
      while (i < body.length) {
        final x = body[i];
        i++;
        len |= (x & 0x7F) << shift;
        if ((x & 0x80) == 0) break;
        shift += 7;
      }
      if (i + len > body.length) break;
      final sub = body.sublist(i, i + len);
      i += len;
      if (field == 3) {
        fields.add('info(${sub.length}B)');
      } else if (field == 5) {
        fields.add('security(${sub.length}B)=${_explainSecurity(sub)}');
      } else {
        fields.add('f$field(${len}B)');
      }
    } else if (wire == 5) {
      i += 4;
    } else if (wire == 1) {
      i += 8;
    } else {
      break;
    }
  }
  return fields.isEmpty ? '（无法识别）' : fields.join(', ');
}

String _explainSecurity(List<int> body) {
  var type = -1;
  final parts = <String>[];
  var i = 0;
  while (i < body.length) {
    final tag = body[i];
    i++;
    final field = tag >> 3;
    final wire = tag & 7;
    if (wire == 0) {
      var v = 0, shift = 0;
      while (i < body.length) {
        final x = body[i];
        i++;
        v |= (x & 0x7F) << shift;
        if ((x & 0x80) == 0) break;
        shift += 7;
      }
      if (field == 1) type = v;
    } else if (wire == 2) {
      var len = 0, shift = 0;
      while (i < body.length) {
        final x = body[i];
        i++;
        len |= (x & 0x7F) << shift;
        if ((x & 0x80) == 0) break;
        shift += 7;
      }
      if (i + len > body.length) break;
      final sub = body.sublist(i, i + len);
      i += len;
      if (field == 2) parts.add('auth(${_explainAuth(sub)})');
      if (field == 3) parts.add('config(${len}B)');
    } else if (wire == 5) {
      i += 4;
    } else if (wire == 1) {
      i += 8;
    } else {
      break;
    }
  }
  final t = type >= 0 ? 'type=$type' : 'type=?';
  return [t, ...parts].join(' ');
}

String _explainAuth(List<int> body) {
  final parts = <String>[];
  var i = 0;
  while (i < body.length) {
    final tag = body[i];
    i++;
    final field = tag >> 3;
    final wire = tag & 7;
    if (wire == 2) {
      var len = 0, shift = 0;
      while (i < body.length) {
        final x = body[i];
        i++;
        len |= (x & 0x7F) << shift;
        if ((x & 0x80) == 0) break;
        shift += 7;
      }
      if (i + len > body.length) break;
      i += len;
      parts.add(field == 1 ? 'random(${len}B)' : 'auth(${len}B)');
    } else if (wire == 0) {
      var v = 0, shift = 0;
      while (i < body.length) {
        final x = body[i];
        i++;
        v |= (x & 0x7F) << shift;
        if ((x & 0x80) == 0) break;
        shift += 7;
      }
      parts.add('f$field=$v');
    } else if (wire == 5) {
      i += 4;
    } else if (wire == 1) {
      i += 8;
    } else {
      break;
    }
  }
  return parts.join(', ');
}
