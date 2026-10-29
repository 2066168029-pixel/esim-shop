import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../ble_selfcheck.dart';

/// Self-check page for the Bluetooth write path.
///
/// One read-only request per link of the chain (link → notify → framing →
/// secure channel → ES10b → ES10c), so a failure names the link that broke
/// instead of just "写卡失败". Every line can be copied as text, because a
/// screenshot of a log is what actually gets debugged later.
class BleSelfCheckScreen extends StatefulWidget {
  const BleSelfCheckScreen({super.key});

  @override
  State<BleSelfCheckScreen> createState() => _BleSelfCheckScreenState();
}

class _BleSelfCheckScreenState extends State<BleSelfCheckScreen> {
  StreamSubscription<BluetoothDevice>? _scanSub;
  StreamSubscription<List<ScanResult>>? _resultSub;

  final _devices = <BluetoothDevice>[];
  bool _scanning = false;
  bool _running = false;
  String? _error;
  SelfCheckResult? _result;
  BluetoothDevice? _lastDevice;
  final _log = <String>[];

  @override
  void dispose() {
    _scanSub?.cancel();
    _resultSub?.cancel();
    _stopScan();
    super.dispose();
  }

  void _note(String line) {
    if (!mounted) return;
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    setState(() => _log.add(
        '[${two(now.hour)}:${two(now.minute)}:${two(now.second)}] $line'));
  }

