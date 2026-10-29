/// Linksfield BLE transport — protocol-correct rebuild.
///
/// Supersedes the first version of this file, which guessed at the protocol.
/// Every step below is backed by `docs/esim-ble-frame-protocol.md`:
///
///   connect → wait for connected → discoverServices → resolve NUS RX/TX →
///   setNotifyValue(TX) → **wait for the CCCD write to land** → requestMtu →
///   **wait for the MTU result** → only then send the first frame
///
/// Frame: `[len_hi][len_lo][protobuf]`, length = payload bytes only, big endian,
/// 2 bytes by default (`bleDataLengthSize`, per-device, 2 or 4).
///
/// The first request is `getDeviceInfo` (`08 00 12 02 08 01`) — a pure read that
/// cannot change card state. Nothing else is sent unless that succeeds.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'euicc_transport.dart';
import 'linksfield_frame.dart' as lf;
import 'raw_analysis.dart';
import 'linksfield_secure.dart' as sec;

/// GATT identifiers used by the Linksfield LPAd firmware.
class LpadGatt {
  static const String service = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const String rx = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
  static const String tx = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
  static const String cccd = '00002902-0000-1000-8000-00805f9b34fb';

  /// 32-bit service form used by some firmware revisions.
  static const String service32 = '1cfde1cc-0000-1000-8000-00805f9b34fb';
}

/// A timestamped line for the diagnostics panel.
class LpadLogLine {
  final DateTime at;
  final String text;
  LpadLogLine(this.at, this.text);
  @override
  String toString() {
    final t = at;
    String two(int v) => v.toString().padLeft(2, '0');
    return '[${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
        '${t.millisecond.toString().padLeft(3, '0')}] $text';
  }
}

/// What the probe found. Kept separate from exceptions so the UI can show a
/// complete picture even when a step fails halfway.
class LpadProbeReport {
  final lines = <LpadLogLine>[];
  bool connected = false;
  bool servicesDiscovered = false;
  bool notifyEnabled = false;
  bool cccdConfirmed = false;
  int mtu = 23;
  bool mtuNegotiated = false;
  String? deviceInfoError;
  String summary = '';

  /// What the user has to do on the phone (pairing / wrong header), if
  /// anything. Null when no action is needed.
  String? pairingPrompt;

  /// Set when the transport recovered by itself (e.g. switched frame length
  /// header); shown once instead of an error.
  String? diagnosisOverride;

  /// Frame length header that actually works with this card (2 or 4).
  int lengthHeaderSize = 2;

  /// Notifications the card pushed without being asked (late replies from an
  /// earlier frame, or unsolicited state changes).
  int unsolicitedFrames = 0;

  /// True when `getDeviceInfo` carried a `security` field.
  ///
  /// Informational only: the vendor app records it and keeps talking plaintext.
  /// This exists so the diagnostics panel can show that the field was there
  /// without any code treating it as a gate.
  bool securityAdvertised = false;

  /// Replies that failed to parse as protobuf. A run of these means the frame
  /// length header or the chunk split is wrong, not that the card is deaf.
  int undecodableFrames = 0;

  /// The last few complete frames the card sent, oldest first.
  final List<String> lastFrames = [];

  /// Every notification payload exactly as it arrived, before any parsing.
  ///
  /// Frame parsing assumes `[len][protobuf]`; when that assumption is wrong the
  /// assembled "frames" are meaningless, so the raw chunks are what actually
  /// identifies the dialect.
  final List<List<int>> rawChunks = [];

  /// Milliseconds from the first byte written to the first byte received.
  ///
  /// A card that answers in 20ms is parsing our frame; one that answers after
  /// 3s was timing out on its own side, which points at a handshake we skipped.
  int? firstReplyLatencyMs;

  /// True when the card spoke before we wrote anything.
  bool cardSpokeFirst = false;

  /// Challenges the card handed us outside a completed handshake.
  ///
  /// Capture 2026-10-24: `openLogicalChannel` answers
  /// `08 02 1A 14 12 12 0A 10 <16B>` — a bare SmartCardRsp whose field 3 is a
  /// challenge, not a channel number, and there is no `08 03` wrapper and no
  /// ciphertext field at all. Recording these matters because a _new_ value
  /// per request proves the challenge is randomised (session nonce), while a
  /// repeat would have meant it was a static device identifier.
  final List<String> challengesSeen = [];

  /// Byte-for-byte record of the secure-channel handshake, one line per step.
  /// A failed handshake is unreadable without it: "no SecurityProtocol" says
  /// nothing about what the card actually answered.
  final List<String> handshakeTranscript = [];

  List<int> get allRawBytes => rawChunks.expand((c) => c).toList();

  /// Multi-hypothesis read of the raw stream, for the diagnostics panel.
  List<String> get rawAnalysis => analyseRawBytes(allRawBytes);

  /// One-paragraph diagnosis for the UI. Null while everything looks fine.
  String? get diagnosis {
    if (diagnosisOverride != null) return diagnosisOverride;
    if (pairingPrompt != null) return pairingPrompt;
    if (connected && servicesDiscovered && !notifyEnabled) {
      return '链路已建立但通知未打开：写出去的命令收不到任何回复。'
          '请断开重连（多数情况是 CCCD 写入失败）。';
    }
    if (undecodableFrames >= 3) {
      return '卡有回数据但解析不了（$undecodableFrames 帧）：'
          '长度头或分片方式与固件不一致，先试“长度头 4 字节”或降低 MTU。';
    }
    return null;
  }
}

/// Linksfield transport over the NUS service.
///
/// Deliberately single-request: [probeDeviceInfo] sends exactly one read-only
/// `getDeviceInfo` frame, then waits for the reply. Failed attempts are not
/// retried automatically (see [LpadProbeReport] for why).
class LinksfieldTransport implements EuiccTransport {
  final BluetoothDevice device;
  final BluetoothCharacteristic rx;
  final BluetoothCharacteristic tx;
  /// Frame length prefix size, 2 or 4 bytes. Not final: [open] may switch it
  /// after re-probing with the other size on a card that never answered.
  int lengthHeaderSize;
  final Duration replyTimeout;
  static const int writeGapMs = 15;

  final report = LpadProbeReport();

  /// Byte-level capture of request/response pairs, for known-plaintext work.
  ///
  /// The secure channel has been reverse-engineered from ciphertext alone so
  /// far, which is why every key candidate has been a guess. One request whose
  /// plaintext is known turns that into "recover the keystream". Kept off
  /// [report] because that object is rebuildable state for the UI, while a
  /// capture must survive intact.
  final List<String> capture = [];

  /// Appends one capture line.
  void addCapture(String line) {
    capture.add(line);
  }
  final _assembler = lf.FrameAssembler();

  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  /// Broadcast hub for assembled frames.
  ///
  /// NOT final: [close] shuts it down, and a transport reopened after a failed
  /// probe (openAnyTransport falls back and reconnects) must get a fresh
  /// controller. Adding to a closed StreamController is a silent no-op, which
  /// presents as "device never answered" with no error anywhere.
  StreamController<Uint8List> _frames = StreamController<Uint8List>.broadcast();

  /// Serialises writes: two frames must never interleave on the wire.
  Future<void> _writeChain = Future.value();

  /// PSK for the secure channel. Defaults to the vendor's fallback.
  final String psk;

  sec.LpadSecureSession? _secure;

