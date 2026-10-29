/// Capture the simplest requests whose plaintext is already known.
///
/// Why this exists: the LPAD secure channel has been attacked from ciphertext
/// only, so every key candidate so far was a guess. This driver sends two
/// commands whose plaintext bytes are fully determined ahead of time, and
/// records both directions byte-for-byte. One such pair converts the problem
/// from "guess the password" into "recover the keystream".
///
/// The two requests, and why each one qualifies:
///
///   1. `openLogicalChannel(A000000559104C696E6B736669656C64)`
///      The AID is the vendor's own constant (`A00000055910` + ASCII
///      "Linksfield"), found in `libapp.so` at offset 577799. The request body
///      going out is therefore known before a single byte is sent.
///
///   2. `iccReset`
///      The command carries no payload, so its ciphertext is the bare CCM tag
///      over the nonce and AAD — the cleanest possible oracle.
///
/// Both are read-only with respect to the SIM: opening a logical channel and
/// resetting the interface do not write a profile. Nothing here downloads,
/// enables, disables or deletes anything.
library;

import 'dart:typed_data';

import 'known_plaintext.dart';
import 'linksfield_frame.dart' as lf;
import 'transport_linksfield.dart';

/// One captured exchange.
class KnownPlaintextCapture {
  final String step;
  final String note;
  final String? requestHex;
  final String? responseHex;

  const KnownPlaintextCapture({
    required this.step,
    this.note = '',
    this.requestHex,
    this.responseHex,
  });

  bool get isComplete => requestHex != null && responseHex != null;

  @override
  String toString() {
    final b = StringBuffer('[抓取] $step')
      ..write(requestHex == null ? '' : '\n  → $requestHex')
      ..write(responseHex == null ? '' : '\n  ← $responseHex');
    if (note.isNotEmpty) b.write('\n  $note');
    return b.toString();
  }
}

/// How far the bytes we sent are from the bytes we assumed.
///
/// The first version of this check printed "明文假设无效" for any mismatch,
/// which was wrong in the way that matters: a one-byte length-field difference
/// leaves the *plaintext* perfectly usable, while a difference inside the
/// payload field does not. Distinguishing the two is the whole point of
/// capturing known plaintext, so the verdict has to be computed, not assumed.
enum PlaintextVerdict {
  /// Byte-for-byte match.
  exact,

  /// Only the declared length differs; the payload is identical. The
  /// plaintext is still fully known — the length field is not part of it.
  lengthOnly,

  /// The payload itself differs. The plaintext assumption is void.
  mismatch,
}

/// Compares what was sent against what was assumed.
///
/// `openLogicalChannel` is the case that motivated this: the card went out with
/// `08 03 12 28 ...` while the table said `08 03 12 29 ...`, and the AID bytes
/// were bit-identical. Calling that "明文假设无效" would have thrown away a
/// perfectly good capture.
PlaintextVerdict comparePlaintext(String expectedHex, String actualHex) {
  final e = expectedHex.toLowerCase();
  final a = actualHex.toLowerCase();
  if (e == a) return PlaintextVerdict.exact;
  // A single differing byte at offset 3 is the declared length of field 2.
  if (e.length == a.length) {
    var diffs = <int>[];
    for (var i = 0; i < e.length; i += 2) {
      if (e.substring(i, i + 2) != a.substring(i, i + 2)) diffs.add(i ~/ 2);
    }
    if (diffs.length == 1 && diffs.first == 3) {
      return PlaintextVerdict.lengthOnly;
    }
  }
  return PlaintextVerdict.mismatch;
}

/// Result of one capture run.
class KnownPlaintextResult {
  final List<KnownPlaintextCapture> captures = [];
  final List<String> notes = [];

  /// Plain lines to paste into `work/keystream.py`.
  String get pasteBlock {
    final b = StringBuffer();
    for (final c in captures) {
      if (!c.isComplete) continue;
      b.writeln('# ${c.step}');
      b.writeln('  plaintext  : ${c.note}');
      b.writeln('  request    : ${c.requestHex}');
      b.writeln('  response   : ${c.responseHex}');
      b.writeln();
    }
    return b.toString();
  }

  String get fullReport {
    final b = StringBuffer()..writeln('— 已知明文抓取 —');
    if (captures.isEmpty) b.writeln('（没有任何抓取结果）');
    for (final c in captures) {
      b.writeln(c);
      b.writeln();
    }
    if (notes.isNotEmpty) {
      b.writeln('— 说明 —');
      for (final n in notes) {
        b.writeln(n);
      }
    }
    return b.toString();
  }
}

