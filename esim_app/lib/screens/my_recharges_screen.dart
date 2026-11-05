import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../store.dart';
import '../theme.dart';

/// 我的充值记录：查看每笔充值订单的状态。
///
/// 状态：待支付 / 已支付 / 已充值 / 充值失败
class MyRechargesScreen extends StatefulWidget {
  const MyRechargesScreen({super.key});

  @override
  State<MyRechargesScreen> createState() => _MyRechargesScreenState();
}

class _MyRechargesScreenState extends State<MyRechargesScreen> {
  List<RechargeOrder>? _rows;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = context.read<AppState>().api;
      final rows = await api.myRecharges();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.watch<AppState>().t;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text(t.rechargeRecords)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _body(t),
      ),
    );
  }

  Widget _body(dynamic t) {
    if (_loading && _rows == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _rows == null) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 80),
          Icon(Icons.cloud_off, size: 48, color: AppColors.muted.withValues(alpha: .6)),
          const SizedBox(height: 14),
          Text(_error!, textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSub, fontSize: 13)),
          const SizedBox(height: 18),
          Center(
            child: OutlinedButton(onPressed: _load, child: Text(t.retry)),
          ),
        ],
      );
    }
    final rows = _rows ?? [];
    if (rows.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 80),
          Icon(Icons.receipt_long_outlined, size: 56,
              color: AppColors.muted.withValues(alpha: .5)),
          const SizedBox(height: 16),
          Text(t.noRecharges, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(t.noRechargesHint, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.textSub)),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      itemCount: rows.length,
      itemBuilder: (_, i) => _tile(t, rows[i]),
    );
  }

  Widget _tile(dynamic t, RechargeOrder r) {
    final (label, color, bg) = _statusStyle(t, r.status);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFFEDF1F7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  r.mealName.isEmpty ? r.mealId : r.mealName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
                child: Text(label,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(r.simId,
              style: const TextStyle(
                  fontSize: 11.5, color: AppColors.muted, fontFamily: 'monospace')),
          const SizedBox(height: 10),
          Row(
            children: [
              Text('\$${r.amount.toStringAsFixed(2)}',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.primary)),
              const Spacer(),
              Text(_fmtTime(r.createdAt),
                  style: const TextStyle(fontSize: 11.5, color: AppColors.muted)),
            ],
          ),
          if (r.status == 'failed' && r.upstreamMsg.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                r.upstreamMsg,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: Color(0xFF991B1B)),
              ),
            ),
          ],
          if (r.status == 'pending') ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 34,
              child: ElevatedButton(
                onPressed: () => _pay(r),
                style: ElevatedButton.styleFrom(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                ),
                child: Text(t.payNow,
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  (String, Color, Color) _statusStyle(dynamic t, String s) {
    switch (s) {
      case 'pending':
        return (t.stPendingPay, const Color(0xFF64748B), const Color(0xFFF1F5F9));
      case 'paid':
        return (t.stPaid, const Color(0xFF1D4ED8), const Color(0xFFDBEAFE));
      case 'fulfilled':
        return (t.stDone, const Color(0xFF047857), const Color(0xFFD1FAE5));
      case 'failed':
        return (t.stFailed, const Color(0xFFB91C1C), const Color(0xFFFEE2E2));
      case 'refunded':
        return (t.stRefunded, const Color(0xFFB45309), const Color(0xFFFEF3C7));
      default:
        return (s, const Color(0xFF64748B), const Color(0xFFF1F5F9));
    }
  }

  Future<void> _pay(RechargeOrder r) async {
    final t = context.read<AppState>().t;
    final api = context.read<AppState>().api;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(t.confirmPay),
        content: Text('${r.mealName}\n\$${r.amount.toStringAsFixed(2)}\n\n${r.simId}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.cancel)),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: Text(t.confirm)),
        ],
      ),
    );
    if (ok != true) return;

    try {
      final done = await api.payRecharge(r.orderNo);
      if (!mounted) return;
      if (done) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.rechargeSuccess)),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.rechargeFailed), backgroundColor: AppColors.danger),
        );
      }
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString()), backgroundColor: AppColors.danger),
        );
      }
    }
  }

  String _fmtTime(DateTime? d) {
    if (d == null) return "—";
    final l = d.toLocal();
    String p(int n) => n.toString().padLeft(2, "0");
    return "${l.month}/${l.day} ${p(l.hour)}:${p(l.minute)}";
  }
}