  /// True once the handshake completed and frames are encrypted.
  bool get isSecure => _secure != null;

  /// True once the CCCD write has completed (not merely been requested).
  bool _cccdConfirmed = false;
  bool _open = false;

  /// Set when the card still owes us a reply (the last exchange timed out).
  ///
  /// A timed-out request is not necessarily lost: the card may answer seconds
  /// later, and because a notification carries no request id that late frame
  /// would be handed to the *next* request as if it were its answer. Every
  /// reply is therefore logged with a sequence number and anything arriving
  /// after the request it belongs to was given up on is reported as
  /// unsolicited instead of being silently consumed.
  int _requestSeq = 0;
  int _awaitingReplyFor = -1;

  /// When the most recent first chunk hit the wire, for reply-latency math.
  DateTime? _firstWriteAt;

  LinksfieldTransport._(
    this.device,
    this.rx,
    this.tx, {
    this.lengthHeaderSize = 2,
    this.replyTimeout = const Duration(seconds: 12),
    required String psk,
  }) : psk = psk;

  @override
  String get kind => 'linksfield-ble';

  @override
  String get description =>
      device.platformName.isNotEmpty ? device.platformName : device.remoteId.str;

  @override
  bool get isOpen => _open;

  void _log(String text) => report.lines.add(LpadLogLine(DateTime.now(), text));

  // ------------------------------------------------------------- lifecycle

  /// Connects, discovers, subscribes, and negotiates the MTU.
  ///
  /// Order is enforced here, not by the caller:
  /// connect → connected → discover → NUS pair → notify → CCCD → MTU → ready.
  ///
  /// [mtuOverride] pins the MTU when the platform refuses to report it; the
  /// caller is expected to have a reason (a previous successful session).
  static Future<LinksfieldTransport> connect(
    BluetoothDevice device, {
    int lengthHeaderSize = 2,
    Duration replyTimeout = const Duration(seconds: 12),
    int? mtuOverride,
    String? psk,
  }) async {
    final log = <LpadLogLine>[];
    void note(String s) => log.add(LpadLogLine(DateTime.now(), s));

    note('开始连接 ${device.remoteId.str} (${device.platformName})');

    await _connectLink(device, note);
    final services = await _discoverServices(device, note);
    final pair = _findNus(services);
    if (pair == null) {
      note('✗ 未发现 NUS 服务 ${LpadGatt.service}');
      throw TransportError('未发现 NUS 服务，可能不是 Linksfield 设备');
    }
    note('✓ NUS 服务: ${pair.$3}');

    final t = LinksfieldTransport._(
      device,
      pair.$1,
      pair.$2,
      lengthHeaderSize: lengthHeaderSize,
      replyTimeout: replyTimeout,
      psk: psk?.trim() ?? '',
    );
    t.report.lines.addAll(log);
    t.report.connected = true;
    t.report.servicesDiscovered = true;

    // notify -> CCCD -> MTU, each gating the next.
    t._connSub = device.connectionState.listen((s) => t._log('状态变化: ${s.name}'));
    await t._subscribe();
    await t._negotiateMtu(mtuOverride);

    // Settle window after the MTU exchange. This firmware is timing-sensitive:
    // it drops the link when the MTU request arrives too early, and it ignores
    // the first frame written in the same event-loop turn as the MTU
    // confirmation. A short pause here is the difference between "answered"
    // and "sent 1 chunk, 12s timeout".
    await Future.delayed(const Duration(milliseconds: 250));

    t._open = true;
    t._log('✓ 链路就绪 (MTU=${t.report.mtu}, 长度头=${lengthHeaderSize}B)');
    return t;
  }

  /// Opens the link and waits until the platform confirms it.
  ///
  /// Any stale handle from a previous session is dropped first: retrying against
  /// a dead handle is what produces "device is disconnected" on this firmware.
  static Future<void> _connectLink(
    BluetoothDevice device,
    void Function(String) note,
  ) async {
    if (device.isConnected) {
      note('已有连接，先断开以建立干净会话');
      try {
        await device.disconnect();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 400));
    }

    await device.connect(
      timeout: const Duration(seconds: 20),
      // mtu:null — a value here makes the plugin request the MTU immediately,
      // before the CCCD exists, which this firmware answers by dropping the link.
      mtu: null,
      autoConnect: false,
    );

    final ok = await _waitConnected(device, const Duration(seconds: 10));
    note(ok ? '✓ 连接状态: connected' : '✗ 连接状态未确认');
    if (!ok) throw TransportError('连接状态未确认');

