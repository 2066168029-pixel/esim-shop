/// Known-plaintext capture driver.
///
/// Purpose: get ONE pair of (plaintext, ciphertext) through the secure channel.
/// Everything about the session key so far has been guessed; with a known
/// plaintext the same question becomes "recover the keystream", which is
/// solvable, and it also settles whether the key is static at all.
///
/// Why these two commands:
///
///   * `openLogicalChannel(AID = A000000559104C696E6B736669656C64)`
///     - the AID is ASCII "…Linksfield" (`A00000055910` + `Linksfield`), found
///       verbatim in `libapp.so` at offset 577799. Every byte going out is
///       known: `08 02 12 16 0A 14 <20-byte AID ASCII> 10 00`.
///     - the response carries a channel number, so only the first couple of
///       plaintext bytes are unknown.
///
///   * `iccReset`
///     - the command frame is empty on the wire, so the ciphertext for an empty
///       plaintext is the pure CCM tag over the nonce/AAD — the cleanest
///       possible oracle.
///
/// Run one command per session and reset the card in between, otherwise the
/// seq counters drift and the frames no longer line up.
library;

import 'dart:typed_data';

/// ASCII "Linksfield" — the vendor's own prefix, not a guess.
const String linksfieldAid = 'A000000559104C696E6B736669656C64';

class KnownPlaintextCase {
  final String name;
  final String why;
  final String expectedRequestHex;
  final String? note;

  const KnownPlaintextCase({
    required this.name,
    required this.why,
    required this.expectedRequestHex,
    this.note,
  });

  @override
  String toString() => '$name\n  $why\n  期望请求: $expectedRequestHex'
      '${note == null ? '' : '\n  注意: $note'}';
}

/// The two cases, with the exact bytes we expect to see going out.
final List<KnownPlaintextCase> knownPlaintextCases = [
  KnownPlaintextCase(
    name: 'openLogicalChannel(Linksfield AID)',
    why: '请求体完全可预测：AID 是 ASCII "Linksfield"，存在 libapp.so@577799',
    // 08 03 12 28 | 08 02 | 12 22 | 0A 20 <32 ASCII chars> | 10 00
    //
    // Careful: the AID goes out as a 32-character ASCII hex string, so the
    // field length is 0x20 (32), not 0x14 (16). Getting this wrong once made
    // the "expected" frame two bytes short and would have sent a padded AID.
    //
    // The outer length is 0x28 (40) — the *real* payload length, with no `+1`
    // padding. Emitting 0x29 here made the field card's own output look wrong
    // and fired a false "明文假设无效" warning on a capture whose AID bytes
    // were in fact identical.
    expectedRequestHex:
        '08031228'
        '0802'
        '1222'
        '0a20'
        '4130303030303035353931303443363936453642373336363639363536433634'
        '1000',
    note: '响应里的通道号未知，所以只有请求方向是纯已知明文',
  ),
  KnownPlaintextCase(
    name: 'iccReset',
    why: '命令帧 payload 为空，密文只剩 tag —— 最干净的 oracle',
    expectedRequestHex: '080312021a00',
    note: '厂商日志 18:27:56.955 原文就是这么发的',
  ),
];

/// Builds the `SmartCardReq` body for the Linksfield AID, without the
/// `EuiccDeviceReq` wrapper, so tests can assert the exact bytes.
Uint8List linksfieldOpenChannelBody() {
  final aid = linksfieldAid;
  final out = <int>[
    0x08, 0x02, // cmd = openLogicalChannel
    0x12, aid.length + 2, // openChannel { aid(2+32), p2(2) } = 36
    0x0A, aid.length, // aid: a 32-character ASCII hex string, so len = aid.length
  ];
  for (var i = 0; i < aid.length; i += 2) {
    // The AID travels as an ASCII hex string, not as packed bytes.
    out.add(aid.codeUnitAt(i));
    out.add(aid.codeUnitAt(i + 1));
  }
  out.addAll([0x10, 0x00]); // p2 = 0
  return Uint8List.fromList(out);
}

/// Human-readable summary for the diagnostics panel.
String describeKnownPlaintextPlan() {
  final b = StringBuffer()
    ..writeln('已知明文抓取计划（目的：把「猜密码」换成「恢复 keystream」）')
    ..writeln();
  for (final c in knownPlaintextCases) {
    b.writeln(c);
    b.writeln();
  }
  b.writeln('做法：每个命令单独开一次会话，中间复位卡，避免 seq 计数器漂移。');
  b.writeln('拿到双向帧后交给 work/ 下的脚本，直接算 keystream 并验证 key 是否静态。');
  return b.toString();
}
