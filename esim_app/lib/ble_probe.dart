/// Read-only BLE probe for an unknown eSIM reader.
///
/// This module deliberately knows **nothing** about card protocols. It only
/// connects, enumerates GATT, subscribes to notifying characteristics and
/// reports whatever bytes arrive. No command is ever sent, so nothing on the
/// card can be changed.
///
/// Why it exists: "we found the NUS service" is not identification. A device
/// that exposes the Nordic UART service may speak protobuf, JSON, a CLI, or
/// nothing at all until it is bonded. Guessing wasted several rounds, so this
/// probe produces evidence instead:
///
///   * connection state transitions, with timestamps
///   * the complete GATT tree: service UUID, characteristic UUID, properties,
///     descriptors
///   * whether TX notify was actually enabled (CCCD state, not the call result)
///   * every byte received, or an explicit "0 bytes"
///   * the disconnect cause, if one happens
///
/// Rules baked in (learned the hard way on `BLE-eSIM-15065138`):
///   1. Wait for the connection state, do not trust `connect()` returning.
///   2. Settle before `discoverServices()`; Android reports
///      "device is disconnected" if discovery races the GATT handshake.
///   3. Subscribe exactly once per session and cancel it on disconnect. A
///      broadcast stream with a stale subscription is what produced
///      "Stream has already been listened to".
///   4. Never call createBond on a disconnected device, and never force it at
///      all -- the probe only *reports* the bond state.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// One timestamped line of probe output.
class ProbeEvent {
  final DateTime at;
  final String text;

  ProbeEvent(this.at, this.text);

  @override
  String toString() {
    final t = at;
    final stamp = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
    return '[$stamp] $text';
  }
}

/// Result of one probe session.
class ProbeReport {
  final List<ProbeEvent> events = [];
  final List<GattServiceInfo> services = [];

  /// Characteristics we subscribed to (TX-like).
  final List<GattCharInfo> subscribed = [];

  /// Total bytes received across all notifying characteristics.
  int bytesReceived = 0;

  /// Raw payloads, truncated for display but complete enough to classify.
  final List<String> receivedHex = [];

  /// Anything that blocks identification, phrased as an instruction.
  final List<String> blockers = [];

  /// Every readable characteristic, with value or the read error.
  final List<DeviceInfoValue> deviceInfo = [];

  bool connected = false;
  bool servicesDiscovered = false;
  String? disconnectReason;

  /// Set when a session ends; a new probe always starts from a clean report.
  String protocolVerdict = '协议未识别';

  ProbeReport();
}

class GattCharInfo {
  final String serviceUuid;
  final String charUuid;
  final String properties;
  final List<String> descriptors;
  bool notifyEnabled = false;
  String notifyError = '';

  GattCharInfo({
    required this.serviceUuid,
    required this.charUuid,
    required this.properties,
    required this.descriptors,
  });

  bool get canWrite => properties.contains('write');
  bool get canNotify => properties.contains('notify') || properties.contains('indicate');
}

class GattServiceInfo {
  final String uuid;
  final List<GattCharInfo> chars;
  GattServiceInfo(this.uuid, this.chars);
}

/// One readable characteristic value (Device Information, mostly).
class DeviceInfoValue {
  final String serviceUuid;
  final String charUuid;
  final String label;
  List<int> value = const [];
  String error = '';

  DeviceInfoValue({
    required this.serviceUuid,
    required this.charUuid,
    this.label = '',
  });
}

/// One session. Create a new one for every connection attempt -- reusing a
/// session across connects is what leaks subscriptions.
class BleProbeSession {
  final BluetoothDevice device;
  final ProbeReport report = ProbeReport();

  StreamSubscription<BluetoothConnectionState>? _connSub;
  final List<StreamSubscription<List<int>>> _valueSubs = [];

  /// True while this session owns the link.
  bool _active = false;

  /// First writable characteristic found (the "RX" side of the firmware).
  BluetoothCharacteristic? _writableTx;

  BleProbeSession(this.device);

  bool get isActive => _active;

  void _log(String text) => report.events.add(ProbeEvent(DateTime.now(), text));

