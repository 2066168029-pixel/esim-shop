import 'dart:async';

import 'package:esim_ble/esim_ble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../theme.dart';
import 'ble_probe_screen.dart';
import 'linksfield_test_screen.dart';

/// Bluetooth eSIM card writer.
///
/// Three states in one page: scan for a card, inspect it, then write a profile
/// onto it. The card stays connected across operations so the user does not
/// have to re-pair between steps.
class CardWriterScreen extends StatefulWidget {
  const CardWriterScreen({super.key, this.onWrite});

  /// Called after a profile is written so the caller can refresh orders.
  final VoidCallback? onWrite;

  @override
  State<CardWriterScreen> createState() => _CardWriterScreenState();
}

class _CardWriterScreenState extends State<CardWriterScreen> {
  final _scanner = CardScanner();
  StreamSubscription<CardDevice>? _scanSub;

  final List<CardDevice> _cards = [];
  bool _scanning = false;
  String? _error;

  CardDevice? _selected;
  EuiccSession? _session;
  Lpa? _lpa;
  bool _connecting = false;

  /// Reader-side facts (name + EID) read straight off the card; the Linksfield
  /// device-info blob is no longer needed now that the card is read as a
  /// standard eUICC.
  String? _eid;
  String? _transportLabel;
  List<ProfileSummary> _profiles = [];

  final _codeController = TextEditingController();
  bool _writing = false;
  String? _progressText;
  DownloadStage? _stage;

  @override
  void dispose() {
    _scanSub?.cancel();
    _scanner.stop();
    _session?.close();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _toggleScan() async {
    if (_scanning) {
      await _stopScan();
      return;
    }

    setState(() {
      _cards.clear();
      _scanning = true;
      _error = null;
    });

    // A disabled radio throws deep inside the plugin; checking first turns that
    // into a readable message instead of a stack trace.
    try {
      final state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
        setState(() {
          _scanning = false;
          _error = '蓝牙未开启，请先打开蓝牙';
        });
        return;
      }
    } catch (_) {
      // Adapter check is best-effort; proceed and let the scan report errors.
    }

    _scanSub = _scanner.scan().listen(
      (card) {
        if (!mounted) return;
        setState(() {
          if (!_cards.any((c) => c.id == card.id)) _cards.add(card);
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _error = '扫描失败：$e';
          _scanning = false;
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _scanning = false);
      },
    );
  }

  Future<void> _stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    await _scanner.stop();
    if (mounted) setState(() => _scanning = false);
  }

  // ------------------------------------------------------------- diagnostics

  /// Log shown in the "诊断" sheet, newest last.
  final _diagLog = <String>[];

  /// Reader handle captured by [_diagnose], so the sheet can send raw text.
  Esim9BleTransport? _diagReader;

  /// Pairing code from the last prompt, reused so the bond step does not ask
  /// twice in one session.
  String? _lastPin;

  void _log(String message) {
    if (!mounted) return;
    setState(() => _diagLog.add(message));
  }

