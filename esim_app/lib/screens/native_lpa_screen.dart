import 'dart:async';

import 'package:flutter/material.dart';

import '../native_lpa.dart';
import '../theme.dart';
import 'scan_screen.dart';

/// iOS 写卡页，走 Linksfield eSIMManagerSDK（原生 Swift 二进制）。
///
/// 界面按安卓端「写入 eSIM」的三步向导重排：选择读卡器 -> 激活码 -> 写卡，
/// 下方是可展开的已装 profile 管理。底层全部仍走原生 SDK 通道，
/// 与 CardWriterScreenV2 的纯 Dart 实现互不影响。
///
/// SDK 只有 arm64 真机切片，模拟器上桥接不编译，此时退化成说明页。
class NativeLpaScreen extends StatefulWidget {
  const NativeLpaScreen({super.key});

  @override
  State<NativeLpaScreen> createState() => _NativeLpaScreenState();
}

class _NativeLpaScreenState extends State<NativeLpaScreen> {
  bool? _available;

  StreamSubscription<NativeLpaDevice>? _scanSub;
  StreamSubscription<NativeLpaConnectionState>? _stateSub;
  StreamSubscription<Map<String, dynamic>>? _notifySub;

  final List<NativeLpaDevice> _devices = [];
  bool _scanning = false;

  NativeLpaDevice? _selected;
  NativeLpaConnectionState _connState = NativeLpaConnectionState.disconnected;
  bool _busy = false;
  String? _eid;
  List<NativeLpaProfile> _profiles = [];
  String? _message;
  double? _progress;
  bool _moreOpen = false;

  final _codeController = TextEditingController();
  final _confirmController = TextEditingController();

  bool get _connected =>
      _connState == NativeLpaConnectionState.connected && _eid != null;

