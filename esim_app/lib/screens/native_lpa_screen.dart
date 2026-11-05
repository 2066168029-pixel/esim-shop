import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../i18n.dart';
import '../native_lpa.dart';
import '../store.dart';
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
  /// 仅表示"正在写卡"，与 _busy（任意进行中的操作）区分开。
  bool _writing = false;
  bool _moreOpen = false;

  /// 本地多语言访问器。
  L get t => context.read<AppState>().t;

  /// 当前 _message 是否为失败态（决定卡片配色）。
  bool _msgIsError = false;

  /// 服务端额度（写入配额）。来自 /api/sim/bind-card。
  /// 与安卓 card_writer_screen_v3 的 _quota 保持一致。
  CardQuota? _quota;

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
        if (mounted) _setMessage(t.cwScanError('$e'), isError: true);
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
      _setMessage(t.cwStatusConnecting(d.name));
    });
    try {
      // 密码由原生层在 getDeviceInfo() 时弹框询问（与 demo 结构一致），
      // 这里只负责连接结果。
      final ok = await NativeLpa.connect(d.id);
      if (!mounted) return;
      if (!ok) {
        _setMessage(t.cwConnectFailed, isError: true);
        return;
      }
      _stateSub?.cancel();
      _stateSub = NativeLpa.connectionStates.listen((s) {
        if (!mounted) return;
        setState(() => _connState = s);
      });
      await _refresh();
    } catch (e) {
      if (mounted) _setMessage(t.cwConnectError('$e'), isError: true);
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
        _setMessage(t.cwReadEidFailed, isError: true);
        return;
      }
      final r = await NativeLpa.getProfiles();
      if (!mounted) return;
      setState(() {
        _profiles = r.profiles;
        _message = null;
      });

      // 与安卓一致：先把卡上的 profile 列表推给服务端同步，
      // 再查额度。服务端按已绑定数量算配额，不同步的话基数会偏小。
      await _loadQuota(eid);
    } catch (e) {
      if (mounted) _setMessage(t.cwReadCardFailed('$e'), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 查询这张卡的服务端写入配额。
  ///
  /// 与安卓 card_writer_screen_v3 的流程一致：
  ///   1. syncProfiles —— 把卡上实际存在的 profile 推上去，校正服务端基数
  ///   2. bindCard     —— 拿回 capacity / boundCount / allowed
  ///
  /// 网络失败不视为"禁止写入"：额度是运营控制项，不该因为断网把功能锁死。
  Future<void> _loadQuota(String eid) async {
    final app = context.read<AppState>();
    try {
      if (_profiles.isNotEmpty) {
        await app.api.syncProfiles(
          eid,
          _profiles
              .map((x) => {
                    'iccid': x.iccid,
                    'state': x.state,
                    'nickname': x.nickname,
                    'profile_name': x.profileName,
                    'service_provider': x.serviceProviderName,
                  })
              .toList(),
        );
      }
    } catch (_) {
      // 同步失败不阻断额度查询
    }

    try {
      final q = await app.api.bindCard(eid);
      if (!mounted) return;
      setState(() => _quota = q);
    } catch (e) {
      if (!mounted) return;
      setState(() => _quota = null);
      // 保留原有提示，不覆盖成功消息
      if (_message == null) {
        _setMessage(t.cwQuotaFailed('$e'), isError: true);
      }
    }
  }

  Future<void> _download() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      _setMessage(t.cwEnterCodeFirst, isError: true);
      return;
    }
    if (!_connected) {
      _setMessage(t.cwConnectReaderFirst, isError: true);
      return;
    }

    setState(() {
      _busy = true;
      _writing = true;
      _progress = null;
      _setMessage(t.cwWritingDontRemove);
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
            _setMessage(t.cwCancelled);
          });
          return;
        }
        r = await NativeLpa.download(code, confirmationCode: confirm);
        if (!mounted) return;
      }

      setState(() {
        _message = r.ok ? t.cwWriteSuccess : t.cwWriteFailedCode(r.result);
      });
      if (r.ok) {
        _codeController.clear();
        _confirmController.clear();
        await _refresh();
      }
    } catch (e) {
      if (mounted) _setMessage(t.cwWriteError('$e'), isError: true);
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
        title: Text(t.cwConfirmCodeTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.cwConfirmCodeNeeded,
              style: TextStyle(fontSize: 12, color: AppColors.muted),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: c,
              autofocus: true,
              decoration: InputDecoration(
                labelText: t.cwConfirmCodeTitle,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.cwCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: Text(t.cwOk),
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
      setState(() => _message = r.ok ? t.cwWriteSuccess : t.cwWriteFailedCode(r.result));
      if (r.ok) await _refresh();
    } catch (e) {
      if (mounted) setState(() => _message = t.cwWriteError('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onProfileAction(String action, NativeLpaProfile p) {
    switch (action) {
      case 'enable':
        _runOp(t.cwEnable, () => NativeLpa.enable(p.iccid));
        break;
      case 'disable':
        _runOp(t.cwDisable, () => NativeLpa.disable(p.iccid));
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
        title: Text(t.cwDeleteProfile),
        content: Text(t.cwDeleteProfileConfirm(
            p.serviceProviderName, p.iccid)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.cwCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.cwDelete),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _runOp(t.cwDelete, () => NativeLpa.delete(p.iccid));
    }
  }

  Future<void> _askRename(NativeLpaProfile p) async {
    final c = TextEditingController(text: p.nickname);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.cwRename),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(
            labelText: t.cwName,
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.cwCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: Text(t.cwOk),
          ),
        ],
      ),
    );
    c.dispose();
    if (name != null && name.isNotEmpty) {
      await _runOp(t.cwRename, () => NativeLpa.setNickname(p.iccid, name));
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
        title: Text(t.cwTitle),
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
            Text(
              t.cwUnsupported,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Text(
              t.cwUnsupportedDetail,
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
          title: t.cwStepReader,
          hint: t.cwStepReaderHint,
          child: _step1Scanner(),
        ),
        const SizedBox(height: 14),
        _step(
          index: 2,
          title: t.cwStepCode,
          hint: t.cwStepCodeHint,
          child: _step2Code(),
        ),
        const SizedBox(height: 14),
        _step(
          index: 3,
          title: t.cwStepWrite,
          hint: _connected
              ? t.cwStepWriteHintReady(_selected?.name ?? '')
              : t.cwStepWriteHintIdle,
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
        (_devices.isEmpty
            ? t.cwNoDeviceYet
            : t.cwFoundDevices(_devices.length));

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
                child: Text(t.cwDisconnect),
              ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _busy ? null : _toggleScan,
          icon: Icon(_scanning ? Icons.stop : Icons.bluetooth_searching),
          label: Text(_scanning ? t.cwStopScan : t.cwScanReader),
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
          decoration: InputDecoration(
            labelText: t.cwActivationPlaceholder,
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
                label: Text(t.cwScan),
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
                  _confirmController.text.isEmpty
                      ? t.cwConfirmCodeOptional
                      : t.cwConfirmCodeFilled,
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
        title: Text(t.cwConfirmCodeTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.cwConfirmCodeNeeded,
              style: TextStyle(fontSize: 12, color: AppColors.muted),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: c,
              autofocus: true,
              decoration: InputDecoration(
                labelText: t.cwConfirmCodeTitle,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.cwCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: Text(t.cwOk),
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
    // 只反映"正在写卡"，不跟着"正在连接"一起转。
    final writing = _writing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: (_busy || !_connected) ? null : _download,
          icon: writing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.download),
          label: Text(writing ? t.cwWriting : t.cwStartWrite),
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

  /// 设置提示消息并标记成败，供 _messageCard 配色。
  void _setMessage(String msg, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _message = msg;
      _msgIsError = isError;
    });
  }

  Widget _messageCard() {
    final isErr = _msgIsError;
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
                  Text(
                    t.cwMoreFunctions,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _connected
                          ? t.cwProfilesInstalled(_profiles.length)
                          : t.cwConnectReaderFirst,
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
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  t.cwConnectToSee,
                  style: TextStyle(fontSize: 12, color: AppColors.muted),
                ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv(t.cwDevice, _selected?.name ?? '-'),
                    _kv('EID', _eid ?? '-'),
                    if (_quota != null) _quotaRow(),
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
                        child: Text(t.cwRefreshProfiles),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy ? null : _disconnect,
                        child: Text(t.cwDisconnect),
                      ),
                    ),
                  ],
                ),
              ),
              if (_profiles.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    t.cwNoProfiles,
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

  /// 服务端写入配额。与安卓 card_writer_screen_v3 的额度行一致：
  /// 已绑定 / 容量，超额红色，并给出扩容入口。
  Widget _quotaRow() {
    final q = _quota!;
    final text = q.known ? '${q.boundCount} / ${q.capacity}' : q.reasonText;
    final color = !q.known
        ? AppColors.muted
        : (q.allowed ? const Color(0xFF389E0D) : const Color(0xFFCF1322));

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 66,
            child: Text(
              t.cwQuotaTitle,
              style: TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: color,
              ),
            ),
          ),
          if (q.known)
            InkWell(
              onTap: _buyQuota,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  t.cwQuotaExpand,
                  style: TextStyle(fontSize: 12, color: AppColors.primary),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 扩容：额度不足时跳去购买套餐。
  ///
  /// 安卓那边是有额度包可直接下单；iOS 这版先引导到套餐页，
  /// 复用已有的下单/支付链路，避免再写一套。
  void _buyQuota() {
    final q = _quota;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.cwQuotaExpandTitle),
        content: Text(
          q == null || !q.known
              ? t.cwQuotaUnknown
              : t.cwQuotaExpandBody(q.boundCount, q.capacity),
          style: const TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.cwCancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.maybePop(context);
            },
            child: Text(t.cwGoToPlans),
          ),
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
                        child: Text(
                          t.cwInUse,
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
                PopupMenuItem(value: 'enable', child: Text(t.cwEnable)),
              if (active)
                PopupMenuItem(value: 'disable', child: Text(t.cwDisable)),
              PopupMenuItem(value: 'rename', child: Text(t.cwRename)),
              PopupMenuItem(value: 'delete', child: Text(t.cwDelete)),
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

