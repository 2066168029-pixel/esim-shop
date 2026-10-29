/// Protocol identification for an unknown Bluetooth reader.
///
/// Readers share the NUS service and differ only in what they understand as a
/// "first frame". Rather than guessing (and retrying by trial), this sends one
/// read-only request per known dialect and reports which one answered:
///
/// | dialect        | first frame                                              |
/// |----------------|----------------------------------------------------------|
/// | linksfield     | `00 02 08 00 12 02 08 01` (protobuf getDeviceInfo)       |
/// | nineEsim       | `{"type":"apdu","payload":{"func":"connect"}}` (lpac JSON) |
/// | rawApdu        | `00 A4 04 00 10 A0…00` (SELECT ISD-R)                    |
///
/// Nothing here writes a card: every probe is a read, and the raw APDU only
/// selects an applet. The scan is slow by design — each dialect gets its own
/// connect/notify/MTU bring-up and its own full timeout — because a reader that
/// answers on the third dialect is still a reader we can use.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'euicc_transport.dart';
import 'hexdump.dart';
import 'transport_9esim_ble.dart';
import 'transport_linksfield.dart';
import 'transport_raw_apdu.dart';

/// One dialect that was tried.
class ProtocolProbeResult {
  final String dialect;
  final bool answered;

  /// What the reader sent back, truncated for display.
  final String evidence;

  /// How long the attempt took, which tells the user whether it timed out or
  /// failed fast.
  final Duration elapsed;

  const ProtocolProbeResult({
    required this.dialect,
    required this.answered,
    required this.evidence,
    required this.elapsed,
  });

  String get icon => answered ? '✓' : '✗';

  String get line =>
      '$icon $dialect（${elapsed.inMilliseconds}ms）'
      '${evidence.isEmpty ? "" : "：$evidence"}';
}

/// Full outcome of a protocol scan.
class ProtocolScanReport {
  final List<ProtocolProbeResult> attempts = [];

  /// Transport that answered, already open and ready for APDUs.
  EuiccTransport? transport;

  /// Dialect of [transport], or null when nothing answered.
  String? dialect;

  bool get identified => transport != null;

  /// A paragraph the UI can show when nothing answered.
  String get diagnosis {
    if (identified) return '识别为 $dialect 协议';
    final heardAnything = attempts.any((a) => a.evidence.isNotEmpty);
    if (!heardAnything) {
      return '三种协议都没有任何回应。链路是通的（服务已发现），'
          '但卡一个字节都不回——最常见是配对没完成（系统弹框里的 PIN），'
          '其次是这块固件需要特定的首帧序列，我们还没有。';
    }
    // Framing may well be correct while the platform handshake still fails:
    // that is a different problem with a different fix, so say so instead of
    // claiming the format is unknown.
    if (!lastLinksfieldRawBytes.isEmpty &&
        lastLinksfieldAnalysis.any((l) => l.startsWith('✓ 2 字节长度头'))) {
      return '帧格式已经识别正确（2 字节大端长度头），但安全通道没有建立。'
          '卡要求先握手，握手失败原因见下方「握手」一行。';
    }
    return '卡有回应，但都不是可用的帧格式。把下面的原始字节发给我，'
        '就能直接对出协议。';
  }

  @override
  String toString() =>
      attempts.map((a) => a.line).join('\n');
}