  Future<void> _stopScan() async {
    try {
      if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
    } catch (_) {}
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _startScan() async {
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
          _error = '蓝牙没打开';
        });
        return;
      }
    } catch (_) {}

    _resultSub = FlutterBluePlus.onScanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        for (final r in results) {
          if (!_devices.any((d) => d.remoteId == r.device.remoteId)) {
            _devices.add(r.device);
          }
        }
      });
    });
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
    await Future.delayed(const Duration(seconds: 12));
    await _resultSub?.cancel();
    _resultSub = null;
    await _stopScan();
  }

  Future<void> _run(BluetoothDevice device) async {
    if (_running) return;
    await _stopScan();
    setState(() {
      _running = true;
      _lastDevice = device;
      _result = null;
      _log.clear();
    });

    final name = device.platformName.isNotEmpty
        ? device.platformName
        : device.remoteId.str;
    _note('开始自检：$name');

    try {
      final result = await runSelfCheck(
        device,
        onProgress: (r) {
          if (!mounted) return;
          setState(() => _result = r);
        },
        timeout: const Duration(seconds: 15),
      );
      if (!mounted) return;
      setState(() => _result = result);
      for (final s in result.steps) {
        _note('${s.icon} ${s.title}${s.detail.isEmpty ? "" : "：${s.detail}"}');
      }
      if (result.blockingIssue != null) {
        _note('结论：${result.blockingIssue}');
      } else if (result.allPassed) {
        _note('结论：链路完全可用，可以直接写卡');
      }
    } catch (e, st) {
      _note('自检异常：$e');
      if (!mounted) return;
      setState(() => _error = '$e');
      debugPrintStack(stackTrace: st);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// Releases the card so the write page can connect to it.
  Future<void> _release() async {
    await _result?.session?.close();
    if (!mounted) return;
    setState(() => _result = null);
    _note('已释放卡片连接');
  }

  String _report() {
    final b = StringBuffer();
    b.writeln('OnlyLink eSIM 写卡自检');
    b.writeln('设备：${_lastDevice?.platformName} ${_lastDevice?.remoteId.str}');
    final r = _result;
    if (r != null) {
      for (final s in r.steps) {
        b.writeln('${s.icon} ${s.title}：${s.state.name}'
            '${s.detail.isEmpty ? "" : " — ${s.detail}"}');
      }
      if (r.blockingIssue != null) b.writeln('blocking=${r.blockingIssue}');
      if (r.eid.isNotEmpty) b.writeln('EID=${r.eid}');
      for (final p in r.profiles) {
        b.writeln('profile ${p.iccid} ${p.isEnabled ? "enabled" : "disabled"}');
      }
    }
    b.writeln('--- 日志 ---');
    b.writeln(_log.join('\n'));
    return b.toString();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _report()));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已复制自检报告')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('写卡自检'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: '复制报告',
            onPressed: _log.isEmpty && _result == null ? null : _copy,
            icon: const Icon(Icons.copy_all, size: 20),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null) _banner(_error!, const Color(0xFFFFF1F0), const Color(0xFFCF1322)),
          _scanCard(),
          if (_devices.isNotEmpty) ...[
            const SizedBox(height: 12),
            ..._devices.map(_deviceTile),
          ],
          if (_result != null) ...[
            const SizedBox(height: 16),
            _stepsCard(_result!),
          ],
          if (_log.isNotEmpty) ...[
            const SizedBox(height: 16),
            _logCard(),
          ],
        ],
      ),
    );
  }

  Widget _banner(String text, Color bg, Color fg) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: TextStyle(color: fg, fontSize: 13, height: 1.4)),
      );

  Widget _scanCard() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('1. 扫描读卡器',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text('给卡通电后点扫描；自检只读，不会写卡或改卡',
                style: TextStyle(fontSize: 13, color: Colors.grey[600])),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _running ? null : (_scanning ? _stopScan : _startScan),
                icon: Icon(_scanning ? Icons.stop : Icons.bluetooth_searching),
                label: Text(_scanning ? '停止扫描' : '扫描'),
              ),
            ),
            if (_scanning)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(minHeight: 2),
              ),
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
            d.platformName.isNotEmpty ? d.platformName : '(无名称)',
            style: const TextStyle(fontSize: 14),
          ),
          subtitle: Text(d.remoteId.str,
              style: TextStyle(fontSize: 11, color: Colors.grey[500])),
          trailing: _running
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow, size: 20),
          onTap: _running ? null : () => _run(d),
        ),
      );

  Widget _stepsCard(SelfCheckResult r) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('2. 自检结果',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const Spacer(),
                if (r.session != null)
                  TextButton(onPressed: _release, child: const Text('释放连接')),
              ],
            ),
            const SizedBox(height: 8),
            ...r.steps.map(_stepRow),
            if (r.blockingIssue != null) ...[
              const SizedBox(height: 8),
              _banner(r.blockingIssue!, const Color(0xFFFFF1F0),
                  const Color(0xFFCF1322)),
            ] else if (!_running && r.allPassed) ...[
              const SizedBox(height: 8),
              _banner('链路完全可用：可以回到「蓝牙写卡」直接写入。',
                  const Color(0xFFF6FFED), const Color(0xFF389E0D)),
            ],
            if (r.profiles.isNotEmpty) ...[
              const Divider(height: 24),
              for (final p in r.profiles)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Icon(
                        p.isEnabled
                            ? Icons.check_circle_outline
                            : Icons.radio_button_unchecked,
                        size: 16,
                        color: p.isEnabled
                            ? const Color(0xFF52C41A)
                            : Colors.grey[400],
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${p.profileName.isNotEmpty ? p.profileName : p.nickname} '
                          '· ${p.iccid}',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey[700]),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      );

  Widget _stepRow(SelfCheckStep s) {
    Color color;
    switch (s.state) {
      case SelfCheckState.pass:
        color = const Color(0xFF52C41A);
      case SelfCheckState.fail:
        color = const Color(0xFFCF1322);
      case SelfCheckState.warn:
        color = const Color(0xFFFA8C16);
      case SelfCheckState.running:
        color = const Color(0xFF1677FF);
      default:
        color = Colors.grey;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            child: s.state == SelfCheckState.running
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(s.icon,
                    style: TextStyle(
                        color: color, fontWeight: FontWeight.bold, fontSize: 15)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                Text(
                  s.detail.isEmpty ? s.meaning : s.detail,
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _logCard() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('日志',
                style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            SelectableText(
              _log.join('\n'),
              style: const TextStyle(
                  color: Color(0xFF9AE6B4),
                  fontSize: 11,
                  height: 1.5,
                  fontFamily: 'monospace'),
            ),
          ],
        ),
      );
}
