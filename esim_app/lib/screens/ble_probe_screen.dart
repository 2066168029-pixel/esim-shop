import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/services.dart';

import '../ble_probe.dart';

/// Read-only BLE diagnostic page.
///
/// Deliberately separate from the write-card flow: this page never sends a byte
/// to the device, so it is safe to run on an unknown reader. It exists to
/// answer three questions with evidence rather than guesses:
///
///   * does the link stay up?
///   * what does the GATT tree actually look like?
///   * did TX notify get enabled, and did anything arrive?
class BleProbeScreen extends StatefulWidget {
  const BleProbeScreen({super.key});

  @override
  State<BleProbeScreen> createState() => _BleProbeScreenState();
}

class _BleProbeScreenState extends State<BleProbeScreen> {
  final _scanner = CardScannerProxy();

  bool _scanning = false;
  String? _error;
  final List<BluetoothDevice> _devices = [];

  BleProbeSession? _session;
  bool _running = false;
  bool _autoRun = true;

  /// Send a bare CR/LF when the device stays silent.
  ///
  /// It is a line terminator, not a command, but it is still a write -- so it
  /// is an explicit opt-in rather than the default.
  bool _sendProbe = false;

  Future<void> _copyReport() async {
    final session = _session;
    if (session == null) return;
    await Clipboard.setData(ClipboardData(text: session.exportText()));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('诊断报告已复制')));
  }

  /// Ten back-to-back connect/disconnect cycles prove the teardown path.
  int _cycles = 0;
  int _cyclesTarget = 0;

  @override
  void dispose() {
    _scanner.stop();
    _session?.stop();
    super.dispose();
  }

  Future<void> _toggleScan() async {
    if (_scanning) {
      await _scanner.stop();
      setState(() => _scanning = false);
      return;
    }
    setState(() {
      _devices.clear();
      _error = null;
      _scanning = true;
    });
    try {
      final state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
        setState(() {
          _scanning = false;
          _error = '蓝牙未开启';
        });
        return;
      }
    } catch (_) {}

    _scanner.scan(onFound: (device) {
      if (!mounted) return;
      final isNew = !_devices.any((d) => d.remoteId == device.remoteId);
      if (isNew) {
        setState(() => _devices.add(device));
      }
      // Auto-probe: the first time a device shows up, run the read-only probe
      // without any further tapping.
      if (_autoRun && isNew && !_running && _session == null) {
        _runProbe(device);
      }
    });

    Timer(const Duration(seconds: 12), () {
      if (!mounted) return;
      _scanner.stop();
      setState(() => _scanning = false);
    });
  }

  Future<void> _runProbe(BluetoothDevice device, {int cycles = 1}) async {
    if (_running) return;
    setState(() {
      _running = true;
      _cycles = 0;
      _cyclesTarget = cycles;
      _error = null;
    });

    for (var i = 1; i <= cycles; i++) {
      // A fresh session per cycle. Reusing one is what leaks subscriptions and
      // produces "Stream has already been listened to".
      final session = BleProbeSession(device);
      setState(() {
        _session = session;
        _cycles = i;
      });
      // Already running -> the report is live-updating, no need to await twice.
      if (cycles == 1) {
        final report = await session.run(sendProbeOnSilence: _sendProbe);
        if (!mounted) return;
        setState(() {
          _running = false;
          if (!report.connected) _error = '连接失败，见下方日志';
        });
        return;
      }
      // Multi-cycle: shorter listen, and only print a one-line summary.
      final report = await session.run(
        listenFor: const Duration(seconds: 4),
        readWritableCharacteristics: i == 1,
      );
      session.report.events.add(ProbeEvent(DateTime.now(),
          '— 第 $i/$cycles 轮结束：连接=${report.connected} '
          '服务=${report.services.length} 通知=${report.subscribed.length} '
          '字节=${report.bytesReceived}'));
      setState(() {});
      await Future.delayed(const Duration(milliseconds: 600));
    }

    if (!mounted) return;
    setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final report = _session?.report;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('BLE 只读诊断'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: '复制日志',
            icon: const Icon(Icons.copy_all, size: 20),
            onPressed: _session == null ? null : _copyReport,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _introCard(),
          const SizedBox(height: 12),
          if (_error != null) _errorCard(_error!),
          _scanCard(),
          if (_devices.isNotEmpty) ...[
            const SizedBox(height: 12),
            ..._devices.map(_deviceTile),
          ],
          if (report != null) ...[
            const SizedBox(height: 12),
            _summaryCard(report),
            const SizedBox(height: 12),
            _deviceInfoCard(report),
            const SizedBox(height: 12),
            _gattCard(report),
            const SizedBox(height: 12),
            _logCard(report),
          ],
        ],
      ),
    );
  }

  Widget _introCard() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.shield_outlined, size: 18, color: Colors.green),
              const SizedBox(width: 6),
              const Text('只读模式',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 6),
            Text(
              '本页只做：连接 → 连接状态确认 → 服务发现 → 读取设备信息 → '
              '打印 GATT 清单 → 启用 TX 通知 → 监听 15 秒。'
              '不会发送任何命令，也不会修改卡片数据。',
              style: TextStyle(fontSize: 12, color: Colors.grey[700], height: 1.5),
            ),
          ],
        ),
      );

  Widget _errorCard(String message) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF1F0),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFFCCC7)),
        ),
        child: Text(message,
            style: const TextStyle(color: Color(0xFFCF1322), fontSize: 13)),
      );

  Widget _scanCard() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _running ? null : _toggleScan,
                icon: Icon(_scanning
                    ? Icons.stop
                    : Icons.bluetooth_searching),
                label: Text(_scanning ? '停止扫描' : '扫描设备'),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Checkbox(
                  value: _autoRun,
                  onChanged: _running
                      ? null
                      : (v) => setState(() => _autoRun = v ?? true),
                ),
                const Expanded(
                  child: Text('发现设备后自动探测（无需手动点）',
                      style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            Row(
              children: [
                Checkbox(
                  value: _sendProbe,
                  onChanged: _running
                      ? null
                      : (v) => setState(() => _sendProbe = v ?? false),
                ),
                const Expanded(
                  child: Text(
                    '静默 4 秒后发送一个空行 CR/LF（仅行结束符，不含命令）',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            if (_running) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: _cyclesTarget > 1 ? _cycles / _cyclesTarget : null,
                minHeight: 3,
              ),
            ],
          ],
        ),
      );

  Widget _deviceTile(BluetoothDevice d) => Card(
        margin: const EdgeInsets.only(bottom: 8),
        elevation: 0,
        child: ListTile(
          leading: const CircleAvatar(
            backgroundColor: Color(0xFFEAF3FF),
            child: Icon(Icons.memory, size: 18),
          ),
          title: Text(
            d.platformName.isEmpty ? '(未命名)' : d.platformName,
            style: const TextStyle(fontSize: 14),
          ),
          subtitle: Text(d.remoteId.str,
              style: TextStyle(fontSize: 11, color: Colors.grey[500])),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: _running ? null : () => _runProbe(d),
                child: const Text('探测'),
              ),
              TextButton(
                onPressed: _running ? null : () => _runProbe(d, cycles: 10),
                child: const Text('×10'),
              ),
            ],
          ),
        ),
      );

  Widget _summaryCard(ProbeReport r) {
    Widget row(String k, String v, {Color? color}) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 96,
                child: Text(k,
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              ),
              Expanded(
                child: Text(v,
                    style: TextStyle(fontSize: 12, color: color)),
              ),
            ],
          ),
        );

    final sub = r.subscribed.isEmpty
        ? '无'
        : r.subscribed
            .map((c) => '${c.charUuid}${c.notifyEnabled ? " ✓" : " ✗"}')
            .join('\n');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('探测结果',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          row('连接', r.connected ? '已连接 ✓' : '未连接 ✗',
              color: r.connected ? Colors.green[700] : Colors.red[700]),
          row('服务发现', r.servicesDiscovered ? '完成 ✓' : '未完成'),
          row('服务数', '${r.services.length}'),
          row('TX 通知', sub),
          row('收到字节', '${r.bytesReceived}',
              color: r.bytesReceived > 0 ? Colors.green[700] : Colors.grey),
          row('断开原因', r.disconnectReason ?? '（仍保持连接）'),
          row('协议判定', r.protocolVerdict,
              color: Colors.orange[800]),
          for (final b in r.blockers) row('阻塞项', b),
          if (_cyclesTarget > 1)
            row('循环', '已执行 $_cycles/$_cyclesTarget 轮'),
        ],
      ),
    );
  }

  /// Device Information (0x180A) values read from the card.
  ///
  /// Shown as its own card because these bytes are the firmware telling us what
  /// it is: manufacturer / model / firmware / hardware / software come first,
  /// everything else follows in read order.
  Widget _deviceInfoCard(ProbeReport r) {
    const order = ['2a29', '2a24', '2a26', '2a27', '2a28', '2a25', '2a23', '2a2a', '2a50'];
    String short(String uuid) {
      final u = uuid.toLowerCase();
      if (u.length == 36 && u.startsWith('0000') && u.endsWith('-0000-1000-8000-00805f9b34fb')) {
        return u.substring(4, 8);
      }
      return u;
    }

    final named = r.deviceInfo.where((d) => d.label.isNotEmpty).toList();
    final sorted = <DeviceInfoValue>[
      for (final u in order) ...named.where((d) => short(d.charUuid) == u),
      ...named.where((d) => !order.contains(short(d.charUuid))),
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('设备信息 (0x180A)',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (sorted.isEmpty)
            const Text('（未读取到设备信息特征）',
                style: TextStyle(fontSize: 12))
          else
            ...sorted.map((d) {
              final hex = d.value
                  .map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase())
                  .join(' ');
              final text = _printable(d.value);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 84,
                      child: Text(d.label,
                          style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                    ),
                    Expanded(
                      child: SelectableText(
                        d.error.isNotEmpty
                            ? '读取失败: ${d.error}'
                            : '${hex.isEmpty ? "(空)" : hex}'
                                '${text.isEmpty ? "" : "  \"$text\""}',
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: d.error.isNotEmpty ? Colors.red[700] : null,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  /// UTF-8 text when the bytes look like text (and not like a raw struct).
  String _printable(List<int> b) {
    if (b.isEmpty) return '';
    final ok = b.where((x) => (x >= 0x20 && x < 0x7f) || x == 0x0a).length;
    if (ok * 10 < b.length * 8) return '';
    return String.fromCharCodes(b).replaceAll('\x00', '').trim();
  }

  Widget _gattCard(ProbeReport r) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('GATT 清单',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SelectableText(
              r.services.isEmpty
                  ? '（无）'
                  : r.services.map((s) {
                      final lines = <String>['服务 ${s.uuid}'];
                      for (final c in s.chars) {
                        lines.add('  ├ ${c.charUuid}');
                        lines.add('  │   属性: ${c.properties}');
                        if (c.descriptors.isNotEmpty) {
                          lines.add('  │   描述符: ${c.descriptors.join(", ")}');
                        }
                        if (c.canNotify) {
                          lines.add('  │   通知: ${c.notifyEnabled ? "已启用" : "未启用"}'
                              '${c.notifyError.isEmpty ? "" : " ($c.notifyError)"}');
                        }
                      }
                      return lines.join('\n');
                    }).join('\n\n'),
              style: const TextStyle(
                  fontSize: 10.5, fontFamily: 'monospace', height: 1.45),
            ),
          ],
        ),
      );

  Widget _logCard(ProbeReport r) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF14161A),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('时间线',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white)),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: SingleChildScrollView(
                child: SelectableText(
                  r.events.join('\n'),
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                    height: 1.5,
                    color: Color(0xFFD6E2F0),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}

/// Minimal scanner wrapper: only needs "found a device" callbacks.
class CardScannerProxy {
  StreamSubscription<List<ScanResult>>? _sub;

  void scan({required void Function(BluetoothDevice) onFound}) {
    stop();
    _sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        onFound(r.device);
      }
    });
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await FlutterBluePlus.stopScan();
  }
}