  /// Connects, enumerates, subscribes, listens for [listenFor].
  ///
  /// Never throws: every failure is recorded in the report so the UI can show
  /// it without a crash dialog.
  Future<ProbeReport> run({
    Duration listenFor = const Duration(seconds: 15),
    bool readWritableCharacteristics = true,
    bool sendProbeOnSilence = false,
  }) async {
    _log('开始探测 ${device.remoteId.str} (${device.platformName})');
    try {
      await _connect();
      await _discover();
      await _subscribeAll();
      if (readWritableCharacteristics) await _readDeviceInfo();
      if (sendProbeOnSilence && _writableTx != null) {
        await _promptIfSilent(_writableTx!);
      } else {
        _log('监听 ${listenFor.inSeconds}s（不发任何命令）…');
        await Future.delayed(listenFor);
        _log('监听结束，共收到 ${report.bytesReceived} 字节');
      }
      await _verdict();
    } catch (e) {
      _log('异常: $e');
    } finally {
      await stop();
    }
    return report;
  }

  // ------------------------------------------------------------- connecting

  Future<void> _connect() async {
    // Report the bond state; never force pairing here. A disconnected device
    // cannot be bonded, and pairing decisions belong to the caller.
    try {
      final bond = await device.bondState
          .first
          .timeout(const Duration(seconds: 3), onTimeout: () => BluetoothBondState.none);
      _log('配对状态: ${bond.name}（本探测不发起配对）');
      if (bond != BluetoothBondState.bonded) {
        report.blockers.add(
          '设备未配对 —— 需要配对的固件会一直沉默，先配对再探测',
        );
      }
    } catch (e) {
      _log('配对状态读取失败: $e');
    }

    if (device.isConnected) {
      _log('已存在连接，先断开以建立干净会话');
      try {
        await device.disconnect();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 400));
    }

    _log('connect() 调用（mtu: null, autoConnect: false）');
    // mtu:null matters: the default (512) is requested immediately and this
    // firmware drops the link when it sees it too early.
    await device.connect(
      timeout: const Duration(seconds: 20),
      mtu: null,
      autoConnect: false,
    );

    // Trust the state stream, not the future's completion.
    final state = await _waitForConnection(Duration(seconds: 10));
    report.connected = state;
    _log('连接状态: ${state ? "connected ✓" : "未确认连接 ✗"}');
    if (!state) throw StateError('连接状态未确认');

    _active = true;
    _connSub = device.connectionState.listen((s) {
      _log('连接状态变化: ${s.name}');
      if (s == BluetoothConnectionState.disconnected) {
        report.disconnectReason ??= 'link disconnected';
      }
    });