/// Runs both known-plaintext requests and records what came back.
///
/// Each request is sent exactly once. A failure is recorded and the next step
/// still runs, because a half capture (one direction, one command) is still
/// worth more than an aborted run.
Future<KnownPlaintextResult> captureKnownPlaintext(
  LinksfieldTransport transport, {
  void Function(String line)? onProgress,
}) async {
  final result = KnownPlaintextResult();
  void note(String s) {
    result.notes.add(s);
    onProgress?.call(s);
  }

  // ---- step 1: openLogicalChannel with the vendor AID ----------------------
  const aidCase = 0;
  final openBody = linksfieldOpenChannelBody();
  final openFrame = lf.wrapScard(openBody);
  final expected = knownPlaintextCases[aidCase].expectedRequestHex.toLowerCase();
  final actual = openFrame
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  result.captures.add(KnownPlaintextCapture(
    step: 'openLogicalChannel(Linksfield AID)',
    note: '请求体已知：AID = ASCII "Linksfield"（libapp.so@577799）',
    requestHex: actual,
  ));
  transport.addCapture('[抓取] openLogicalChannel → $actual');
  switch (comparePlaintext(expected, actual)) {
    case PlaintextVerdict.exact:
      note('✓ openLogicalChannel 请求字节与预期完全一致，明文可信。');
    case PlaintextVerdict.lengthOnly:
      // The length field is not plaintext. The AID bytes are what carry the
      // known value, and they match — so the capture is usable.
      note('✓ openLogicalChannel 只有长度字段差 1 字节（0x28 vs 0x29），'
          'AID 载荷完全一致，明文仍然可信。');
    case PlaintextVerdict.mismatch:
      note('⚠ openLogicalChannel 的请求载荷和预期不一致。'
          '预期 $expected，实际 $actual。这次的明文假设无效。');
  }

  try {
    final frame = await transport.request(openFrame);
    final hex = lf.hexOf(frame);
    final last = result.captures.last;
    result.captures[result.captures.length - 1] = KnownPlaintextCapture(
      step: last.step,
      note: last.note,
      requestHex: last.requestHex,
      responseHex: hex,
    );
    transport.addCapture('[抓取] openLogicalChannel ← $hex');
  } catch (e) {
    note('openLogicalChannel 没有拿到响应：$e');
  }

  // ---- step 2: iccReset ----------------------------------------------------
  // `encodeIccReset()` already returns the complete frame
  // (`08 03 12 02 1A 00`); wrapping it again produced
  // `08 03 12 06 08 03 12 02 1A 00` — a SCARD envelope inside a SCARD
  // envelope, which the card answered with a challenge instead of a reset.
  final resetFrame = lf.encodeIccReset();
  final resetHex = lf.hexOf(resetFrame);
  result.captures.add(KnownPlaintextCapture(
    step: 'iccReset',
    note: '请求 payload 为空，密文里只剩 tag',
    requestHex: resetHex,
  ));
  transport.addCapture('[抓取] iccReset → $resetHex');
  if (resetHex.toLowerCase() !=
      knownPlaintextCases[1].expectedRequestHex.toLowerCase()) {
    note('⚠ iccReset 帧和厂商日志的 080312021A00 不一致：实际 $resetHex');
  }

  try {
    final frame = await transport.request(resetFrame);
    final hex = lf.hexOf(frame);
    final last = result.captures.last;
    result.captures[result.captures.length - 1] = KnownPlaintextCapture(
      step: last.step,
      note: last.note,
      requestHex: last.requestHex,
      responseHex: hex,
    );
    transport.addCapture('[抓取] iccReset ← $hex');
  } catch (e) {
    note('iccReset 没有拿到响应：$e');
  }

  note('提示：每个命令单独开一次会话、中间复位卡，seq 才不会漂移。');
  note('把上面的 request/response 贴进 work/keystream.py 的 CAPTURES。');
  return result;
}

/// Capture the full secure-channel handshake.
///
/// This is the data that has been missing for two days. Every attempt so far
/// produced either a ciphertext without a known plaintext, or a plaintext
/// without a session — never the moment where the card decides whether to
/// hand over the UPDATE. Without an UPDATE there is no session key, and
/// without a session key nothing else can be analysed.
///
/// `startSecureChannel` already logs each step into
/// [LpadProbeReport.handshakeTranscript]; this wrapper runs it and returns the
/// transcript as a paste-ready block, plus the challenges seen, so the next
/// round can compare them instead of eyeballing hex.
Future<KnownPlaintextResult> captureHandshake(
  LinksfieldTransport transport, {
  void Function(String line)? onProgress,
  String password = '',
}) async {
  final result = KnownPlaintextResult();
  void note(String s) {
    result.notes.add(s);
    onProgress?.call(s);
  }

  transport.report.challengesSeen.clear();
  note('开始跑完整握手（目标：拿到 UPDATE，没有 UPDATE 就没有会话密钥）');

  var ok = false;
  try {
    ok = await transport.startSecureChannel();
  } catch (e) {
    note('握手抛异常：$e');
  }

  note(ok ? '✓ 握手成功，已拿到 UPDATE' : '✗ 握手失败');

  final t = transport.report.handshakeTranscript;
  if (t.isNotEmpty) {
    note('');
    note('— 握手 transcript —');
    for (final line in t) {
      note(line);
    }
  }

  final ch = transport.report.challengesSeen;
  if (ch.isNotEmpty) {
    note('');
    note('— 本次见到的挑战（${ch.length} 个）—');
    for (final c in ch) {
      note(c);
    }
    note('对比历史：09:52 是 2665B91C…，09:57 是 64AA56D6…，每次不同即证实随机。');
  }

  final err = transport.report.deviceInfoError;
  if (err != null && err.isNotEmpty) {
    note('');
    note('失败原因：$err');
  }

  result.captures.add(KnownPlaintextCapture(
    step: 'secure-channel handshake',
    note: ok ? '成功' : '失败',
    requestHex: null,
    responseHex: null,
  ));

  return result;
}

/// Just the raw bytes, for callers that only need the hex.
Uint8List linksfieldOpenRequest() =>
    lf.wrapScard(linksfieldOpenChannelBody());