/// Tries every known dialect against [device].
///
/// [dialects] is ordered by likelihood; pass a subset to skip the slow path.
Future<ProtocolScanReport> scanProtocols(
  BluetoothDevice device, {
  List<String> dialects = const ['linksfield', 'nineEsim', 'rawApdu'],
  Duration perDialectTimeout = const Duration(seconds: 8),
  void Function(String line)? onProgress,

  /// Card password for the secure-channel handshake. Required for the
  /// Linksfield dialect — there is no built-in fallback any more, because
  /// guessing it on a provisioned card looks exactly like a protocol failure.
  String? psk,
}) async {
  final report = ProtocolScanReport();

  for (final dialect in dialects) {
    final sw = Stopwatch()..start();
    onProgress?.call('正在试 $dialect …');

    _ProbeOutcome outcome;
    try {
      switch (dialect) {
        case 'linksfield':
          outcome = await _probeLinksfield(device, perDialectTimeout, psk);
        case 'nineEsim':
          outcome = await _probeNineEsim(device, perDialectTimeout);
        case 'rawApdu':
          outcome = await _probeRawApdu(device, perDialectTimeout);
        default:
          outcome = _ProbeOutcome(ProtocolProbeResult(
            dialect: dialect,
            answered: false,
            evidence: '未知协议名',
            elapsed: sw.elapsed,
          ));
      }
    } catch (e) {
      outcome = _ProbeOutcome(ProtocolProbeResult(
        dialect: dialect,
        answered: false,
        evidence: '$e',
        elapsed: sw.elapsed,
      ));
    }

    sw.stop();
    report.attempts.add(outcome.result);
    onProgress?.call(outcome.result.line);

    if (outcome.result.answered) {
      report.transport = outcome.transport;
      report.dialect = dialect;
      return report;
    }

    // A failed dialect can leave the firmware in a state where the next
    // connect is refused; let the controller settle between attempts.
    await _settle(device);
  }

  return report;
}

Future<void> _settle(BluetoothDevice device) async {
  try {
    await device.disconnect();
  } catch (_) {}
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    bool connected;
    try {
      connected = device.isConnected;
    } catch (_) {
      connected = false;
    }
    if (!connected) break;
    await Future.delayed(const Duration(milliseconds: 120));
  }
  await Future.delayed(const Duration(milliseconds: 500));
}

// ---------------------------------------------------------------------------

/// A probe attempt: what it reported, and the live transport when it worked.
class _ProbeOutcome {
  final ProtocolProbeResult result;
  final EuiccTransport? transport;
  const _ProbeOutcome(this.result, [this.transport]);
}

/// Raw bytes captured by the most recent Linksfield attempt, even when it
/// failed. The UI prints these: when frame parsing is wrong they are the only
/// evidence that identifies the dialect.
List<int> lastLinksfieldRawBytes = const [];
List<String> lastLinksfieldAnalysis = const [];
int? lastReplyLatencyMs;
bool lastCardSpokeFirst = false;

/// Why the secure-channel handshake stopped, when it ran and failed.
String? lastHandshakeError;

/// Byte-for-byte handshake transcript from the last attempt.
List<String> lastHandshakeTranscript = const [];

void _rememberLinksfieldEvidence(LinksfieldTransport? t) {
  if (t == null) return;
  lastLinksfieldRawBytes = t.report.allRawBytes;
  lastLinksfieldAnalysis = t.report.rawAnalysis;
  lastReplyLatencyMs = t.report.firstReplyLatencyMs;
  lastCardSpokeFirst = t.report.cardSpokeFirst;
  lastHandshakeError = t.report.deviceInfoError;
  lastHandshakeTranscript = List.unmodifiable(t.report.handshakeTranscript);
}