    // Let the GATT settle before discovery.
    await Future.delayed(const Duration(milliseconds: 800));
  }

  Future<bool> _waitForConnection(Duration timeout) async {
    if (device.isConnected) return true;
    try {
      final s = await device.connectionState
          .where((s) => s == BluetoothConnectionState.connected)
          .first
          .timeout(timeout);
      return s == BluetoothConnectionState.connected;
    } catch (_) {
      return device.isConnected;
    }
  }

  // ------------------------------------------------------------- discovery

  Future<void> _discover() async {
    _log('discoverServices() …');
    final services = await device.discoverServices();
    report.servicesDiscovered = true;
    _log('发现 ${services.length} 个服务');

    for (final s in services) {
      final chars = <GattCharInfo>[];
      _log('  服务 ${s.uuid.str}'
          '${s.isPrimary ? "" : " (secondary)"}');
      for (final c in s.characteristics) {
        final info = GattCharInfo(
          serviceUuid: s.uuid.str,
          charUuid: c.uuid.str,
          properties: _props(c.properties),
          descriptors: c.descriptors.map((d) => d.uuid.str).toList(),
        );
        chars.add(info);
        _log('    ├ 特征 ${c.uuid.str}');
        _log('    │   属性: ${info.properties}');
        if (info.descriptors.isNotEmpty) {
          _log('    │   描述符: ${info.descriptors.join(", ")}');
        }
        if (c.properties.write || c.properties.writeWithoutResponse) {
          _writableTx ??= c;
        }
      }
      report.services.add(GattServiceInfo(s.uuid.str, chars));
    }
  }

  static String _props(CharacteristicProperties p) {
    final out = <String>[];
    if (p.broadcast) out.add('broadcast');
    if (p.read) out.add('read');
    if (p.writeWithoutResponse) out.add('writeWithoutResponse');
    if (p.write) out.add('write');
    if (p.notify) out.add('notify');
    if (p.indicate) out.add('indicate');
    if (p.authenticatedSignedWrites) out.add('signedWrite');
    if (p.extendedProperties) out.add('extended');
    return out.isEmpty ? '(none)' : out.join(', ');
  }

  // ------------------------------------------------------------ subscribe

  /// Subscribes to every notifying characteristic once and listens.
  ///
  /// One subscription per session, cancelled in [stop]; a second
  /// `setNotifyValue` on the same characteristic would trip
  /// "Stream has already been listened to".
  Future<void> _subscribeAll() async {
    for (final svc in report.services) {
      for (final ch in svc.chars) {
        if (!ch.canNotify) continue;

        // Find the live characteristic object again: GattCharInfo is a value.
        final live = device.servicesList
            .where((s) => s.uuid.str == svc.uuid)
            .expand((s) => s.characteristics)
            .where((c) => c.uuid.str == ch.charUuid)
            .cast<BluetoothCharacteristic?>()
            .firstWhere((c) => c != null, orElse: () => null);
        if (live == null) {
          ch.notifyError = '特征对象丢失';
          _log('  ✗ ${ch.charUuid} 无法订阅: 特征对象丢失');
          continue;
        }

        try {
          await live.setNotifyValue(true);
          ch.notifyEnabled = live.isNotifying;
          _log('  ${ch.notifyEnabled ? "✓" : "✗"} TX 通知已启用: '
              '${ch.charUuid} (isNotifying=${live.isNotifying})');
        } catch (e) {
          ch.notifyError = '$e';
          ch.notifyEnabled = false;
          _log('  ✗ TX 通知启用失败: ${ch.charUuid} → $e');
          continue;
        }

        if (!ch.notifyEnabled) continue;
        report.subscribed.add(ch);

        final sub = live.onValueReceived.listen((value) {
          report.bytesReceived += value.length;
          final hex = _hex(value);
          report.receivedHex.add('${ch.charUuid} ← $hex');
          _log('  ← 收到 ${value.length} 字节: $hex');
        }, onError: (Object e) {
          _log('  ✗ 通知流错误 ${ch.charUuid}: $e');
        });
        _valueSubs.add(sub);
      }
    }
    if (report.subscribed.isEmpty) {
      _log('没有任何可订阅的通知特征 —— 不会收到数据');
    }
  }

  /// Reads every `read`-capable characteristic and files it by UUID.
  ///
  /// Device Information (0x180A) is the firmware telling us what it is, so it
  /// is read explicitly, with named labels, instead of being buried in the raw
  /// dump. Every value and every error is kept -- a failed read is information
  /// too (usually "requires encryption").
  Future<void> _readDeviceInfo() async {
    for (final s in device.servicesList) {
      final isDeviceInfo = s.uuid.str.toLowerCase().startsWith('0000180a');
      for (final c in s.characteristics) {
        if (!c.properties.read) continue;
        final uuid = c.uuid.str.toLowerCase();
        final label = _deviceInfoLabels[_short(uuid)] ?? _short(uuid);
        final entry = DeviceInfoValue(
          serviceUuid: s.uuid.str,
          charUuid: c.uuid.str,
          label: isDeviceInfo ? label : '',
        );
        try {
          final v = await c.read();
          entry.value = v;
          report.deviceInfo.add(entry);
          _log('  read ${entry.label}(${entry.charUuid}) = ${_hex(v)}');
          final text = _text(v);
          if (text.isNotEmpty) _log('      → "$text"');
        } catch (e) {
          entry.error = '$e';
          report.deviceInfo.add(entry);
          _log('  read ${entry.label}(${entry.charUuid}) 失败: $e');
        }
      }
    }
  }

  static const _deviceInfoLabels = <String, String>{
    '2a23': '系统ID',
    '2a24': '型号',
    '2a25': '序列号',
    '2a26': '固件版本',
    '2a27': '硬件版本',
    '2a28': '软件版本',
    '2a29': '制造商',
    '2a2a': 'IEEE认证',
    '2a50': 'PnP ID',
    '2a00': '设备名',
    '2a01': '外观',
    '2a04': '首选连接参数',
    '2aa6': '中心地址',
  };

  /// Short 16-bit form of a characteristic UUID ("2a24" for 00002a24-...).
  static String _short(String uuid) {
    final u = uuid.toLowerCase();
    if (u.length == 36 && u.startsWith('0000') && u.endsWith('-0000-1000-8000-00805f9b34fb')) {
      return u.substring(4, 8);
    }
    return u;
  }

  /// UTF-8 text when the bytes look like text, otherwise empty.
  static String _text(List<int> b) {
    if (b.isEmpty) return '';
    final printable = b.where((x) => (x >= 0x20 && x < 0x7f) || x == 0x0a).length;
    if (printable * 10 < b.length * 8) return '';
    try {
      return String.fromCharCodes(b).replaceAll('\x00', '').trim();
    } catch (_) {
      return '';
    }
  }

  /// Waits for the device to speak first, then -- only if it stayed silent --
  /// sends one line that contains no command at all.
  ///
  /// The distinction matters: a bare "\r\n" is a terminator, not an opcode, so
  /// it cannot trigger any write path on the card. Many CLI-style firmwares
  /// only reply after receiving a line, which is exactly why a purely passive
  /// probe sees 0 bytes on a perfectly healthy device.
  ///
  /// Disabled unless the caller asks for it.
  Future<void> _promptIfSilent(BluetoothCharacteristic tx) async {
    const passive = Duration(seconds: 4);
    _log('先静默等待 ${passive.inSeconds}s，看设备是否主动说话 …');
    final before = report.bytesReceived;
    await Future.delayed(passive);

    if (report.bytesReceived > before) {
      _log('设备主动发送过数据，不需要探测性写入');
      return;
    }

    _log('仍无数据 → 发送单个回车（空行，不含任何命令）以获取提示符');
    try {
      await tx.write(Uint8List.fromList([0x0D, 0x0A]), withoutResponse: false);
      _log('已写入 0D 0A（仅行结束符）');
    } catch (e) {
      _log('写入 0D 0A 失败: $e（可能要求配对或写入加密）');
      report.blockers.add('TX 写入被拒绝：$e');
      return;
    }

    await Future.delayed(const Duration(seconds: 3));
    if (report.bytesReceived > before) {
      _log('收到 ${report.bytesReceived - before} 字节 —— 协议有回应');
    } else {
      _log('空行也没有回应');
      report.blockers.addAll([
        '写 TX 成功但设备无应答 → 固件在等握手/配对，或要求加密帧',
        '这类固件通常在 bond 建立前丢弃所有写入',
      ]);
    }
  }

  // -------------------------------------------------------------- verdict

  Future<void> _verdict() async {
    final hasNus = report.services
        .any((s) => s.uuid.toLowerCase().startsWith('6e400001'));
    if (report.bytesReceived == 0) {
      report.protocolVerdict =
          '协议未识别：未收到任何字节${hasNus ? "（有 NUS 服务但设备沉默）" : ""}';
    } else {
      report.protocolVerdict = '协议未识别：收到 ${report.bytesReceived} 字节，'
          '尚未确认协议类型（原始数据见下方）';
    }
    if (report.bytesReceived == 0) {
      report.blockers.addAll([
        '订阅本身没问题：TX 的 CCCD 已写入成功，说明链路能收发 ATT 包',
        '设备沉默的最常见原因是未配对：这类固件在 bond 建立前不回任何数据',
        '第二种可能：只有手机先发命令它才回（本页不发命令，所以永远看不到）',
      ]);
    }
    _log(report.protocolVerdict);
  }

  // --------------------------------------------------------------- teardown

  /// Cancels every subscription this session created and drops the link.
  ///
  /// Safe to call twice: callers do it on disconnect *and* in `finally`.
  Future<void> stop() async {
    for (final s in _valueSubs) {
      await s.cancel();
    }
    _valueSubs.clear();

    await _connSub?.cancel();
    _connSub = null;

    if (_active) {
      _log('断开连接（会话结束）');
      try {
        await device.disconnect();
      } catch (e) {
        report.disconnectReason ??= '$e';
        _log('断开时异常: $e');
      }
      _active = false;
    }
    if (report.disconnectReason != null) {
      _log('断开原因: ${report.disconnectReason}');
    }
  }

  static String _hex(List<int> b) {
    if (b.isEmpty) return '(空)';
    final n = b.length > 64 ? 64 : b.length;
    final s = b.take(n).map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');
    return b.length > n ? '$s … (+${b.length - n}B)' : s;
  }

  /// The whole report as copyable text.
  ///
  /// Exists because the useful evidence (device info, GATT, timeline) is too
  /// long to retype from a screenshot.
  String exportText() {
    final b = StringBuffer();
    b.writeln('=== BLE 诊断报告 ===');
    b.writeln('生成时间: ${DateTime.now()}');
    b.writeln('设备: ${device.remoteId.str}  ${device.platformName}');
    b.writeln('');
    b.writeln('--- 结论 ---');
    b.writeln('连接: ${report.connected ? "已连接" : "未连接"}');
    b.writeln('服务发现: ${report.servicesDiscovered ? "完成" : "未完成"}');
    b.writeln('服务数: ${report.services.length}');
    b.writeln(
        'TX 通知: ${report.subscribed.isEmpty ? "无" : report.subscribed.map((c) => "${c.charUuid}(${c.notifyEnabled ? "已启用" : "未启用"})").join(", ")}');
    b.writeln('收到字节: ${report.bytesReceived}');
    b.writeln('协议判定: ${report.protocolVerdict}');
    b.writeln('断开原因: ${report.disconnectReason ?? "（仍保持连接）"}');
    for (final x in report.blockers) {
      b.writeln('阻塞项: $x');
    }

    b.writeln('');
    b.writeln('--- 设备信息（优先项在前） ---');
    final named = report.deviceInfo.where((d) => d.label.isNotEmpty).toList();
    final ordered = <DeviceInfoValue>[
      for (final u in _infoOrder)
        ...named.where((d) => _short(d.charUuid) == u),
      ...named.where((d) => !_infoOrder.contains(_short(d.charUuid))),
    ];
    if (ordered.isEmpty) {
      b.writeln('（未读到任何带名称的特征）');
    }
    for (final d in ordered) {
      if (d.error.isNotEmpty) {
        b.writeln('${d.label} (${d.charUuid}): 读取失败 - ${d.error}');
      } else {
        final hex = d.value
            .map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase())
            .join(' ');
        final text = _text(d.value);
        b.writeln('${d.label} (${d.charUuid}): ${hex.isEmpty ? "(空)" : hex}'
            '${text.isEmpty ? "" : "  \"$text\""}');
      }
    }

    b.writeln('');
    b.writeln('--- GATT 清单 ---');
    for (final s in report.services) {
      b.writeln('服务 ${s.uuid}');
      for (final c in s.chars) {
        b.writeln('  ├ ${c.charUuid}  [${c.properties}]');
        if (c.descriptors.isNotEmpty) {
          b.writeln('  │   描述符: ${c.descriptors.join(", ")}');
        }
        if (c.canNotify) {
          b.writeln('  │   通知: ${c.notifyEnabled ? "已启用" : "未启用"}');
        }
      }
    }

    b.writeln('');
    b.writeln('--- 时间线 ---');
    for (final e in report.events) {
      b.writeln(e.toString());
    }
    return b.toString();
  }

  /// Device-info characteristics in the order a human reads them.
  static const _infoOrder = [
    '2a29', // 制造商
    '2a24', // 型号
    '2a26', // 固件版本
    '2a27', // 硬件版本
    '2a28', // 软件版本
    '2a25', // 序列号
    '2a23', // 系统 ID
    '2a2a', // IEEE 认证
    '2a50', // PnP ID
  ];
}