    // GATT handshake settle before discovery.
    await Future.delayed(const Duration(milliseconds: 300));
  }

  /// Re-discovers services on the *current* connection.
  static Future<List<BluetoothService>> _discoverServices(
    BluetoothDevice device,
    void Function(String) note,
  ) async {
    note('discoverServices() …');
    try {
      final services = await device.discoverServices();
      note('✓ 发现 ${services.length} 个服务');
      for (final s in services) {
        note('  服务 ${s.uuid.str} (${s.characteristics.length} 特征)');
      }
      return services;
    } catch (e) {
      note('✗ discoverServices 失败: $e');
      throw TransportError('服务发现失败: $e');
    }
  }

  static Future<bool> _waitConnected(BluetoothDevice device, Duration timeout) async {
    if (device.isConnected) return true;
    try {
      await device.connectionState
          .where((s) => s == BluetoothConnectionState.connected)
          .first
          .timeout(timeout);
      return true;
    } catch (_) {
      return device.isConnected;
    }
  }

  /// Locates the NUS write/notify pair.
  ///
  /// The vendor compares the first 24 characters of the service UUID, which also
  /// matches the 32-bit service form; characteristics are matched exactly.
  static (BluetoothCharacteristic, BluetoothCharacteristic, String)? _findNus(
    List<BluetoothService> services,
  ) {
    for (final s in services) {
      final su = s.uuid.str.toLowerCase();
      if (su != LpadGatt.service && su != LpadGatt.service32) continue;
      BluetoothCharacteristic? r;
      BluetoothCharacteristic? t;
      for (final c in s.characteristics) {
        final cu = c.uuid.str.toLowerCase();
        if (cu == LpadGatt.rx) r = c;
        if (cu == LpadGatt.tx) t = c;
      }
      if (r != null && t != null) return (r, t, s.uuid.str);
    }
    return null;
  }

  /// Enables notifications and waits for the CCCD write to actually complete.
  ///
  /// `setNotifyValue(true)` returning is not proof: the plugin resolves once
  /// the request is written, and some stacks report success before the peer has
  /// acknowledged it. A short confirmation window plus `isNotifying` covers it.
  Future<void> _subscribe() async {
    _log('setNotifyValue(TX, true) …');
    try {
      await tx.setNotifyValue(true);
      report.notifyEnabled = tx.isNotifying;
      _log('${report.notifyEnabled ? "✓" : "✗"} TX notify requested '
          '(isNotifying=${tx.isNotifying})');
    } catch (e) {
      _log('✗ setNotifyValue 失败: $e');
      throw TransportError('无法启用 TX 通知: $e');
    }

    _notifySub = tx.onValueReceived.listen(_onNotification, onError: (Object e) {
      _log('✗ 通知流错误: $e');
    });

    // Wait for the CCCD to settle. A device that acknowledges quickly is fine;
    // one that never does still gets the full window.
    _cccdConfirmed = await _waitCccd();
    report.cccdConfirmed = _cccdConfirmed;
    _log(_cccdConfirmed
        ? '✓ CCCD 已确认 (稳定 ${_confirmWindowMs}ms 无异常)'
        : '⚠ CCCD 未得到明确确认，按兼容逻辑继续');
  }

  static const _confirmWindowMs = 300;

  Future<bool> _waitCccd() async {
    // FlutterBluePlus exposes the descriptor state through isNotifying; if it
    // reads true and stays true across a settle window, the write landed.
    for (var i = 0; i < 3; i++) {
      await Future.delayed(const Duration(milliseconds: _confirmWindowMs));
      if (!tx.isNotifying) return false;
      if (!device.isConnected) {
        _log('✗ CCCD 等待期间断连');
        return false;
      }
    }
    return true;
  }

  /// Requests an MTU and waits for the real result.
  ///
  /// Calling `requestMtu` is not evidence that the MTU changed, so this uses the
  /// returned value and validates it, falling back to the current value.
  Future<void> _negotiateMtu(int? override) async {
    if (override != null) {
      report.mtu = override;
      report.mtuNegotiated = true;
      _log('MTU 使用调用方指定的值: $override');
      return;
    }

    _log('requestMtu(517) …');
    try {
      final mtu = await device.requestMtu(517).timeout(
            const Duration(seconds: 5),
            onTimeout: () => -1,
          );
      if (mtu >= 23) {
        report.mtu = mtu;
        report.mtuNegotiated = true;
        _log('✓ MTU = $mtu');
      } else {
        await _mtuFallback('requestMtu 超时');
      }
    } catch (e) {
      await _mtuFallback('requestMtu 异常: $e');
    }
  }

  Future<void> _mtuFallback(String why) async {
    // No MTU result: stay on the BLE default. Every write is then sized from
    // mtu - 3, which is always safe at 23.
    await Future.delayed(const Duration(milliseconds: 120));
    report.mtu = 23;
    report.mtuNegotiated = false;
    _log('⚠ $why → 回退到默认 MTU 23（仍可发送，只是分片更多）');
  }

  // ---------------------------------------------------------- notifications

  void _onNotification(List<int> value) {
    if (value.isEmpty) return;
    // Keep the raw bytes: when frame parsing fails, they are the only evidence
    // left, and asking the user to run the probe again is a whole round trip.
    report.rawChunks.add(List<int>.from(value));
    _log('← 通知 ${value.length}B: ${lf.hexOf(value)}');
    for (final frame in _assembler.push(value)) {
      _log('  完整帧 ${frame.length}B: ${lf.hexOf(frame)}');
      _rememberFrame(frame);
      if (!_frames.isClosed) _frames.add(frame);
    }
  }

  /// Keeps a bounded history of what the card actually said, and flags frames
  /// that arrive while nothing is waiting for them.
  void _rememberFrame(Uint8List frame) {
    report.lastFrames.add(lf.hexOf(frame, max: 48));
    if (report.lastFrames.length > 5) report.lastFrames.removeAt(0);

    if (_awaitingReplyFor < 0) {
      report.unsolicitedFrames++;
      _log('  ⚠ 无人等待的帧（#${report.unsolicitedFrames}）'
          '——可能上一条命令的迟到回复');
    }
    // Cheap structural check: every message starts with a varint tag whose
    // wire type must be one protobuf defines. Garbage means the length header
    // or the chunk boundaries are wrong.
    final wire = frame.isNotEmpty ? frame[0] & 7 : 7;
    if (wire != 0 && wire != 1 && wire != 2 && wire != 5) {
      report.undecodableFrames++;
      _log('  ⚠ 帧头不是合法 protobuf（wire type $wire）');
    }
  }

  // ---------------------------------------------------------------- send

  /// Sends one protobuf payload as a framed message and waits for one reply.
  ///
  /// Serialised: a second call queues behind the first, so two requests can
  /// never interleave chunk-by-chunk on the wire.
  Future<Uint8List> request(Uint8List payload, {Duration? timeout}) {
    final completer = Completer<Uint8List>();
    _writeChain = _writeChain.then((_) async {
      try {
        completer.complete(await _send(payload, timeout ?? replyTimeout));
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<Uint8List> _send(
    Uint8List payload,
    Duration timeout, {
    bool forcePlain = false,
  }) async {
    if (!_open || !device.isConnected) {
      throw TransportError('链路未就绪（未连接或未完成初始化）');
    }
    if (!_cccdConfirmed) {
      _log('⚠ CCCD 未确认，首帧可能收不到回复');
    }

    _assembler.reset();

    // Once the handshake completed, every request travels inside a
    // SecurityData envelope (AES-CCM with the rolling id).
    final session = forcePlain ? null : _secure;
    final wirePayload = session?.wrap(payload) ?? payload;
    if (session != null) {
      _log('  加密后 ${wirePayload.length}B (id=${session.counter})');
    }

    final chunks = lf.framePayload(
      wirePayload,
      mtu: report.mtu,
      lengthHeaderSize: lengthHeaderSize,
    );

    _log('→ payload ${payload.length}B: ${lf.hexOf(payload)}');
    _log('  长度头 ${lengthHeaderSize}B = ${lf.hexOf(chunks.first.sublist(0, lengthHeaderSize))}'
        ' | MTU ${report.mtu} | ${chunks.length} 片');

    // Subscribe BEFORE writing, and cancel it in a finally block.
    //
    // `stream.first.timeout(...)` throws from inside the timeout wrapper, and
    // the subscription it opened is only released later by the microtask
    // queue -- if at all. On a broadcast hub that leaves a live listener
    // competing with the next attempt for the same frame, so every retry
    // after the first timeout fails the same way. A manually managed
    // subscription cannot leak.
    final completer = Completer<Uint8List>();
    final seq = ++_requestSeq;
    late final StreamSubscription<Uint8List> replySub;
    final timer = Timer.periodic(timeout, (_) {
      if (!completer.isCompleted) {
        completer.completeError(TransportError(_timeoutMessage(seq, chunks.length, timeout)));
      }
    });

    replySub = _frames.stream.listen(
      (frame) {
        if (!completer.isCompleted) {
          _awaitingReplyFor = -1;
          report.firstReplyLatencyMs ??= DateTime.now()
              .difference(_firstWriteAt ?? DateTime.now())
              .inMilliseconds;
          completer.complete(frame);
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) {
          _awaitingReplyFor = -1;
          completer.completeError(TransportError('通知流出错: $e'));
        }
      },
    );

    final Uint8List frame;
    try {
      _awaitingReplyFor = seq;

      // First request only: give the card a quiet window before we speak.
      //
      // Two different devices look identical when neither answers:
      //   * one expects to be spoken to first  -> silence here is normal
      //   * one wants to say hello itself      -> silence here means we have
      //                                           been trampling its greeting
      // Watching for 2s costs nothing on a healthy reader and settles which.
      if (seq == 1) {
        final quiet = Stopwatch()..start();
        while (quiet.elapsedMilliseconds < 2000 && report.rawChunks.isEmpty) {
          await Future.delayed(const Duration(milliseconds: 50));
        }
        if (report.rawChunks.isNotEmpty) {
          report.cardSpokeFirst = true;
          _log('⚠ 卡在我们发首帧前就说话了（${report.allRawBytes.length}B）');
        } else {
          _log('  静听 2000ms：卡没有说话');
        }
      }

      for (var i = 0; i < chunks.length; i++) {
        if (!device.isConnected) {
          throw TransportError('发送第 ${i + 1}/${chunks.length} 片时链路断开');
        }
        _log('  写第 ${i + 1}/${chunks.length} 片 ${chunks[i].length}B: '
            '${lf.hexOf(chunks[i])}');
        if (i == 0) _firstWriteAt = DateTime.now();
        await rx.write(chunks[i], withoutResponse: false);
        if (i + 1 < chunks.length && writeGapMs > 0) {
          await Future.delayed(Duration(milliseconds: writeGapMs));
        }
      }
      frame = await completer.future;
    } finally {
      timer.cancel();
      await replySub.cancel();
      // Leave the flag set when the request failed: a late reply to *this*
      // frame would otherwise be consumed by the next one.
      if (!completer.isCompleted) _awaitingReplyFor = seq;
      else _awaitingReplyFor = -1;
    }

    _log('← 响应 ${frame.length}B: ${lf.hexOf(frame)}');

    if (session != null) {
      final plain = session.unwrap(frame);
      if (plain == null) {
        _log('✗ 解密失败：响应不是合法的 SecurityData 或 MAC 不匹配');
        throw TransportError('安全通道解密失败');
      }
      _log('  解密后 ${plain.length}B: ${lf.hexOf(plain)}');
      return plain;
    }
    return frame;
  }

  /// Runs the vendor's three-message secure-channel handshake.
  ///
  ///   1. → SecurityProtocol{type: AUTH}                      (start)
  ///      ← SecurityProtocol{type: AUTH, auth{random}}        (challenge)
  ///   2. → SecurityProtocol{type: AUTH, auth{pcNonce, proof}}
  ///      ← SecurityProtocol{type: UPDATE, config{nonce, aad, auth}}
  ///
  /// The session key is bytes 16..31 of the proof; the device proves the same
  /// derivation in `config.auth`. Returns true on success.
  Future<bool> startSecureChannel({List<int>? knownChallenge}) async {
    if (_secure != null) return true;

    final pskKey = sec.derivePskKey(psk);
    _log('— 安全通道握手 —');
    _log('PSK 派生完成 (HMAC-SHA256, 32B)');
    if (knownChallenge != null && knownChallenge.isNotEmpty) {
      _log('使用首帧里已经拿到的挑战：${lf.hexOf(knownChallenge)}');
    }

    // The card sent the challenge together with its getDeviceInfo answer, so
    // asking for one again may simply be ignored. Try the carried-over
    // challenge first when we have it, then fall back to the documented
    // request. Both attempts are logged byte for byte.
    final attempts = <String>[
      if (knownChallenge != null && knownChallenge.isNotEmpty) 'carried',
      'request',
    ];

    for (final mode in attempts) {
      report.handshakeTranscript.add('── 尝试：$mode ──');
      final challenge = mode == 'carried'
          ? Uint8List.fromList(knownChallenge!)
          : await _requestChallenge();
      if (challenge == null) {
        // Silence here is what turned into "设备未返回 SecurityProtocol" last
        // time, which sent us looking at the card instead of the parser. Say
        // plainly that we never got a challenge to send.
        _log('✗ $mode 路径：没有拿到挑战，跳过 AUTH 回复');
        report.handshakeTranscript
            .add('✗ $mode：没有拿到挑战（未发出 AUTH 回复）');
        continue;
      }

      final ok = await _sendAuthReply(pskKey, challenge);
      if (ok) {
        _log('✓ 握手成功（$mode 路径）');
        report.handshakeTranscript.add('✓ 成功（$mode）');
        return true;
      }
      _log('✗ $mode 路径失败');
      report.handshakeTranscript.add('✗ 失败（$mode）');
    }

    report.deviceInfoError ??= '握手失败：两条路径都没有得到 UPDATE';

    // Record what actually stopped us, not just that we stopped. Without this
    // the transcript shows two arrows and a verdict, and the interesting part
    // -- which challenge we used, what came back, why it was rejected -- lives
    // only in `lines`, which the diagnostics panel does not render.
    report.handshakeTranscript.add('');
    report.handshakeTranscript.add('— 诊断 —');
    final ch = knownChallenge ?? const <int>[];
    report.handshakeTranscript.add(
        '首帧挑战: ${ch.isEmpty ? "(空——说明卡的首帧响应没解析出挑战)" : lf.hexOf(ch)}');
    report.handshakeTranscript.add('PSK: ${psk.isEmpty ? "(空, 未提供密码)" : "用户输入(${psk.length} 字符)"}');
    final last = report.lastFrames.isEmpty ? "" : report.lastFrames.last;
    if (last.isNotEmpty) {
      report.handshakeTranscript.add('卡最后一次应答: $last');
    }
    if (report.deviceInfoError != null) {
      report.handshakeTranscript.add('失败原因: ${report.deviceInfoError}');
    }
    return false;
  }

  /// The running id for `SecurityData` envelopes on the security channel.
  ///
  /// `k3` keeps a counter (`m3.a`) and stamps every security message with it.
  /// Starting from 0 and incrementing per message reproduces that.
  int _securityMsgId = 0;

  /// Wraps a `SecurityProtocol` the way the firmware expects on the wire:
  /// `EuiccDeviceReq{cmd: SECURITY, request: SecurityData{id, sec}}`.
  Uint8List _wrapSecurityMsg(Uint8List securityProtocol) {
    _securityMsgId += 1;
    final data = sec.encodeSecurityDataSec(_securityMsgId, securityProtocol);
    return lf.wrapSecurity(data);
  }

  /// Asks the card for a fresh challenge (`SecurityProtocol{type: AUTH}`).
  ///
  /// Returns null when the reply carries no SecurityProtocol, which on this
  /// firmware means "you already have my challenge, use it".
  ///
  /// Both reply shapes are handled. The captured card answers a *bare*
  /// SecurityProtocol (`1A 14 12 12 0A 10 …`, no DeviceRsp wrapper at all), so
  /// parsing only through `DeviceRsp.securityBytes` finds nothing and the
  /// caller concludes "no challenge" -- which is not what the bytes say. The
  /// bare shape is what actually arrives on this firmware; the wrapped one is
  /// kept for the other revisions.
  Future<Uint8List?> _requestChallenge() async {
    final startFrame = _wrapSecurityMsg(sec.encodeAuthStart());
    _log('→ SecurityProtocol{type: AUTH} ${lf.hexOf(startFrame)}');
    report.handshakeTranscript.add('→ ${lf.hexOf(startFrame)}');
    try {
      final rsp1 = await _sendRaw(startFrame, secure: false);
      report.handshakeTranscript.add('← ${lf.hexOf(rsp1)}');
      final security1 = _securityBodyOf(rsp1);
      if (security1 == null) {
        final outer1 = lf.DeviceRsp.parse(rsp1);
        _log('  ← DeviceRsp{cmd=${outer1.cmd}, result=${outer1.result}} 无 security');
        return null;
      }
      final p1 = sec.SecurityProtocolMsg.parse(security1);
      _log('← $p1');
      final len = p1.authRandom.length;
      if (len == 16 || len == 32) {
        _log('  challenge: ${lf.hexOf(p1.authRandom)}');
        return Uint8List.fromList(p1.authRandom);
      }
      _log('  挑战长度异常：$len');
      return null;
    } catch (e) {
      _log('  请求挑战失败：$e');
      return null;
    }
  }

  /// Sends `SecurityProtocol{type: AUTH, auth{pcNonce, proof}}` and applies the
  /// UPDATE that comes back.
  Future<bool> _sendAuthReply(Uint8List pskKey, Uint8List challenge) async {
    // Vendor capture, 2026-10-21: `1A 36 12 34 0A 10 <16B> 12 20 <32B>`
    // - auth.random is the **16-byte challenge the card sent**, not a nonce we
    //   invent. Filling it with our own 32-byte value shifts the field length
    //   and the card rejects the reply.
    // - auth.auth is the 32-byte proof computed over that same challenge.
    final pcNonce = Uint8List.fromList(List<int>.from(challenge));
    final proof = sec.buildProof(pskKey, challenge, pcNonce);
    // `lf.wrapSecurity` is the EuiccDeviceReq{cmd: SECURITY} envelope -- still
    // required. What must NOT be added is a `type` field inside the body.
    final step2 = _wrapSecurityMsg(sec.encodeAuthReply(pcNonce, proof));
    _log('→ SecurityProtocol{AUTH, auth{nonce, proof}} ${lf.hexOf(step2)}');
    report.handshakeTranscript.add('→ ${lf.hexOf(step2)}');

    Uint8List rsp2;
    try {
      rsp2 = await _sendRaw(step2, secure: false);
    } catch (e) {
      _log('  ✗ 第 2 步无响应：$e');
      return false;
    }
    report.handshakeTranscript.add('← ${lf.hexOf(rsp2)}');

    final security2 = _securityBodyOf(rsp2);
    if (security2 == null) {
      final status = _statusCodeOf(rsp2);
      if (status != null) {
        _log('  ✗ $status');
        report.deviceInfoError = '握手第 2 步：$status';
        report.handshakeTranscript.add(status);
        return false;
      }
      final outer2 = lf.DeviceRsp.parse(rsp2);
      _log('  ✗ 第 2 步没有 SecurityProtocol (cmd=${outer2.cmd}, '
          'result=${outer2.result})');
      // Vendor capture 2026-10-23 18:27:46: a rejected AUTH reply comes back as
      // exactly two bytes, `08 05` — that is EuiccDeviceRsp.result (field 5)
      // = 5, with no SecurityData envelope at all. The vendor app does not
      // retry the AUTH; it sends `08 03 12 02 1A 00` (SCARD with an empty
      // scard block) to make the card re-issue a challenge, then runs the
      // whole handshake again.
      //
      // Name the case so the next log does not get read as "SecurityData
      // {id=1, error=5}" again — that reading cost a full day.
      if (outer2.result == 5) {
        _log('  ✗ 卡回 result=5（AUTH 回复被拒）；厂商做法是复位重开，见下方重置');
        report.deviceInfoError =
            '握手第 2 步：卡回 result=5（AUTH 回复未被接受）。厂商的做法是发 '
            'SCARD 空 payload 让卡重发挑战后重试，不是换个 PSK 硬试。';
        report.handshakeTranscript.add(
            '卡应答: 08 05 = EuiccDeviceRsp.result=5（2 字节，无 SecurityData 信封）');
        return false;
      }
      // Say what the card sent instead: a bare SecurityProtocol that merely
      // repeated the challenge means the AUTH reply was rejected (wrong PSK or
      // wrong proof shape), and that is a different fix from a silent card.
      final again = _challengeOf(rsp2);
      report.deviceInfoError = again != null
          ? '握手第 2 步被拒：卡重发了挑战（AUTH 回复未被接受，先检查 PSK）'
          : '握手第 2 步：设备未返回 SecurityProtocol';
      return false;
    }

    final p2 = sec.SecurityProtocolMsg.parse(security2);
    _log('← $p2');
    if (p2.configNonce.isEmpty) {
      _log('  ✗ 不是 UPDATE（type=${p2.type}, nonce=${p2.configNonce.length}B）');
      report.deviceInfoError = '握手第 2 步：未得到 UPDATE（type=${p2.type}）';
      return false;
    }
    _log('  nonce: ${lf.hexOf(p2.configNonce)}');
    _log('  aad:   ${lf.hexOf(p2.configAad)}');
    _log('  auth:  ${lf.hexOf(p2.configAuth)}');

    try {
      _secure = sec.deriveLpadSession(
        proof: proof,
        updateNonce: Uint8List.fromList(p2.configNonce),
        updateAad: Uint8List.fromList(p2.configAad),
        updateAuth: Uint8List.fromList(p2.configAuth),
      );
    } on FormatException catch (e) {
      _log('✗ 会话派生失败: ${e.message}');
      report.deviceInfoError = '握手第 3 步（MAC 校验）失败：${e.message}';
      return false;
    }
    return true;
  }

  /// Sends a payload with an explicit encryption choice.
  ///
  /// Handshake messages are plaintext by definition, so they must not be
  /// wrapped even after `_secure` exists. Passing the flag (rather than
  /// temporarily nulling the session) keeps the state machine honest and makes
  /// nested calls safe.
  Future<Uint8List> _sendRaw(Uint8List payload, {required bool secure}) {
    return _send(payload, replyTimeout, forcePlain: !secure);
  }

  /// Builds a timeout error that says what the link and the card were doing.
  ///
  /// "No reply" has four very different causes, and they are told apart here so
  /// the UI does not have to guess: the write never landed (notification
  /// closed), the card answered something unparseable (wrong length header),
  /// the card was busy and answered late, or the card really is silent (no
  /// notifications at all -- usually the wrong first frame or a wrong channel).
  String _timeoutMessage(int seq, int chunks, Duration timeout) {
    final parts = <String>[
      '卡在 ${timeout.inSeconds}s 内没有回复（命令 #$seq，已写 $chunks 片）',
    ];
    if (!report.notifyEnabled) {
      parts.add('通知未打开：写入的命令卡根本收不到');
    } else if (!_cccdConfirmed) {
      parts.add('CCCD 未确认：卡的回复可能没有到达手机');
    }
    if (report.lastFrames.isEmpty) {
      parts.add('卡一个字节都没回');
      if (seq == 1) {
        parts.add('首帧无响应：多为配对未完成、长度头不对（2/4 字节）或 MTU 不足');
      }
    } else {
      parts.add('最近收到的帧：${report.lastFrames.join(" | ")}');
      if (report.undecodableFrames > 0) {
        parts.add('其中 ${report.undecodableFrames} 帧解析失败'
            '（怀疑长度头 4 字节或分片边界错误）');
      }
      if (report.unsolicitedFrames > 0) {
        parts.add('有 ${report.unsolicitedFrames} 条迟到回复'
            '（卡在长时间操作，可把超时调大后重试）');
      }
    }
    return parts.join('；');
  }

  /// Sends exactly one read-only `getDeviceInfo` and reports what came back.
  ///
  /// No retry: a device that refuses or ignores this frame will not start
  /// answering because we repeat it, and blind repeats are exactly what the
  /// safety requirement forbids.
  Future<lf.DeviceInfo?> probeDeviceInfo({bool allowSecureRetry = true}) async {
    try {
      var frame = await request(lf.encodeGetDeviceInfo());

      // A card that answers with a *bare* SecurityProtocol (no DeviceRsp
      // wrapper) is the common case on this firmware, and it is exactly what
      // the capture shows: `08 01 2A 14 …` has no cmd/result, field 5 at the
      // top level. Parsing it as DeviceRsp yields nothing and the handshake is
      // never attempted, which presented as "frame received but unparseable".
      final bare = _tryBareSecurityProtocol(frame);
      if (bare != null) {
        _log('响应是裸 SecurityProtocol（无 DeviceRsp 外壳）');
        report.pairingPrompt ??= '卡要求先建立安全通道';
        if (!allowSecureRetry) return null;
        if (!await startSecureChannel()) return null;
        frame = await request(lf.encodeGetDeviceInfo());
      }

      final rsp = lf.DeviceRsp.parse(frame);
      _log('解析: cmd=${rsp.cmd} result=${rsp.result} '
          'info=${rsp.infoBytes.length}B security=${rsp.securityBytes.length}B');

      // The firmware's answer to getDeviceInfo carries a `security` field on
      // this card (captured: `2A 14 12 12 0A 10 <16B>`). The vendor app treats
      // that as informational and carries on in plaintext: its own trace shows
      // getDeviceInfo -> SUCCESS without any handshake, followed by
      // openLogicalChannel and APDUs on the same unencrypted channel.
      //
      // Treating the field as "handshake required, everything blocked until it
      // succeeds" is what wedged the probe: the card never wanted a session to
      // read device info, and every attempt to build one answered `{field5:5}`.
      if (rsp.securityBytes.isNotEmpty) {
        final proto = sec.SecurityProtocolMsg.parse(rsp.securityBytes);
        _log('security 字段 ${rsp.securityBytes.length}B'
            '（type=${proto.type}, random=${proto.authRandom.length}B）'
            '—— 按厂商行为仅作记录，明文继续');
        report.securityAdvertised = true;
      }

      if (rsp.needsSecureChannel) {
        report.deviceInfoError = '设备要求先建立安全通道 (result=-256)';
        _log('✗ ${report.deviceInfoError}');
        return null;
      }

      return _extractInfo(rsp);
    } on TransportError catch (e) {
      report.deviceInfoError = e.message;
      _log('✗ $e');
      return null;
    } catch (e) {
      report.deviceInfoError = '$e';
      _log('✗ 解析失败: $e');
      return null;
    }
  }

  /// One read-only `getDeviceInfo` with an explicit frame length header.
  ///
  /// Exists because the header size is per-device (`bleDataLengthSize`, 2 or 4)
  /// and cannot be read off the card: a card built for 4-byte headers reads our
  /// `00 02` as a 0x00020008-byte message and never answers. Rather than guess,
  /// the UI reopens the link with the other size and repeats this one harmless
  /// request. Nothing about the card changes.
  Future<lf.DeviceInfo?> probeWithHeader(
    int headerSize, {
    int? mtuOverride,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    LinksfieldTransport? other;
    try {
      other = await LinksfieldTransport.connect(
        device,
        lengthHeaderSize: headerSize,
        replyTimeout: timeout,
        mtuOverride: mtuOverride,
      );
      final info = await other.request(lf.encodeGetDeviceInfo()).then(
            (frame) => lf.DeviceRsp.parse(frame),
          ).then((rsp) => rsp.info);
      if (info != null) {
        report.lengthHeaderSize = headerSize;
        report.summary = '长度头 $headerSize 字节可用：${info.deviceName.isNotEmpty ? info.deviceName : info.vendor}';
      }
      return info;
    } catch (e) {
      _log('长度头 $headerSize 字节探测失败：$e');
      return null;
    } finally {
      await other?.close();
      // The probe leaves the card disconnected; the caller reconnects.
    }
  }


  /// The `SecurityProtocol` bytes inside [frame], however they are wrapped.
  ///
  /// Two shapes appear in the captures:
  ///   * `DeviceRsp{security: SecurityProtocol}` -- `cmd=1` then field 5
  ///   * bare `SecurityProtocol`                 -- field 1 = type (0), field 2
  ///     = auth, no envelope. The captured card uses this one.
  ///
  /// `DeviceRsp.parse` only looks for field 5, so it returns an empty
  /// `securityBytes` for the bare shape and the handshake stops before it
  /// starts. Returning the frame itself for the bare case keeps both paths on
  /// the same parser.
  Uint8List? _securityBodyOf(Uint8List frame) {
    final outer = lf.DeviceRsp.parse(frame);
    if (outer.securityBytes.isNotEmpty) return outer.securityBytes;
    // `SecurityData{id, sec}`: the card answers a handshake message inside the
    // same envelope the vendor uses to send one. Field 3 is `sec`; field 1 is
    // the id. Without this unwrap the protocol body is mistaken for a whole
    // SecurityProtocol and every field lands one level too shallow.
    final data = sec.parseSecurityData(frame);
    if (data != null && data.ciphertext.isNotEmpty) {
      // `parseSecurityData` exposes whatever blobs it saw; field 3 (sec) is the
      // plaintext protocol, so re-read it explicitly.
      final secBody = _fieldBytes(frame, 3);
      if (secBody != null && secBody.isNotEmpty) return secBody;
      return data.ciphertext;
    }
    if (_tryBareSecurityProtocol(frame) != null) return frame;
    return null;
  }

  /// Raw bytes of a length-delimited top-level [field], or null.
  Uint8List? _fieldBytes(Uint8List frame, int field) {
    try {
      final r = lf.PbReader(frame);
      while (true) {
        final t = r.nextTag();
        if (t == null) return null;
        if (t.$1 == field && t.$2 == 2) return r.readBytes();
        r.skip(t.$2);
      }
    } on FormatException {
      return null;
    }
  }

  /// The 16/32-byte challenge in [frame], bare or wrapped, or null.
  Uint8List? _challengeOf(Uint8List frame) {
    final body = _securityBodyOf(frame);
    if (body == null) return null;
    final p = sec.SecurityProtocolMsg.parse(body);
    final r = p.authRandom;
    return (r.length == 16 || r.length == 32) ? Uint8List.fromList(r) : null;
  }

  /// The card's status code when it rejects a security message.
  ///
  /// `{field5: N}` arrives where an UPDATE would be. Field 5 is not part of
  /// `SecurityProtocol`, so feeding the frame to the protocol parser raises
  /// "truncated bytes" and hides the one number that says what went wrong.
  /// Return it as a readable reason instead.
  String? _statusCodeOf(Uint8List frame) {
    try {
      final r = lf.PbReader(frame);
      while (true) {
        final t = r.nextTag();
        if (t == null) return null;
        if (t.$1 == 5 && t.$2 == 0) {
          final v = r.readUint();
          return '卡回状态码 $v（拒绝了这次安全消息）';
        }
        r.skip(t.$2);
      }
    } on FormatException {
      return null;
    }
  }

  /// Returns the parsed message when [frame] is a bare `SecurityProtocol`.
  ///
  /// Detection is structural, not by trying the handshake: field 1 must be a
  /// small type value and field 2 must be a nested message of plausible size.
  /// Anything else stays on the DeviceRsp path.
  sec.SecurityProtocolMsg? _tryBareSecurityProtocol(Uint8List frame) {
    if (frame.isEmpty) return null;
    // A DeviceRsp always starts with cmd (field 1). A bare SecurityProtocol also
    // starts with field 1 = type, so the distinction is what comes next: the
    // wrapped form has cmd=0/1/2/3 followed by result/info, while the bare form
    // carries an auth sub-message at field 2 with a 16-byte random inside.
    try {
      final proto = sec.SecurityProtocolMsg.parse(frame);
      if (proto.authRandom.length == 16 || proto.authRandom.length == 32) {
        // Require that every top-level byte was consumed as a known field, so a
        // DeviceRsp that happens to carry a 16-byte blob is not mistaken for it.
        if (!_onlySecurityFields(frame)) return null;
        return proto;
      }
      if (proto.configNonce.length == 12 && proto.configAuth.isNotEmpty) {
        return proto;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  /// True when [frame] consists only of SecurityProtocol's own field numbers.
  static bool _onlySecurityFields(Uint8List frame) {
    var i = 0;
    while (i < frame.length) {
      final tag = frame[i];
      i++;
      final field = tag >> 3;
      final wire = tag & 7;
      if (field < 1 || field > 3) return false;
      if (wire == 0) {
        while (i < frame.length) {
          final x = frame[i];
          i++;
          if ((x & 0x80) == 0) break;
        }
      } else if (wire == 2) {
        var len = 0, shift = 0;
        while (i < frame.length) {
          final x = frame[i];
          i++;
          len |= (x & 0x7F) << shift;
          if ((x & 0x80) == 0) break;
          shift += 7;
          if (shift > 28) return false;
        }
        i += len;
        if (i > frame.length) return false;
      } else {
        return false;
      }
    }
    return true;
  }

  lf.DeviceInfo? _extractInfo(lf.DeviceRsp rsp) {
    final info = rsp.info;
    if (info == null) {
      // A missing `info` is not a failure.
      //
      // This card answers getDeviceInfo with `SecurityProtocol` only
      // (`08 01 2A 14 …`) and no device info block. The vendor app's own trace
      // shows it carrying on regardless: openLogicalChannel and the ES10x
      // APDUs work on the same plaintext channel. Returning null here made the
      // probe report "设备仍要求安全通道" and aborted the whole session before a
      // single APDU was ever sent.
      _log('⚠ DeviceRsp 无 info 字段（security=${rsp.securityBytes.length}B）'
          '—— 继续，不阻断链路');
      report.summary = rsp.securityBytes.isNotEmpty
          ? '卡已响应（仅回 security 字段，无设备信息）'
          : '卡已响应（无设备信息）';
      // Signal "the link works" without inventing a device info object: the
      // caller only needs to know it may proceed.
      return const lf.DeviceInfo(vendor: '', deviceName: '');
    }
    _log('✓ 设备信息: $info');
    report.summary =
        '设备已响应: ${info.vendor.isNotEmpty ? info.vendor : "(未报告厂商)"}';
    return info;
  }

  // ------------------------------------------------------- EuiccTransport

  /// Brings the session to the state the SGP.22 engine expects.
  ///
  /// `connect()` already established the BLE link; what is still missing is the
  /// secure channel, and the only way to learn whether it is needed is to send
  /// the (read-only) getDeviceInfo probe and read the answer:
  ///
  ///   * plain `DeviceRsp{info}`      -> card talks plaintext, nothing to do
  ///   * plain `DeviceRsp{security}`  -> handshake, then replay the probe
  ///
  /// Doing it here means every caller (list, enable, download) can assume the
  /// channel is ready, instead of each one tripping over `-256` on its first
  /// APDU.
  @override
  Future<void> open() async {
    if (!_open) {
      throw TransportError('请使用 LinksfieldTransport.connect() 建立连接');
    }
    if (_secure != null) return;

    _log('— 建立会话（探测设备信息以决定是否需要安全通道）—');
    final info = await probeDeviceInfo();
    if (info != null) {
      _log('设备以明文响应，无需安全通道');
      return;
    }
    if (_secure != null) {
      _log('✓ 会话就绪（安全通道）');
      return;
    }
    // The card said nothing at all. Before declaring it broken, rule out the
    // one setting that is invisible from our side: the frame length header.
    if (report.lastFrames.isEmpty && report.deviceInfoError != null) {
      final alt = lengthHeaderSize == 2 ? 4 : 2;
      _log('— 首帧无任何回复，尝试长度头 $alt 字节 —');
      final info2 = await probeWithHeader(alt);
      if (info2 != null) {
        // The probe ran on a fresh link with the working header; adopt it and
        // rebuild this transport's link so the caller can carry on.
        _log('✓ 长度头 $alt 字节可用，已按该设置重连');
        await close();
        final rebuilt = await LinksfieldTransport.connect(
          device,
          lengthHeaderSize: alt,
          replyTimeout: replyTimeout,
        );
        report.lengthHeaderSize = alt;
        report.diagnosisOverride =
            '这张卡用 $alt 字节长度头，已自动切换。';
        await rebuilt.open();
        // Hand the ready session's state to the caller: copy the envelope
        // objects over and retire the probe link.
        _adopt(rebuilt);
        _open = true;
        return;
      }
      report.deviceInfoError =
          '${report.deviceInfoError}；长度头 2 和 4 字节都没有回复';
    }
    throw TransportError(
      '会话无法建立：${report.deviceInfoError ?? "设备未响应"}',
    );
  }

  /// Takes over the session state of [other] (used after a header re-probe).
  void _adopt(LinksfieldTransport other) {
    _secure = other._secure;
    report.mtu = other.report.mtu;
    report.mtuNegotiated = other.report.mtuNegotiated;
    report.notifyEnabled = other.report.notifyEnabled;
    report.cccdConfirmed = other.report.cccdConfirmed;
    lengthHeaderSize = other.lengthHeaderSize;
  }

  /// Raw APDU forwarding for the SGP.22 engine.
  ///
  /// Not used by the probe phase; kept so the shared engine can talk to a
  /// Linksfield card once the secure channel question is settled.
  @override
  Future<ApduResponse> transmit(Uint8List apdu) async {
    final parsed = _parseApdu(apdu);
    final scard = lf.encodeTransmitApdu(
      channel: parsed.$1,
      cla: parsed.$2,
      instruction: parsed.$3,
      p1: parsed.$4,
      p2: parsed.$5,
      p3: parsed.$6,
      dataHex: parsed.$7,
    );

    var frame = await request(lf.wrapScard(scard));
    var rsp = lf.SmartCardRsp.parse(frame);

    // The card wants the encrypted channel. Establish it once, then replay the
    // same APDU -- the request is idempotent at this layer (the card decides).
    if (rsp.needsSecureChannel && !isSecure) {
      _log('设备要求安全通道 → 建立后重发同一个 APDU');
      final ok = await startSecureChannel();
      if (!ok) {
        throw TransportError('安全通道建立失败，无法继续发送 APDU');
      }
      frame = await request(lf.wrapScard(scard));
      rsp = lf.SmartCardRsp.parse(frame);
    }

    if (rsp.needsSecureChannel) {
      throw TransportError('设备仍要求安全通道 (result=-256)');
    }
    if (rsp.apduBytes.isEmpty) {
      throw TransportError('SmartCardRsp 中没有 APDU 数据 (result=${rsp.result})');
    }
    final sw = _readSw(rsp.apduBytes);
    return ApduResponse(
      Uint8List.sublistView(rsp.apduBytes, 0, rsp.apduBytes.length - 2),
      sw,
    );
  }

  @override
  Future<int> openChannel(Uint8List aid) async {
    final hex = aid.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final req = lf.encodeOpenLogicalChannel(hex);
    // Print both directions. "result=-1" says the card refused, but not what it
    // saw; without the request bytes there is no way to tell a wrong field
    // number from a wrong AID encoding from a command the card does not support.
    _log('→ openLogicalChannel aid=$hex');
    _log('   请求体 ${lf.hexOf(req)}');
    // Also mirror into the transcript: `report.lines` is not rendered by the
    // diagnostics panel, so log-only lines are invisible exactly when they
    // matter most.
    report.handshakeTranscript.add('— openLogicalChannel —');
    report.handshakeTranscript.add('aid=$hex');
    report.handshakeTranscript.add('→ 请求体 ${lf.hexOf(req)}');
    report.handshakeTranscript.add('→ 完整帧 ${lf.hexOf(lf.wrapScard(req))}');
    var frame = await request(lf.wrapScard(req));
    _log('← ${lf.hexOf(frame)}');
    report.handshakeTranscript.add('← ${lf.hexOf(frame)}');
    var rsp = lf.SmartCardRsp.parse(frame);
    report.handshakeTranscript.add(
        '解析: cmd=${rsp.cmd} result=${rsp.result} '
        'open=${rsp.openChannelData} apdu=${rsp.apduBytes.length}B');
    // A challenge in field 3 is not a channel number. Record every one we get:
    // a value that changes per request proves the card randomises it, which is
    // what makes it usable as a session nonce instead of a fixed identifier.
    final early = rsp.challenge;
    if (early != null && early.isNotEmpty) {
      report.challengesSeen.add(lf.hexOf(early));
      _log('  字段 3 是挑战，不是通道号：${lf.hexOf(early)}');
    }
    if (rsp.needsSecureChannel && !isSecure) {
      _log('openChannel: 设备要求安全通道 → 建立后重发');
      if (!await startSecureChannel()) {
        throw TransportError('安全通道建立失败，无法打开逻辑通道');
      }
      frame = await request(lf.wrapScard(lf.encodeOpenLogicalChannel(hex)));
      rsp = lf.SmartCardRsp.parse(frame);
    }
    if (rsp.openChannelData.isEmpty) {
      // Field 3 holding a `SecurityProtocol` instead of a channel number means
      // the card accepted the command (`result = 0`) but wants the secure
      // channel established first. Reporting that as "打开逻辑通道失败" hid the
      // fact that the command was understood.
      final ch = rsp.challenge;
      if (ch != null) {
        report.handshakeTranscript
            .add('openLogicalChannel 返回挑战（${ch.length}B），先建立安全通道再重试');
        _log('openChannel: 卡回挑战，建立安全通道后重发');
        if (!isSecure) {
          final ok = await startSecureChannel(knownChallenge: ch);
          if (!ok) {
            throw TransportError(
                '打开通道需要安全通道，但握手失败：${report.deviceInfoError ?? "未知原因"}');
          }
        }
        // Replay the same request now that a session exists.
        frame = await request(lf.wrapScard(req));
        report.handshakeTranscript.add('← 重试 ${lf.hexOf(frame)}');
        rsp = lf.SmartCardRsp.parse(frame);
        report.handshakeTranscript.add(
            '解析: cmd=${rsp.cmd} result=${rsp.result} open=${rsp.openChannelData}');
        if (rsp.openChannelData.isNotEmpty) {
          return rsp.openChannelData.first;
        }
        throw TransportError(
            '建立安全通道后仍无通道号 (result=${rsp.result}, '
            'raw=${lf.hexOf(rsp.openChannelRaw, max: 24)})');
      }
      throw TransportError(
          '打开逻辑通道失败 (result=${rsp.result}, cmd=${rsp.cmd}, '
          'openData=${rsp.openChannelData.length}, apdu=${rsp.apduBytes.length}B, '
          'raw=${lf.hexOf(rsp.openChannelRaw, max: 24)})');
    }
    return rsp.openChannelData.first;
  }

  /// Sends MANAGE CHANNEL close (00 70 80 <ch>) through the card's APDU pipe.
  ///
  /// The protobuf request only expresses `closeLogicalChannel`, which this
  /// firmware answers but does not act on for a channel we opened with the
  /// `openLogicalChannel` command. Plain APDU close works on both.
  @override
  Future<bool> closeChannelOnCard(int channel) async {
    if (channel <= 0) return true;
    try {
      final rsp = await transmit(
        Uint8List.fromList([0x00, 0x70, 0x80, channel & 0xFF, 0x00]),
      );
      return rsp.isOk;
    } catch (e) {
      _log('MANAGE CHANNEL close 失败: $e');
      return false;
    }
  }

  /// This firmware exposes one card handle: a second logical channel would
  /// steal the APDU replies meant for the first. Do not advertise support.
  @override
  Future<int> addChannel(Uint8List aid) =>
      throw UnsupportedError('Linksfield 卡只支持一个逻辑通道');

  @override
  Future<void> closeChannel(int channel) async {
    try {
      await request(lf.wrapScard(lf.encodeCloseLogicalChannel(channel)));
    } catch (_) {
      // Closing is best-effort; the link teardown also releases it.
    }
  }

  @override
  Future<void> close() async {
    _log('关闭会话');
    await _notifySub?.cancel();
    _notifySub = null;
    await _connSub?.cancel();
    _connSub = null;
    _assembler.reset();

    // A half-received frame left behind by a timed-out request would be
    // prefixed onto the next session's first notification, and the card's next
    // reply would then be rejected as an impossible length -- presenting as
    // "sent one chunk, nothing came back" all over again. The counters go with
    // it: a reopened transport is a new conversation.
    _requestSeq = 0;
    _awaitingReplyFor = -1;

    // Drop the hub and build a fresh one. Reusing a closed StreamController
    // silently swallows every later notification, so a transport that is
    // reopened must not keep the old instance.
    final hub = _frames;
    _frames = StreamController<Uint8List>.broadcast();

    try {
      await tx.setNotifyValue(false);
    } catch (_) {}
    try {
      await device.disconnect();
    } catch (_) {}
    _open = false;
    _cccdConfirmed = false;
    if (!hub.isClosed) await hub.close();
  }

  // ---------------------------------------------------------------- helpers

  /// Extracts SW1/SW2 from the tail of an APDU response.
  static int _readSw(Uint8List apduRsp) {
    if (apduRsp.length < 2) return 0;
    return (apduRsp[apduRsp.length - 2] << 8) | apduRsp[apduRsp.length - 1];
  }

  /// ISO 7816-4 short APDU → the fields `TransmitApdu` carries.
  static (int, int, int, int, int, int, String) _parseApdu(Uint8List apdu) {
    if (apdu.length < 4) throw TransportError('APDU 太短 (${apdu.length}B)');
    final cla = apdu[0];
    final ins = apdu[1];
    final p1 = apdu[2];
    final p2 = apdu[3];

    var p3 = 0;
    var data = Uint8List(0);
    if (apdu.length == 5) {
      p3 = apdu[4];
    } else if (apdu.length > 5) {
      final lc = apdu[4];
      if (5 + lc > apdu.length) {
        throw TransportError('APDU 的 Lc 与实际长度不符');
      }
      p3 = lc;
      data = Uint8List.sublistView(apdu, 5, 5 + lc);
    }
    final hex = data
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return (cla & 0x0F, cla, ins, p1, p2, p3, hex);
  }
}
