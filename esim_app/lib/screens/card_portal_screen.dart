import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../main.dart' show showSnack;
import '../store.dart';
import '../theme.dart';

/// 激活页输入 ICCID 后进入的卡信息页。
///
/// - ICCID 由上一页带入，这里**不再要求重复输入**
/// - 进入即查询：卡状态 → 当前套餐 → 可充值套餐
/// - 支持下拉刷新
class CardPortalScreen extends StatefulWidget {
  final String iccid;

  const CardPortalScreen({super.key, required this.iccid});

  @override
  State<CardPortalScreen> createState() => _CardPortalScreenState();
}

class _CardPortalScreenState extends State<CardPortalScreen> {
  CardFlowInfo? _flow;
  CardPackage? _currentPack;
  List<CardPackage> _packages = const [];
  bool _loading = false;
  bool _loadingPkgs = false;
  String? _error;

  String get _sim => widget.iccid.trim();

  @override
  void initState() {
    super.initState();
    if (_sim.isNotEmpty) {
      _query();
    }
  }

  Future<void> _query() async {
    if (_sim.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = context.read<AppState>().api;
      // 状态和流量一起拿：flow 里有剩余流量，status 里有卡片状态
      final results = await Future.wait([
        api.cardFlow(_sim),
        api.cardStatus(_sim),
      ]);
      final flow = results[0];
      final status = results[1];

      if (!mounted) return;
      setState(() {
        _flow = CardFlowInfo(
          ok: flow.ok,
          simId: flow.simId,
          totalFlow: flow.totalFlow,
          usedFlow: flow.usedFlow,
          remainingFlow: flow.remainingFlow,
          expireDate: flow.expireDate,
          status: status.status.isNotEmpty ? status.status : flow.status,
          error: flow.error,
        );
        _loading = false;
        if (!flow.ok) _error = flow.error ?? 'err';
      });
      if (flow.ok) _loadPackages();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadPackages() async {
    if (_loadingPkgs) return;
    setState(() => _loadingPkgs = true);
    try {
      final api = context.read<AppState>().api;
      final r = await api.cardPackagesByCard(_sim);
      if (!mounted) return;
      setState(() {
        _currentPack = r.current;
        _packages = r.packages;
        _loadingPkgs = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingPkgs = false);
    }
  }

  Future<void> _recharge(CardPackage pkg) async {
    final t = context.read<AppState>().t;
    final api = context.read<AppState>().api;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(t.confirmRecharge),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(pkg.name, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('\$${pkg.money}',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.primary)),
            const SizedBox(height: 10),
            Text(_sim,
                style: const TextStyle(fontSize: 12, color: AppColors.textSub, fontFamily: 'monospace')),
            const SizedBox(height: 12),
            Text('${t.rechargeHint}\n${t.payNow}',
                style: const TextStyle(fontSize: 12, color: AppColors.muted)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.cancel)),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: Text(t.confirm)),
        ],
      ),
    );
    if (ok != true) return;

    try {
      // 1) 创建订单（pending，不扣钱也不调上游）
      final order = await api.createRecharge(
        simId: _sim,
        mealId: pkg.orderId,
        mealName: pkg.name,
        days: pkg.days,
        flowSizeMb: pkg.flowSizeMb,
        amount: double.tryParse(pkg.money) ?? 0,
      );
      if (!mounted) return;

      // 2) 付款 → 自动充值
      final done = await api.payRecharge(order.orderNo);
      if (!mounted) return;

      if (done) {
        showSnack(context, t.rechargeSuccess);
        setState(() {
          _packages = const [];
        });
        _query();
      } else {
        showSnack(context, '${t.rechargeFailed} · ${order.orderNo}', error: true);
      }
    } catch (e) {
      if (mounted) showSnack(context, e.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.watch<AppState>().t;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text(t.cardDetails)),
      body: RefreshIndicator(
        onRefresh: _query,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 60),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_error != null) _errorBox(t, _error!),
            if (_flow != null && _flow!.ok) ...[
              _flowCard(t, _flow!),
              if (_currentPack != null) ...[
                const SizedBox(height: 12),
                _currentPackCard(t, _currentPack!),
              ],
              const SizedBox(height: 16),
              _packagesSection(t),
            ],
          ],
        ),
      ),
    );
  }

  Widget _errorBox(dynamic t, String msg) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: Color(0xFFB91C1C)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              msg == 'err' ? t.queryFailed : msg,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF991B1B)),
            ),
          ),
          TextButton(
            onPressed: _query,
            child: Text(t.retry, style: const TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }

  Widget _flowCard(dynamic t, CardFlowInfo f) {
    final total = f.totalFlow ?? 0;
    final used = f.usedFlow ?? 0;
    final remain = f.remainingFlow ?? ((total - used).clamp(0, total)).toDouble();
    final pct = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    final danger = pct > .85;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: AppColors.heroBlue,
        borderRadius: BorderRadius.circular(AppRadii.card),
        boxShadow: const [
          BoxShadow(color: Color(0x330A66FF), blurRadius: 18, offset: Offset(0, 6)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.sim_card, size: 17, color: Colors.white),
            const SizedBox(width: 7),
            Text(t.cardStatus,
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .22),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _statusText(t, f.status),
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            _whiteStat(t.remaining, CardFlowInfo.fmt(remain)),
            _whiteDivider(),
            _whiteStat(t.totalData, total > 0 ? CardFlowInfo.fmt(total) : '—'),
            _whiteDivider(),
            _whiteStat(t.dataUsed, CardFlowInfo.fmt(used)),
          ]),
          if (total > 0) ...[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 7,
                backgroundColor: Colors.white.withValues(alpha: .25),
                valueColor: AlwaysStoppedAnimation(danger ? const Color(0xFFFCA5A5) : Colors.white),
              ),
            ),
            const SizedBox(height: 6),
            Text('${(pct * 100).toStringAsFixed(1)}%',
                style: TextStyle(fontSize: 11.5, color: Colors.white.withValues(alpha: .85))),
          ],
          if (f.expireDate.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('${t.expiresAt} ${f.expireDate}',
                style: TextStyle(fontSize: 11.5, color: Colors.white.withValues(alpha: .85))),
          ],
        ],
      ),
    );
  }

  String _statusText(dynamic t, String? s) {
    switch (s) {
      case '1':
        return t.statusActive;
      case '4':
        return t.statusPending;
      case '2':
        return t.statusSuspended;
      case '3':
        return t.statusCancelled;
      case '5':
        return t.statusExpired;
      default:
        return t.statusUnknown;
    }
  }

  Widget _whiteStat(String label, String value) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.3)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(color: Colors.white.withValues(alpha: .8), fontSize: 11)),
          ],
        ),
      );

  Widget _whiteDivider() => Container(
        width: 1,
        height: 24,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        color: Colors.white.withValues(alpha: .25),
      );

  Widget _currentPackCard(dynamic t, CardPackage p) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F4FF),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFFDBE2FF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(t.currentPlan,
                  style: const TextStyle(
                      fontSize: 11.5, color: AppColors.textSub, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (p.days > 0)
                Text('${p.days} ${t.days}',
                    style: const TextStyle(fontSize: 11.5, color: AppColors.muted)),
            ],
          ),
          const SizedBox(height: 6),
          Text(p.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Row(
            children: [
              _miniInfo(t.flow, CardPackage.fmtFlow(p.flowSizeMb)),
              const SizedBox(width: 18),
              _miniInfo(t.price, '\$${p.money}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniInfo(String label, String value) => Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.muted)),
          const SizedBox(width: 5),
          Text(value, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
        ],
      );

  Widget _packagesSection(dynamic t) {
    if (_loadingPkgs) {
      return const Center(
          child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()));
    }
    final main = _packages;
    if (main.isEmpty) {
      return Center(
        child: TextButton(
          onPressed: _loadPackages,
          child: Text(t.loadPackages),
        ),
      );
    }
    final rows = main;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 只有一份列表了：可充值套餐。
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            '${t.rechargePlans} (${main.length})',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(t.noPackages,
                  style: const TextStyle(fontSize: 12.5, color: AppColors.muted)),
            ),
          )
        else
          ...rows.map((p) => _packageTile(t, p)),
      ],
    );
  }

  Widget _packageTile(dynamic t, CardPackage p) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFFEDF1F7)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Text('\$${p.money}',
                        style: const TextStyle(
                            fontSize: 12.5,
                            color: AppColors.primary,
                            fontWeight: FontWeight.w700)),
                    if (p.days > 0) ...[
                      const SizedBox(width: 8),
                      Text('${p.days}${t.days}',
                          style: const TextStyle(fontSize: 11.5, color: AppColors.muted)),
                    ],
                    if (p.flowSizeMb.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Text(CardPackage.fmtFlow(p.flowSizeMb),
                          style: const TextStyle(fontSize: 11.5, color: AppColors.muted)),
                    ],
                  ],
                ),
              ],
            ),
          ),
          SizedBox(
            height: 32,
            child: ElevatedButton(
              onPressed: () => _recharge(p),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(72, 32),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
              ),
              child: Text(t.recharge,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}