Future<_ProbeOutcome> _probeLinksfield(
  BluetoothDevice device,
  Duration timeout,
  String? psk,
) async {
  final sw = Stopwatch()..start();
  // No password, no attempt: the handshake cannot succeed and the only outcome
  // is a misleading "protocol unrecognised".
  if (psk == null || psk.trim().isEmpty) {
    return _ProbeOutcome(ProtocolProbeResult(
      dialect: 'linksfield',
      answered: false,
      evidence: '未提供卡密码，跳过 Linksfield 握手',
      elapsed: sw.elapsed,
    ));
  }
  LinksfieldTransport? t;
  try {
    t = await LinksfieldTransport.connect(
      device,
      replyTimeout: timeout,
      psk: psk,
    );
    await t.open();
    final info = await t.probeDeviceInfo(allowSecureRetry: true);

    final frames = t.report.lastFrames;
    final evidence = info != null
        ? '设备信息 ${info.vendor} ${info.deviceName}'.trim()
        : frames.isEmpty
            ? ''
            : frames.last;

    if (info != null || frames.isNotEmpty) {
      // Hand the open transport to the caller; do not close it on success.
      return _ProbeOutcome(
        ProtocolProbeResult(
          dialect: 'linksfield',
          answered: true,
          evidence: evidence,
          elapsed: sw.elapsed,
        ),
        t,
      );
    }
    _rememberLinksfieldEvidence(t);
    await t.close();
    return _ProbeOutcome(ProtocolProbeResult(
      dialect: 'linksfield',
      answered: false,
      evidence: lastLinksfieldRawBytes.isEmpty
          ? ''
          : '收到 ${lastLinksfieldRawBytes.length}B',
      elapsed: sw.elapsed,
    ));
  } catch (e) {
    _rememberLinksfieldEvidence(t);
    final evidence = lastLinksfieldRawBytes.isNotEmpty
        ? '收到 ${lastLinksfieldRawBytes.length}B，所有解析假设均失败'
        : '$e';
    try {
      await t?.close();
    } catch (_) {}
    return _ProbeOutcome(ProtocolProbeResult(
      dialect: 'linksfield',
      answered: false,
      evidence: evidence,
      elapsed: sw.elapsed,
    ));
  }
}


Future<_ProbeOutcome> _probeNineEsim(
  BluetoothDevice device,
  Duration timeout,
) async {
  final sw = Stopwatch()..start();
  Esim9BleTransport? t;
  try {
    t = await Esim9BleTransport.connect(device, timeout: timeout);
    final ok = await t.probe();
    if (ok) {
      return _ProbeOutcome(
        ProtocolProbeResult(
          dialect: 'nineEsim',
          answered: true,
          evidence: t.lastRawLine,
          elapsed: sw.elapsed,
        ),
        t,
      );
    }
    final evidence = t.lastRawLine;
    await t.close();
    return _ProbeOutcome(ProtocolProbeResult(
      dialect: 'nineEsim',
      answered: false,
      evidence: evidence,
      elapsed: sw.elapsed,
    ));
  } catch (e) {
    final evidence = t?.lastRawLine ?? '$e';
    try {
      await t?.close();
    } catch (_) {}
    return _ProbeOutcome(ProtocolProbeResult(
      dialect: 'nineEsim',
      answered: false,
      evidence: evidence,
      elapsed: sw.elapsed,
    ));
  }
}

/// Connects, subscribes, and sends a bare SELECT ISD-R APDU.
///
/// This is the last resort: a reader that speaks plain APDU-over-NUS needs no
/// vendor protocol at all, and every eUICC answers SELECT with something other
/// than complete silence.
Future<_ProbeOutcome> _probeRawApdu(
  BluetoothDevice device,
  Duration timeout,
) async {
  final sw = Stopwatch()..start();
  try {
    final t = await RawApduTransport.connect(device, replyTimeout: timeout);
    try {
      final rsp = await t.transmit(Uint8List.fromList([0x00, 0xA4, 0x04, 0x00]));
      // Anything the card answers proves the dialect; an error SW still tells us
      // the reader forwards our bytes and the card rejects the SELECT form.
      return _ProbeOutcome(
        ProtocolProbeResult(
          dialect: 'rawApdu',
          answered: true,
          evidence: 'SW=0x${rsp.sw.toRadixString(16).padLeft(4, "0").toUpperCase()}'
              '${rsp.data.isEmpty ? "" : " data=${hexLine(rsp.data, maxBytes: 24)}"}',
          elapsed: sw.elapsed,
        ),
        t,
      );
    } catch (e) {
      await t.close();
      return _ProbeOutcome(ProtocolProbeResult(
        dialect: 'rawApdu',
        answered: false,
        evidence: '$e',
        elapsed: sw.elapsed,
      ));
    }
  } catch (e) {
    return _ProbeOutcome(ProtocolProbeResult(
      dialect: 'rawApdu',
      answered: false,
      evidence: '$e',
      elapsed: sw.elapsed,
    ));
  }
}