  /// Runs the full reader bring-up against [card] and shows every step.
  ///
  /// This exists because a silent BLE device is indistinguishable from a wrong
  /// protocol from the outside: both look like "no answer". The log tells us
  /// whether the link, the service, the JSON protocol or the card failed.
  Future<void> _diagnose(CardDevice card) async {
    await _stopScan();
    setState(() {
      _diagLog
        ..clear()
        ..add('设备: ${card.name}  ${card.id}');
    });

    // A card that needs pairing has to be bonded *before* the link is opened,
    // otherwise the first connect races the OS dialog and dies with
    // "device is disconnected". Ask once, up front, and reuse the answer.
    if (_lastPin == null) {
      final pin = await _askPin(card);
      if (pin != null && pin.isNotEmpty) _lastPin = pin;
    }

    // 1. 9eSIM path: connect, ask for a JSON reply, then ask what it is.
    final probe = await diagnoseReader(card.device, onStep: _log, pin: _lastPin);
    _diagReader = probe.reader;
    if (probe.answered) {
      _log('— 读卡器识别 —');
      for (final line in await probe.reader!.identify()) {
        _log(line);
      }

      _log('— 打开 eUICC 会话 —');
      try {
        final session = EuiccSession(probe.reader!);
        await session.open();
        _log('ISD-R 已选中，通道 ${session.channel}');
        final lpa = Lpa(session);
        _log('EID: ${await lpa.readEid()}');
        final profiles = await lpa.listProfiles();
        _log('卡内套餐: ${profiles.length} 个');
        for (final p in profiles) {
          _log('  • ${p.iccid} ${p.isEnabled ? "(已启用)" : ""} '
              '${p.profileName.isEmpty ? p.nickname : p.profileName}');
        }
        setState(() {
          _session = session;
          _lpa = lpa;
          _transportLabel = '9esim-ble';
          _selected = card;
        });
        await _refreshProfiles();
        _log('✓ 9eSIM 链路正常');
      } catch (e) {
        _log('✗ 会话打开失败: $e');
      }
      return;
    }

    // 2. Linksfield path: pair with the printed code, then talk protobuf.
    _log('— 尝试 Linksfield 协议 —');
    final pin = await _askPin(card);
    if (pin == null) {
      _log('已取消输入配对密码');
      return;
    }
    try {
      // Read-only verification: correct notify/CCCD/MTU ordering, then exactly
      // one getDeviceInfo frame. No APDU, no logical channel, no profile op.
      final transport = await LinksfieldTransport.connect(card.device);
      _transportLabel = 'linksfield-ble';
      _selected = card;

      var shown = 0;
      for (final line in transport.report.lines) {
        _log(line.text);
        shown++;
      }

      _log('— 发送只读 getDeviceInfo (08 00 12 02 08 01) —');
      final info = await transport.probeDeviceInfo();
      for (final line in transport.report.lines.skip(shown)) {
        _log(line.text);
      }

      if (info != null) {
        _log('✓ Linksfield 协议已识别');
        _log('  厂商: ${info.vendor}');
        _log('  型号: ${info.deviceName}');
        _log('  序列号: ${info.sn}');
        if (info.ability.isNotEmpty) {
          _log('  能力: ${info.ability.join(", ")}');
        }
      } else {
        _log('⚠ 未收到设备信息: ${transport.report.deviceInfoError ?? "无响应"}');
        _log('  本次不重试，也不发送任何其它命令。');
        _log('  若日志显示 CCCD/MTU 正常而设备沉默，下一步应检查配对状态。');
      }
    } catch (e) {
      _log('✗ Linksfield 初始化失败: $e');
      _log('');
      _log('可能原因：');
      _log('· 读卡器没电 / 卡没插好');
      _log('· 服务发现或 CCCD 阶段被系统打断');
      _log('· 手机与读卡器之间被别的 App 占用');
    }
  }

