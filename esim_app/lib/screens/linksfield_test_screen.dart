import 'package:esim_ble/esim_ble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Linksfield protocol test — the one path that actually sends a frame.
///
/// The read-only probe (`BleProbeScreen`) never writes to the device by design,
/// so it can only ever report "0 bytes". This screen exists to answer a single
/// question with evidence:
///
///     does the device reply to `08 00 12 02 08 01` (getDeviceInfo)?
///
/// Sequence: connect → wait connected → discoverServices → NUS pair →
/// notify → CCCD confirmed → requestMtu → send exactly one frame → wait.
///
/// Safety: one read-only request, no APDU, no logical channel, no retry. Nothing
/// on the card can change.
class LinksfieldTestScreen extends StatefulWidget {
  const LinksfieldTestScreen({super.key, required this.devices});

  final List<BluetoothDevice> devices;

  @override
  State<LinksfieldTestScreen> createState() => _LinksfieldTestScreenState();
}

class _LinksfieldTestScreenState extends State<LinksfieldTestScreen> {
  final _log = <String>[];
  bool _running = false;
  String? _result;
  bool _ok = false;

  void _append(String line) {
    if (!mounted) return;
    setState(() => _log.add(line));
  }

  Future<void> _run(BluetoothDevice device) async {
    setState(() {
      _running = true;
      _log.clear();
      _result = null;
      _ok = false;
      _log.add('设备: ${device.remoteId.str}  ${device.platformName}');
    });

    LinksfieldTransport? transport;
    try {
      _append('— 连接（connect / 服务发现 / CCCD / MTU）—');
      transport = await LinksfieldTransport.connect(device);
      // Replay the transport's own timeline, which records each gate.
      for (final line in transport.report.lines) {
        _append(line.toString());
      }

      _append('');
      _append('— 发送唯一一帧 getDeviceInfo —');
      final before = transport.report.lines.length;
      final info = await transport.probeDeviceInfo();
      for (final line in transport.report.lines.skip(before)) {
        _append(line.toString());
      }

      if (info != null) {
        setState(() {
          _ok = true;
          _result = '协议已识别！\n'
              '厂商: ${info.vendor}\n'
              '型号: ${info.deviceName}\n'
              '序列号: ${info.sn}\n'
              'SCARD 模式: ${info.scardMode}\n'
              '能力: ${info.ability.join(", ")}';
        });
      } else {
        setState(() {
          _ok = false;
          _result = '设备未返回设备信息\n'
              '原因: ${transport!.report.deviceInfoError ?? "未知"}';
        });
      }
    } catch (e) {
      _append('✗ 失败: $e');
      setState(() {
        _ok = false;
        _result = '初始化失败: $e';
      });
    } finally {
      try {
        await transport?.close();
      } catch (_) {}
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('Linksfield 协议测试'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: const [
                  Icon(Icons.memory, size: 18, color: Colors.blue),
                  SizedBox(width: 6),
                  Text('会发送 1 帧只读请求',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 6),
                Text(
                  '连接 → 服务发现 → TX notify → 等 CCCD → 请求 MTU → 发一次 '
                  'getDeviceInfo（08 00 12 02 08 01）。\n'
                  '不发 APDU、不开通道、不读写 Profile；失败不重试。',
                  style: TextStyle(fontSize: 12, color: Colors.grey[700], height: 1.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ...widget.devices.map((d) => Card(
                margin: const EdgeInsets.only(bottom: 8),
                elevation: 0,
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFEAF3FF),
                    child: Icon(Icons.bluetooth, size: 18),
                  ),
                  title: Text(
                    d.platformName.isEmpty ? '(未命名)' : d.platformName,
                    style: const TextStyle(fontSize: 14),
                  ),
                  subtitle: Text(d.remoteId.str,
                      style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                  trailing: FilledButton(
                    onPressed: _running ? null : () => _run(d),
                    child: Text(_running ? '运行中…' : '运行'),
                  ),
                ),
              )),
          if (_result != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _ok ? const Color(0xFFF6FFED) : const Color(0xFFFFF1F0),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: _ok ? const Color(0xFFB7EB8F) : const Color(0xFFFFCCC7)),
              ),
              child: SelectableText(
                _result!,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: _ok ? const Color(0xFF237804) : const Color(0xFFCF1322),
                ),
              ),
            ),
          ],
          if (_log.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF14161A),
                borderRadius: BorderRadius.circular(14),
              ),
              child: SelectableText(
                _log.join('\n'),
                style: const TextStyle(
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                  height: 1.5,
                  color: Color(0xFFD6E2F0),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