  @override
  void initState() {
    super.initState();
    _checkAvailability();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _stateSub?.cancel();
    _notifySub?.cancel();
    NativeLpa.stopScan().catchError((Object _) {});
    _codeController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 原生调用（逻辑与改造前一致，只换了界面）
  // ---------------------------------------------------------------------------

  Future<void> _checkAvailability() async {
    final ok = await NativeLpa.isAvailable;
    if (!mounted) return;
    setState(() => _available = ok);
  }

  Future<void> _toggleScan() async {
    if (_scanning) {
      await _scanSub?.cancel();
      _scanSub = null;
      await NativeLpa.stopScan().catchError((Object _) {});
      if (mounted) setState(() => _scanning = false);
      return;
    }

    setState(() {
      _scanning = true;
      _devices.clear();
      _message = null;
    });

    _scanSub?.cancel();
    _scanSub = NativeLpa.scan().listen(
      (d) {
        if (!mounted) return;
        if (_devices.any((x) => x.id == d.id)) return;
        setState(() => _devices.add(d));
      },
      onError: (Object e) {
        if (mounted) setState(() => _message = '扫描出错：$e');
      },
      onDone: () {
        if (mounted) setState(() => _scanning = false);
      },
    );
  }

  Future<void> _connect(NativeLpaDevice d) async {
    setState(() {
      _busy = true;
      _selected = d;
      _message = '正在连接 ${d.name}…';
    });
    try {
      final ok = await NativeLpa.connect(d.id);
      if (!mounted) return;
      if (!ok) {
        setState(() => _message = '连接失败，请确认读卡器已通电并靠近手机');
        return;
      }
      _stateSub?.cancel();
      _stateSub = NativeLpa.connectionStates.listen((s) {
        if (!mounted) return;
        setState(() => _connState = s);
      });
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _message = '连接异常：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    _stateSub?.cancel();
    _stateSub = null;
    await NativeLpa.disconnect().catchError((Object _) {});
    if (!mounted) return;
    setState(() {
      _selected = null;
      _eid = null;
      _profiles = [];
      _connState = NativeLpaConnectionState.disconnected;
      _message = null;
    });
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      final eid = await NativeLpa.getEid();
      if (!mounted) return;
      setState(() => _eid = eid);
      if (eid == null || eid.isEmpty) {
        setState(() => _message = '读取 EID 失败，请重试');
        return;
      }
      final r = await NativeLpa.getProfiles();
      if (!mounted) return;
      setState(() {
        _profiles = r.profiles;
        _message = null;
      });    } catch (e) {
      if (mounted) setState(() => _message = '读取卡片信息失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _message = '请先填写激活码');
      return;
    }
    if (!_connected) {
      setState(() => _message = '请先在第 1 步连接读卡器');
      return;
    }

    setState(() {
      _busy = true;
      _progress = null;
      _message = '正在写卡，请勿断开读卡器…';
    });

    try {
      var r = await NativeLpa.download(code);
      if (!mounted) return;

      // -2 表示运营商要求确认码，弹窗补一次
      if (!r.ok && r.needConfirm) {
        final confirm = await _askConfirmCode();
        if (confirm == null) {
          setState(() {
            _busy = false;
            _message = '已取消';
          });
          return;
        }
        r = await NativeLpa.download(code, confirmationCode: confirm);
        if (!mounted) return;
      }

      setState(() {
        _message = r.ok ? '写卡成功' : '写卡失败（错误码 ${r.result}）';
      });
      if (r.ok) {
        _codeController.clear();
        _confirmController.clear();
        await _refresh();
      }
    } catch (e) {
      if (mounted) setState(() => _message = '写卡异常：$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<String?> _askConfirmCode() async {
    final c = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '运营商要求输入确认码才能继续。',
              style: TextStyle(fontSize: 12, color: AppColors.muted),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: c,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '确认码',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    c.dispose();
    return v;
  }

  Future<void> _runOp(String label, Future<NativeLpaResult> Function() op) async {
    setState(() {
      _busy = true;
      _message = '$label…';
    });
    try {
      final r = await op();
      if (!mounted) return;
      setState(() => _message = r.ok ? '$label成功' : '$label失败（错误码 ${r.result}）');
      if (r.ok) await _refresh();
    } catch (e) {
      if (mounted) setState(() => _message = '$label异常：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onProfileAction(String action, NativeLpaProfile p) {
    switch (action) {
      case 'enable':
        _runOp('启用', () => NativeLpa.enable(p.iccid));
        break;
      case 'disable':
        _runOp('停用', () => NativeLpa.disable(p.iccid));
        break;
      case 'delete':
        _confirmDelete(p);
        break;
      case 'rename':
        _askRename(p);
        break;
    }
  }

  Future<void> _confirmDelete(NativeLpaProfile p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 profile'),
        content: Text('确定删除 ${p.serviceProviderName} (${p.iccid})？\n删除后需重新写卡。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _runOp('删除', () => NativeLpa.delete(p.iccid));
    }
  }

  Future<void> _askRename(NativeLpaProfile p) async {
    final c = TextEditingController(text: p.nickname);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    c.dispose();
    if (name != null && name.isNotEmpty) {
      await _runOp('重命名', () => NativeLpa.setNickname(p.iccid, name));
    }
  }

  // ---------------------------------------------------------------------------
  // 界面
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('写入 eSIM'),
        backgroundColor: Colors.white,
        foregroundColor: AppColors.text,
        elevation: 0.5,
      ),
      body: _available == null
          ? const Center(child: CircularProgressIndicator())
          : (_available! ? _buildWizard() : _buildUnavailable()),
    );
  }

  Widget _buildUnavailable() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.bluetooth_disabled, size: 56, color: AppColors.muted),
            const SizedBox(height: 16),
            const Text(
              '当前环境不支持原生写卡',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            const Text(
              '原生 SDK 只提供真机 arm64 切片，模拟器上不可用。\n请使用 Dart 传输流程，或换真机运行。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.muted, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWizard() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _step(
          index: 1,
          title: '选择读卡器',
          hint: '给卡通电后扫描，点一下即可连接',
          child: _step1Scanner(),
        ),
        const SizedBox(height: 14),
        _step(
          index: 2,
          title: '激活码',
          hint: '粘贴或扫码；二维码印在供应商给的卡上',
          child: _step2Code(),
        ),
        const SizedBox(height: 14),
        _step(
          index: 3,
          title: '写卡',
          hint: _connected ? '已连接 ${_selected?.name ?? ''}' : '先在第 1 步连上读卡器',
          child: _step3Write(),
        ),
        if (_message != null) ...[
          const SizedBox(height: 14),
          _messageCard(),
        ],
        const SizedBox(height: 18),
        _moreSection(),
      ],
    );
  }

  // ----- 步骤 1 -----