  /// The pairing code printed on a Linksfield card.
  Future<String?> _askPin(CardDevice card) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('蓝牙配对密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(card.name,
                style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '卡片上印的密码，如 180651；不知道就留空',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (v) => Navigator.pop(c, v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, controller.text.trim()),
            child: const Text('连接'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return null;
    if (result.isNotEmpty) _lastPin = result;
    return result;
  }

  Future<void> _connect(CardDevice card) async {
    await _stopScan();
    setState(() {
      _selected = card;
      _connecting = true;
      _error = null;
      _profiles = [];
      _eid = null;
      _transportLabel = null;
    });

    try {
      // One connection path for every reader: probe which protocol the device
      // speaks (9eSIM board -> plain APDUs, Linksfield -> protobuf bridge),
      // then drive it through the same SGP.22 engine.
      final transport = await openAnyTransport(card.device);
      final session = EuiccSession(transport);
      await session.open();

      // EID confirms we are talking to a real eUICC and gives the UI something
      // to show besides the BLE name.
      String? eid;
      try {
        eid = await Lpa(session).readEid();
      } catch (_) {
        // EID is nice-to-have; some cards hide it until ISD-R is selected.
      }

      if (!mounted) return;
      setState(() {
        _session = session;
        _lpa = Lpa(session);
        _eid = eid;
        _transportLabel = transport.kind;
        _connecting = false;
      });
      await _refreshProfiles();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _error = '连接失败：$e';
      });
    }
  }

  Future<void> _refreshProfiles() async {
    final lpa = _lpa;
    if (lpa == null) return;
    try {
      final list = await lpa.listProfiles();
      if (!mounted) return;
      setState(() => _profiles = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '读取套餐列表失败：$e');
    }
  }

  Future<void> _writeProfile() async {
    final card = _selected;
    final code = ActivationCode.tryParse(_codeController.text);
    if (card == null || code == null) {
      setState(() => _error = '激活码格式不正确，应形如 LPA:1\$主机\$匹配码');
      return;
    }

    setState(() {
      _writing = true;
      _error = null;
      _progressText = '准备下载…';
      _stage = DownloadStage.connecting;
    });

    try {
      final result = await ProfileDownloader.connect(
        card.device,
        code,
        onProgress: (stage, detail) {
          if (!mounted) return;
          setState(() {
            _stage = stage;
            _progressText = detail;
          });
        },
      );

      if (!mounted) return;
      setState(() {
        _writing = false;
        _progressText =
            '写入完成${result.iccid.isEmpty ? '' : '，ICCID ${result.iccid}'}';
        _codeController.clear();
      });
      widget.onWrite?.call();

      // The download path closes the connection, so reconnect to refresh.
      await _connect(card);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _writing = false;
        _error = '写卡失败：$e';
      });
    }
  }

  Future<void> _profileAction(
      String label, Future<void> Function(Lpa lpa) action) async {
    final lpa = _lpa;
    if (lpa == null) return;
    try {
      await action(lpa);
      await _refreshProfiles();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$label 成功')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$label 失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('蓝牙写卡'),
        backgroundColor: Colors.white,
        foregroundColor: AppColors.text,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: '诊断',
            icon: const Icon(Icons.terminal, size: 20),
            onPressed: _showDiagSheet,
          ),
          IconButton(
            tooltip: 'Linksfield 协议测试',
            icon: const Icon(Icons.memory, size: 20),
            onPressed: _showLinksfieldTest,
          ),
          IconButton(
            tooltip: '只读 BLE 诊断',
            icon: const Icon(Icons.bluetooth, size: 20),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BleProbeScreen()),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null) _errorCard(_error!),
          if (_session == null) ..._buildScanSection(),
          if (_connecting)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            ),
          if (_session != null) ..._buildCardSection(),
        ],
      ),
    );
  }

  Widget _errorCard(String message) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF1F0),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFFCCC7)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline, color: Color(0xFFCF1322), size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: Color(0xFFCF1322), fontSize: 13),
              ),
            ),
          ],
        ),
      );

  List<Widget> _buildScanSection() {
    return [
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '连接写卡器',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              '请先给蓝牙 eSIM 卡通电，然后点击扫描',
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _toggleScan,
                icon: Icon(_scanning ? Icons.stop : Icons.bluetooth_searching),
                label: Text(_scanning ? '停止扫描' : '扫描设备'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            if (_scanning)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(minHeight: 2),
              ),
          ],
        ),
      ),
      if (_cards.isNotEmpty) ...[
        const SizedBox(height: 16),
        ..._cards.map(_cardTile),
      ] else if (_scanning) ...[
        const SizedBox(height: 32),
        Center(
          child: Text(
            '正在搜索附近的写卡器…',
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
        ),
      ],
    ];
  }

  Widget _cardTile(CardDevice card) => Card(
        margin: const EdgeInsets.only(bottom: 8),
        elevation: 0,
        child: ListTile(
          leading: const CircleAvatar(
            backgroundColor: Color(0xFFEAF3FF),
            child: Icon(Icons.memory, color: AppColors.primary),
          ),
          title: Text(card.name, style: const TextStyle(fontSize: 14)),
          subtitle: Text(
            card.id,
            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
          ),
          trailing: Text(
            '${card.rssi} dBm',
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
          onTap: () => _connect(card),
          // Long-press runs the full trace instead of the one-shot connect:
          // when a device stays silent this is what tells us which layer broke.
          onLongPress: () => _diagnose(card),
        ),
      );

  /// Opens the Linksfield protocol test (connect → CCCD → MTU → one
  /// getDeviceInfo). Different from the read-only probe: this one *does* send a
  /// single read-only frame, which is the only way to learn whether the device
  /// answers the protocol at all.
  void _showLinksfieldTest() {
    if (_cards.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先扫描一次，让设备出现在列表里')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LinksfieldTestScreen(devices: _cards.map((c) => c.device).toList()),
      ),
    );
  }

  /// Bottom sheet with the diagnostic log plus a raw-input box.
  void _showDiagSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (c) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(c).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('读卡器诊断',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                child: SelectableText(
                  _diagLog.isEmpty ? '（还没有日志）' : _diagLog.join('\n'),
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    height: 1.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _RawCommandRow(onSend: (text) async {
              final reader = _diagReader;
              if (reader == null) {
                _log('还没连上读卡器');
                return;
              }
              try {
                final reply = await reader.rawRoundTrip(text);
                _log('> $text\n< $reply');
              } catch (e) {
                _log('> $text\n(无回应: $e)');
              }
            }),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildCardSection() {
    return [
      Container(
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
                const Icon(Icons.check_circle,
                    color: Color(0xFF52C41A), size: 18),
                const SizedBox(width: 6),
                Text(
                  _selected?.name ?? '已连接',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    await _session?.close();
                    setState(() {
                      _session = null;
                      _lpa = null;
                      _selected = null;
                      _profiles = [];
                      _eid = null;
                      _transportLabel = null;
                    });
                  },
                  child: const Text('断开'),
                ),
              ],
            ),
            if (_transportLabel != null) ...[
              const SizedBox(height: 8),
              _kv('读卡器', switch (_transportLabel) {
                '9esim-ble' => '9eSIM 蓝牙读卡器',
                'linksfield-ble' => 'Linksfield 蓝牙卡',
                _ => _transportLabel!,
              }),
              if (_eid != null && _eid!.isNotEmpty) _kv('EID', _eid!),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '写入新套餐',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _codeController,
              enabled: !_writing,
              maxLines: 2,
              minLines: 1,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                hintText: 'LPA:1\$主机地址\$匹配码',
                hintStyle: TextStyle(fontSize: 12),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _writing ? null : _writeProfile,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _writing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('开始写卡'),
              ),
            ),
            if (_writing && _progressText != null) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: _stage == null ? null : _stageFraction(_stage!),
                minHeight: 3,
              ),
              const SizedBox(height: 6),
              Text(
                _progressText!,
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
            if (!_writing && _progressText != null) ...[
              const SizedBox(height: 10),
              Text(
                _progressText!,
                style: const TextStyle(fontSize: 12, color: Color(0xFF52C41A)),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),
      Container(
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
                const Text(
                  '卡内套餐',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  onPressed: _refreshProfiles,
                  icon: const Icon(Icons.refresh, size: 18),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            if (_profiles.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '暂无套餐',
                  style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                ),
              )
            else
              ..._profiles.map(_profileTile),
          ],
        ),
      ),
    ];
  }

  Widget _profileTile(ProfileSummary p) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: p.isEnabled
                        ? const Color(0xFFE6F7E6)
                        : const Color(0xFFF0F0F0),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    p.isEnabled ? '已启用' : '未启用',
                    style: TextStyle(
                      fontSize: 10,
                      color: p.isEnabled
                          ? const Color(0xFF389E0D)
                          : Colors.grey[600],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    p.profileName.isNotEmpty ? p.profileName : p.nickname,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'ICCID ${p.iccid}',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey[500],
                fontFamily: 'monospace',
              ),
            ),
            if (p.serviceProvider.isNotEmpty)
              Text(
                p.serviceProvider,
                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
              ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                if (!p.isEnabled)
                  _miniAction(
                    '启用',
                    () => _profileAction(
                      '启用',
                      (l) => l.enableProfile(p.iccid),
                    ),
                  ),
                if (p.isEnabled)
                  _miniAction(
                    '停用',
                    () => _profileAction(
                      '停用',
                      (l) => l.disableProfile(p.iccid),
                    ),
                  ),
                _miniAction('删除', () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('删除套餐'),
                      content: Text('确定删除 ${p.iccid}？此操作不可撤销。'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(c, false),
                          child: const Text('取消'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text(
                            '删除',
                            style: TextStyle(color: Color(0xFFCF1322)),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) {
                    await _profileAction(
                      '删除',
                      (l) => l.deleteProfile(p.iccid),
                    );
                  }
                }),
              ],
            ),
          ],
        ),
      );

  Widget _miniAction(String label, VoidCallback onTap) => InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFDDDDDD)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(label, style: const TextStyle(fontSize: 11)),
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 60,
              child: Text(
                k,
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),
            ),
            Expanded(
              child: Text(v, style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );

  double _stageFraction(DownloadStage stage) {
    switch (stage) {
      case DownloadStage.connecting:
        return 0.05;
      case DownloadStage.readingCard:
        return 0.15;
      case DownloadStage.initiateAuthentication:
        return 0.3;
      case DownloadStage.authenticateServer:
        return 0.45;
      case DownloadStage.authenticateClient:
        return 0.55;
      case DownloadStage.prepareDownload:
        return 0.65;
      case DownloadStage.getBoundProfilePackage:
        return 0.75;
      case DownloadStage.loadBoundProfilePackage:
        return 0.9;
      case DownloadStage.done:
        return 1.0;
      case DownloadStage.failed:
        return 0.0;
    }
  }
}

/// A text field that sends one raw line to the reader and keeps its history.
///
/// Lives at the bottom of the diagnostics sheet: it is the escape hatch when a
/// device speaks a protocol we did not anticipate.
class _RawCommandRow extends StatefulWidget {
  const _RawCommandRow({required this.onSend});

  final Future<void> Function(String text) onSend;

  @override
  State<_RawCommandRow> createState() => _RawCommandRowState();
}

class _RawCommandRowState extends State<_RawCommandRow> {
  final _controller = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text;
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(text);
      _controller.clear();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            enabled: !_sending,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              hintText: '发送原始命令，如 help 或 {"cmd":"getElpaInfo"}',
              hintStyle: TextStyle(fontSize: 11),
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _send(),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _sending ? null : _send,
          child: const Text('发送'),
        ),
      ],
    );
  }
}
