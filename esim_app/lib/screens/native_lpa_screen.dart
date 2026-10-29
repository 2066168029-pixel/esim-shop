import 'dart:async';

import 'package:flutter/material.dart';

import '../native_lpa.dart';
import '../theme.dart';

/// iOS-native LPA page, driven by the Linksfield eSIMManagerSDK.
///
/// This is the iOS counterpart of `CardWriterScreen`. On iOS the vendor binary
/// SDK handles BLE + LPA, so there is no need to run the pure-Dart protocol
/// implementation. On every other platform (or in the simulator, where the
/// arm64-only xcframework is unavailable) this page explains itself and points
/// back to the Dart flow.
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

  final _codeController = TextEditingController();

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
    super.dispose();
  }

  Future<void> _checkAvailability() async {
    final ok = await NativeLpa.isAvailable;
    if (!mounted) return;
    setState(() => _available = ok);
    if (!ok) return;

    _stateSub = NativeLpa.connectionStates.listen((s) {
      if (mounted) setState(() => _connState = s);
    });
    _notifySub = NativeLpa.deviceNotifications.listen((n) {
      if (!mounted) return;
      final iccid = n['iccid'] as String? ?? '';
      setState(() {
        _message = '${n['operation']} ${n['status']}'
            '${iccid.isNotEmpty ? ' | $iccid' : ''}';
      });
    });
  }

  Future<void> _toggleScan() async {
    if (_scanning) {
      await _scanSub?.cancel();
      await NativeLpa.stopScan();
      if (mounted) setState(() => _scanning = false);
      return;
    }

    setState(() {
      _devices.clear();
      _scanning = true;
      _message = null;
    });

    _scanSub = NativeLpa.scan().listen(
      (d) {
        if (!mounted) return;
        if (_devices.any((x) => x.id == d.id)) return;
        setState(() => _devices.add(d));
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
      _message = 'Connecting...';
    });
    try {
      final ok = await NativeLpa.connect(d.id);
      if (!mounted) return;
      if (!ok) {
        setState(() => _message = 'Connection failed');
        return;
      }
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _message = 'Connect error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _busy = true);
    try {
      final r = await NativeLpa.getProfiles();
      if (!mounted) return;
      setState(() {
        _eid = r.eid;
        _profiles = r.profiles;
        _message = r.result == 0 ? null : 'getProfiles result=${r.result}';
      });
    } catch (e) {
      if (mounted) setState(() => _message = 'Refresh error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runOp(
    String label,
    Future<NativeLpaResult> Function() op,
  ) async {
    setState(() {
      _busy = true;
      _message = '$label...';
    });
    try {
      final r = await op();
      if (!mounted) return;
      setState(() {
        _message = r.ok ? '$label OK' : '$label failed (${r.result})';
      });
      if (r.ok) await _refresh();
    } catch (e) {
      if (mounted) setState(() => _message = '$label error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;

    setState(() {
      _busy = true;
      _message = 'Downloading...';
    });
    try {
      var r = await NativeLpa.download(code);
      if (r.needConfirm) {
        if (!mounted) return;
        final confirm = await _askConfirmationCode();
        if (confirm == null) {
          setState(() => _message = 'Cancelled (confirmation code required)');
          return;
        }
        r = await NativeLpa.download(code, confirmationCode: confirm);
      }
      if (!mounted) return;
      setState(() {
        _message = r.ok ? 'Installed' : 'Download failed (${r.result})';
      });
      if (r.ok) {
        _codeController.clear();
        await _refresh();
      }
    } catch (e) {
      if (mounted) setState(() => _message = 'Download error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askConfirmationCode() {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmation code'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Enter the code'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_available == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Native LPA (iOS SDK)'),
        actions: [
          if (_eid != null)
            IconButton(
              tooltip: 'Refresh',
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: _available! ? _buildBody() : _buildUnavailable(),
    );
  }

  Widget _buildUnavailable() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.apple, size: 56, color: AppColors.muted),
            const SizedBox(height: 16),
            const Text(
              'Native SDK not available',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            const Text(
              'The Linksfield eSIMManagerSDK ships an arm64 device slice only.\n\n'
              'It works on a physical iPhone, but not in the simulator, and not '
              'on Android or desktop. Use the Dart transport flow there.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_eid != null) return _buildCard();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _scanning
                      ? 'Scanning...'
                      : 'Found ${_devices.length} card(s)',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : _toggleScan,
                icon: Icon(_scanning ? Icons.stop : Icons.bluetooth_searching),
                label: Text(_scanning ? 'Stop' : 'Scan'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _devices.isEmpty
              ? Center(
                  child: Text(
                    _scanning ? 'Looking for cards...' : 'No cards yet - tap Scan',
                    style: const TextStyle(color: AppColors.muted),
                  ),
                )
              : ListView.separated(
                  itemCount: _devices.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final d = _devices[i];
                    final shortId = d.id.length > 8 ? d.id.substring(0, 8) : d.id;
                    return ListTile(
                      leading: const Icon(Icons.credit_card),
                      title: Text(d.name),
                      subtitle: Text(
                        '$shortId... | ${d.rssi} dBm'
                        '${d.mac.isNotEmpty ? ' | ${d.mac}' : ''}',
                      ),
                      trailing: _busy && _selected?.id == d.id
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.chevron_right),
                      onTap: _busy ? null : () => _connect(d),
                    );
                  },
                ),
        ),
        if (_message != null) _buildMessageBar(),
      ],
    );
  }

  Widget _buildMessageBar() {
    return Container(
      width: double.infinity,
      color: AppColors.bg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Text(_message!, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _buildCard() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _kv('Device', _selected?.name ?? '-'),
        _kv('State', _connState.name),
        _kv('EID', _eid ?? '-'),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : _refresh,
                child: const Text('Reload profiles'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : _disconnect,
                child: const Text('Disconnect'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Text('Profiles', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (_profiles.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'No profiles on this card',
              style: TextStyle(color: AppColors.muted),
            ),
          )
        else
          ..._profiles.map(_buildProfileTile),
        const SizedBox(height: 24),
        const Text(
          'Install profile',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _codeController,
          decoration: const InputDecoration(
            labelText: 'Activation code',
            hintText: r'LPA:1$SMDP$MATCHING-ID',
            border: OutlineInputBorder(),
          ),
          maxLines: 2,
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _busy ? null : _download,
          icon: const Icon(Icons.download),
          label: const Text('Install'),
        ),
        if (_message != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.bg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(_message!, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ],
    );
  }

  Future<void> _disconnect() async {
    await NativeLpa.disconnect();
    if (!mounted) return;
    setState(() {
      _eid = null;
      _profiles = [];
      _selected = null;
    });
  }

  Widget _buildProfileTile(NativeLpaProfile p) {
    final title = p.nickname.isNotEmpty
        ? p.nickname
        : (p.profileName.isNotEmpty ? p.profileName : p.iccid);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          p.isEnabled ? Icons.check_circle : Icons.radio_button_unchecked,
          color: p.isEnabled ? AppColors.success : AppColors.muted,
        ),
        title: Text(title),
        subtitle: Text('${p.serviceProviderName} | ${p.iccid}'),
        trailing: PopupMenuButton<String>(
          enabled: !_busy,
          onSelected: (v) => _onProfileAction(v, p),
          itemBuilder: (_) => [
            if (!p.isEnabled)
              const PopupMenuItem(value: 'enable', child: Text('Enable')),
            if (p.isEnabled)
              const PopupMenuItem(value: 'disable', child: Text('Disable')),
            const PopupMenuItem(value: 'rename', child: Text('Rename')),
            const PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ),
    );
  }

  void _onProfileAction(String action, NativeLpaProfile p) {
    switch (action) {
      case 'enable':
        _runOp('Enable', () => NativeLpa.enable(p.iccid));
      case 'disable':
        _runOp('Disable', () => NativeLpa.disable(p.iccid));
      case 'delete':
        _runOp('Delete', () => NativeLpa.delete(p.iccid));
      case 'rename':
        _askRename(p);
    }
  }

  Future<void> _askRename(NativeLpaProfile p) async {
    final ctrl = TextEditingController(text: p.nickname);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename profile'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await _runOp('Rename', () => NativeLpa.setNickname(p.iccid, name));
    }
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              k,
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
          ),
          Expanded(
            child: SelectableText(v, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