  Widget _step1Scanner() {
    final label = _selected?.name ??
        (_devices.isEmpty ? '尚未发现设备' : '发现 ${_devices.length} 个设备');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: _connected ? AppColors.success : AppColors.muted,
                  fontWeight: _connected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
            if (_connected)
              TextButton(
                onPressed: _busy ? null : _disconnect,
                child: const Text('断开'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _busy ? null : _toggleScan,
          icon: Icon(_scanning ? Icons.stop : Icons.bluetooth_searching),
          label: Text(_scanning ? '停止扫描' : '扫描蓝牙读卡器'),
        ),
        if (_devices.isNotEmpty && !_connected) ...[
          const SizedBox(height: 8),
          ..._devices.map(_deviceTile),
        ],
      ],
    );
  }

  Widget _deviceTile(NativeLpaDevice d) {
    final busyThis = _busy && _selected?.id == d.id;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.credit_card, color: AppColors.primary),
        title: Text(
          d.name,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${d.mac.isNotEmpty ? d.mac : d.id.substring(0, d.id.length > 8 ? 8 : d.id.length)}'
          ' · ${d.rssi} dBm',
          style: const TextStyle(fontSize: 11),
        ),
        trailing: busyThis
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.chevron_right, size: 20),
        onTap: _busy ? null : () => _connect(d),
      ),
    );
  }

  // ----- 步骤 2 -----

  Widget _step2Code() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _codeController,
          maxLines: 3,
          minLines: 2,
          style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          decoration: const InputDecoration(
            labelText: 'LPA: 激活码',
            hintText: r'LPA:1$SMDP.EXAMPLE.COM$MATCHING-ID',
            hintStyle: TextStyle(fontSize: 12),
            border: OutlineInputBorder(),
            isDense: true,
            contentPadding: EdgeInsets.all(12),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _scanQr,
                icon: const Icon(Icons.qr_code_scanner, size: 18),
                label: const Text('扫码'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : _askConfirmOptional,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                child: Text(
                  _confirmController.text.isEmpty ? '确认码（可选）' : '确认码已填',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _scanQr() async {
    // 复用项目里现有的真扫码页（flutter_zxing，带摄像头）。
    // 它会把 LPA: 开头的串原样返回。
    final code = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const ScanScreen()),
    );
    if (code != null && code.isNotEmpty && mounted) {
      setState(() => _codeController.text = code.trim());
    }
  }

  Future<void> _askConfirmOptional() async {
    final c = TextEditingController(text: _confirmController.text);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '部分运营商需要额外确认码，没有就留空。',
              style: TextStyle(fontSize: 12, color: AppColors.muted),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: c,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '确认码',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    c.dispose();
    if (v != null && mounted) {
      setState(() => _confirmController.text = v);
    }
  }

  // ----- 步骤 3 -----

  Widget _step3Write() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: (_busy || !_connected) ? null : _download,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.download),
          label: Text(_busy ? '写卡中…' : '开始写卡'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            disabledBackgroundColor: AppColors.border,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        if (_progress != null) ...[
          const SizedBox(height: 10),
          LinearProgressIndicator(value: _progress),
        ],
      ],
    );
  }

  // ----- 消息条 -----

  Widget _messageCard() {
    final isErr = _message!.contains('失败') || _message!.contains('异常');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isErr ? const Color(0xFFFEF2F2) : const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isErr ? AppColors.danger.withValues(alpha: 0.4) : AppColors.success.withValues(alpha: 0.4),
        ),
      ),
      child: Text(
        _message!,
        style: TextStyle(
          fontSize: 12,
          color: isErr ? AppColors.danger : const Color(0xFF15803D),
        ),
      ),
    );
  }

  // ----- 更多功能 -----

  Widget _moreSection() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _moreOpen = !_moreOpen),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Text(
                    '更多功能',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _connected ? '已装 ${_profiles.length} 个 profile' : '需先连接读卡器',
                      style: const TextStyle(fontSize: 12, color: AppColors.muted),
                    ),
                  ),
                  Icon(
                    _moreOpen ? Icons.expand_less : Icons.expand_more,
                    color: AppColors.muted,
                  ),
                ],
              ),
            ),
          ),
          if (_moreOpen) ...[
            const Divider(height: 1),
            if (!_connected)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '连接读卡器后可查看 EID、管理已装 profile',
                  style: TextStyle(fontSize: 12, color: AppColors.muted),
                ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv('设备', _selected?.name ?? '-'),
                    _kv('EID', _eid ?? '-'),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy ? null : _refresh,
                        child: const Text('刷新 profile'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy ? null : _disconnect,
                        child: const Text('断开'),
                      ),
                    ),
                  ],
                ),
              ),
              if (_profiles.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text(
                    '这张卡上还没有 profile',
                    style: TextStyle(fontSize: 12, color: AppColors.muted),
                  ),
                )
              else
                ..._profiles.map(_profileTile),
            ],
          ],
        ],
      ),
    );
  }

  Widget _profileTile(NativeLpaProfile p) {
    final active = p.state == 1;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: active ? AppColors.primary.withValues(alpha: 0.5) : AppColors.border,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        p.nickname.isEmpty ? p.serviceProviderName : p.nickname,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (active) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          '使用中',
                          style: TextStyle(fontSize: 9, color: Colors.white),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  p.iccid,
                  style: const TextStyle(fontSize: 10, color: AppColors.muted),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            enabled: !_busy,
            icon: const Icon(Icons.more_horiz, size: 20),
            onSelected: (v) => _onProfileAction(v, p),
            itemBuilder: (_) => [
              if (!active)
                const PopupMenuItem(value: 'enable', child: Text('启用')),
              if (active)
                const PopupMenuItem(value: 'disable', child: Text('停用')),
              const PopupMenuItem(value: 'rename', child: Text('重命名')),
              const PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    );
  }

  // ----- 小工具 -----

  Widget _step({
    required int index,
    required String title,
    required String hint,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$index',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 30),
            child: Text(
              hint,
              style: const TextStyle(fontSize: 11.5, color: AppColors.muted),
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 66,
            child: Text(
              k,
              style: const TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          ),
          Expanded(
            child: SelectableText(
              v,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

