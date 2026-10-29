import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:esim_ble/esim_ble.dart';

/// Capture screen for known-plaintext work on the LPAD secure channel.
///
/// The secure channel has so far been attacked from ciphertext only, which is
/// why every PSK candidate was a guess. This page sends two requests whose
/// plaintext is already known — the vendor's own AID constant and a reset —
/// and shows both directions byte-for-byte so they can be pasted into
/// `work/keystream.py`.
///
/// Nothing here writes the card: opening a logical channel and resetting the
/// interface do not touch installed profiles.
class KnownPlaintextScreen extends StatefulWidget {
  const KnownPlaintextScreen({super.key});

  @override
  State<KnownPlaintextScreen> createState() => _KnownPlaintextScreenState();
}

class _KnownPlaintextScreenState extends State<KnownPlaintextScreen> {
  final _log = <String>[];
  final _scanner = CardScanner();
  StreamSubscription<CardDevice>? _scanSub;
  final _devices = <CardDevice>[];
  String? _error;
  String? _paste;
  bool _running = false;
  bool _scanning = false;

  @override
  void dispose() {
    _scanSub?.cancel();
    _scanner.stop();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _devices.clear();
      _scanning = true;
      _error = null;
    });
    await _scanSub?.cancel();
    _scanSub = _scanner.scan().listen(
      (card) {
        if (!mounted) return;
        if (_devices.any((d) => d.id == card.id)) return;
        setState(() => _devices.add(card));
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _scanning = false;
          _error = '扫描失败：$e';
        });
      },
    );
    await Future<void>.delayed(const Duration(seconds: 8));
    await _stopScan();
  }

  Future<void> _stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    await _scanner.stop();
    if (mounted) setState(() => _scanning = false);
  }

  void _note(String line) {
    if (!mounted) return;
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    setState(() => _log.add(
        '[${two(now.hour)}:${two(now.minute)}:${two(now.second)}] $line'));
  }

  Future<void> _run(CardDevice card, {bool handshake = false}) async {
    setState(() {
      _running = true;
      _error = null;
      _paste = null;
      _log.clear();
    });
    LinksfieldTransport? transport;
    try {
      _note('连接 ${card.name}…');
      transport = await LinksfieldTransport.connect(card.device,
          replyTimeout: const Duration(seconds: 12));
      _note('已连接');

      final result = handshake
          ? await captureHandshake(transport, onProgress: _note)
          : await captureKnownPlaintext(transport, onProgress: _note);
      for (final line in result.fullReport.split('\n')) {
        if (line.trim().isNotEmpty) _note(line);
      }
      setState(() => _paste = result.pasteBlock);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      _note('失败：$e');
    } finally {
      try {
        await transport?.close();
      } catch (_) {}
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mono = const TextStyle(fontFamily: 'monospace', fontSize: 11);
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('已知明文抓取'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: '复制全部',
            icon: const Icon(Icons.copy, size: 20),
            onPressed: () {
              final text = [_log.join('\n'), ?_paste]
                  .where((s) => s.isNotEmpty)
                  .join('\n\n');
              if (text.isEmpty) return;
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制')));
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFBE6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              '这是只读抓取：打开逻辑通道 + 复位，不会下载/启用/删除任何套餐。\n'
              '目的：拿到一对「已知明文」的请求和响应，'
              '把安全通道的问题从「猜密码」变成「恢复 keystream」。',
              style: TextStyle(fontSize: 12, color: Color(0xFFAD6800)),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: (_scanning || _running) ? null : _scan,
            icon: const Icon(Icons.bluetooth_searching),
            label: Text(_scanning ? '扫描中…' : '扫描读卡器'),
          ),
          if (_devices.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('选择读卡器', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            for (final d in _devices)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.bluetooth, size: 18),
                title: Text(d.name, style: const TextStyle(fontSize: 13)),
                subtitle: Text('${d.id} · RSSI ${d.rssi}',
                    style: const TextStyle(fontSize: 11)),
                trailing: FilledButton(
                  onPressed: _running ? null : () => _run(d),
                  child: Text(_running ? '…' : '明文'),
                ),
              ),
          ],
          if (_devices.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.vpn_key, size: 15, color: Color(0xFF0958D9)),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    '要查「为什么握手不成」，跑完整握手：',
                    style: TextStyle(fontSize: 12, color: Color(0xFF0958D9)),
                  ),
                ),
                OutlinedButton(
                  onPressed:
                      _running ? null : () => _run(_devices.first, handshake: true),
                  child: Text(_running ? '…' : '完整握手'),
                ),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF1F0),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_error!,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFCF1322))),
            ),
          ],
          if (_paste != null) ...[
            const SizedBox(height: 16),
            const Text('贴进 work/keystream.py 的内容',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(10),
              color: const Color(0xFF10131A),
              child: SelectableText(
                _paste!,
                style: mono.copyWith(color: const Color(0xFFB7F7C2)),
              ),
            ),
          ],
          if (_log.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('日志',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(10),
              color: const Color(0xFF10131A),
              child: SelectableText(
                _log.join('\n'),
                style: mono.copyWith(color: const Color(0xFF9AD0F5)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
