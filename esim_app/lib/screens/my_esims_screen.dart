import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../store.dart';
import '../theme.dart';
import '../i18n.dart';

/// 「我的卡」—— 列出用户已购买的所有卡，展示实时流量。
///
/// 刷新策略：
///  - 进入页面时拉一次
///  - 页面可见时每 60 秒自动刷新一次（可在右上角暂停）
///  - 下拉手动刷新
///
/// 所有文案走 `t.*`，实体卡的标题由 [AppLang] 决定（后端只给
/// `kind = physical_card`，不再传中文）。
class MyEsimsScreen extends StatefulWidget {
  const MyEsimsScreen({super.key});

  @override
  State<MyEsimsScreen> createState() => _MyEsimsScreenState();
}

class _MyEsimsScreenState extends State<MyEsimsScreen> with WidgetsBindingObserver {
  static const _autoRefresh = Duration(seconds: 60);

  List<MyEsim>? _items;
  bool _loading = true;
  String? _error;
  DateTime? _lastRefresh;
  bool _auto = true;
  bool _refreshing = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 只在页面可见时刷新，切到后台不打扰上游
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load(silent: true);
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final app = context.read<AppState>();
      final rows = await app.api.myEsims();
      if (!mounted) return;
      setState(() {
        _items = rows;
        _loading = false;
        _error = null;
        _lastRefresh = DateTime.now();
      });
      // 列表刷新后，顺手让「我的」页的汇总数字跟上
      unawaited(app.refreshEsimStats());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_items == null) _error = e.toString();
      });
    } finally {
      _refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.watch<AppState>().t;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text(t.myEsim),
        actions: [
          IconButton(
            tooltip: _auto ? t.autoRefreshOn : t.autoRefreshOff,
            icon: Icon(_auto ? Icons.autorenew : Icons.pause_circle_outline, size: 20),
            onPressed: () {
              setState(() => _auto = !_auto);
              _timer?.cancel();
              if (_auto) _startTimer();
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _loading ? null : () => _load(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(),
        child: _body(),
      ),
    );
  }

  Widget _body() {
    final t = context.read<AppState>().t;
    if (_loading && _items == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items == null) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 60),
          Icon(Icons.cloud_off, size: 48, color: AppColors.muted.withValues(alpha: .6)),
          const SizedBox(height: 14),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textSub, fontSize: 13),
          ),
          const SizedBox(height: 18),
          Center(
            child: OutlinedButton(
              onPressed: () => _load(),
              child: Text(t.retry),
            ),
          ),
        ],
      );
    }
    final rows = _items ?? [];
    if (rows.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 80),
          Icon(Icons.sim_card_outlined, size: 56, color: AppColors.muted.withValues(alpha: .5)),
          const SizedBox(height: 16),
          Text(
            t.cardsEmptyTitle,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            t.cardsEmptyHint,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: AppColors.textSub),
          ),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      itemCount: rows.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) return _refreshHint(t);
        return _card(rows[i - 1], t);
      },
    );
  }

  Widget _refreshHint(L t) {
    final label = _lastRefresh == null
        ? t.fetching
        : '${t.updatedAt} ${_hms(_lastRefresh!)}${_auto ? " · ${t.autoEveryMinute}" : ""}';
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: Row(
        children: [
          Icon(Icons.sync_rounded, size: 13, color: AppColors.muted),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: AppColors.muted),
            ),
          ),
        ],
      ),
    );
  }

  String _hms(DateTime d) =>
      '${d.hour.toString().padLeft(2, "0")}:${d.minute.toString().padLeft(2, "0")}:${d.second.toString().padLeft(2, "0")}';

  /// 卡片标题：实体卡按当前语言显示，eSIM 用套餐名
  String _title(MyEsim e, L t) {
    if (e.isPhysicalCard) return t.physicalCard;
    if (e.planTitle.isEmpty) return 'eSIM';
    return e.planTitle;
  }

  Widget _card(MyEsim e, L t) {
    final total = e.dataTotalMb;
    final used = e.dataUsedMb;
    final pct = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    final remain = total > 0 ? (total - used).clamp(0.0, total) : 0.0;
    final danger = pct > .85;
    final expired = e.status == 'expired';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadow.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  gradient: AppColors.heroBlue,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.sim_card_rounded, size: 17, color: Colors.white),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _title(e, t),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      e.iccid,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.muted,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              _statusChip(e.status, expired: expired, t: t),
            ],
          ),
          const SizedBox(height: 14),
          if (total > 0) ...[
            Row(
              children: [
                _metric(t.used, MyEsim.fmt(used)),
                _divider(),
                _metric(t.dataTotalShort, MyEsim.fmt(total)),
                _divider(),
                _metric(t.remaining, MyEsim.fmt(remain), highlight: true),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 7,
                backgroundColor: AppColors.borderSoft,
                valueColor: AlwaysStoppedAnimation(
                  danger ? const Color(0xFFEF4444) : AppColors.primary,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  '${(pct * 100).toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: danger ? const Color(0xFFEF4444) : AppColors.muted,
                  ),
                ),
                const Spacer(),
                if (e.expiresAt != null)
                  Text(
                    '${t.expiresOn} ${_date(e.expiresAt!)}',
                    style: const TextStyle(fontSize: 11.5, color: AppColors.muted),
                  ),
              ],
            ),
          ] else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: AppColors.muted.withValues(alpha: .8)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      t.noUsageYet,
                      style: const TextStyle(fontSize: 12, color: AppColors.textSub),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _metric(String label, String value, {bool highlight = false}) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: highlight ? AppColors.orange : AppColors.text,
              letterSpacing: -.4,
              height: 1.1,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 10.5, color: AppColors.muted)),
        ],
      ),
    );
  }

  Widget _divider() => Container(
        width: 1,
        height: 24,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: AppColors.borderSoft,
      );

  Widget _statusChip(String status, {required bool expired, required L t}) {
    final (label, color, bg) = switch (status) {
      'active' => (t.statusUsing, const Color(0xFF047857), const Color(0xFFECFDF5)),
      'issued' => (t.statusIssued, const Color(0xFFB45309), const Color(0xFFFFFBEB)),
      'expired' => (t.statusExpired, const Color(0xFF64748B), const Color(0xFFF1F5F9)),
      _ => (status, const Color(0xFF64748B), const Color(0xFFF1F5F9)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, "0")}-${d.day.toString().padLeft(2, "0")}';

  void _startTimer() {
    _timer?.cancel();
    if (!_auto) return;
    _timer = Timer.periodic(_autoRefresh, (_) {
      if (mounted) _load(silent: true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _startTimer();
  }
}
