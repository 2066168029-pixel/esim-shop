import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../countries.dart';
import '../currency.dart';
import '../store.dart';
import '../theme.dart';

/// Full-page plan detail.
///
/// The list screen adds straight to the cart from a tile, which hides the
/// description, validity rules and coverage. This page is where a customer
/// reads before committing.
class PlanDetailScreen extends StatefulWidget {
  final Plan plan;
  const PlanDetailScreen({super.key, required this.plan});

  @override
  State<PlanDetailScreen> createState() => _PlanDetailScreenState();
}

class _PlanDetailScreenState extends State<PlanDetailScreen> {
  late Plan _plan;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _plan = widget.plan;
    _refresh();
  }

  /// Re-fetch by id: stock and price change, and the list payload can be a
  /// minute stale by the time someone taps through.
  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final fresh = await context.read<AppState>().api.plan(_plan.id);
      if (mounted) setState(() => _plan = fresh);
    } catch (_) {
      // Keep showing the data we already have; a stale plan is better than an
      // error screen for something the user cannot act on.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _addToCart() {
    final app = context.read<AppState>();
    app.addToCart(_plan);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已加入购物车：${_plan.title}'),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: '去结算',
          textColor: Colors.white,
          onPressed: () {
            Navigator.pop(context);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _plan;
    final soldOut = p.stock <= 0;
    final cover = destinationPhoto(p.countryCode, cover: p.cover);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('套餐详情'),
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: ListView(
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Image.network(
              cover,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                color: AppColors.sky,
                child: const Icon(Icons.public, size: 48, color: AppColors.primary),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.title,
                  style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, height: 1.3),
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      formatInCurrency(p.price, p.currency),
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary,
                      ),
                    ),
                    const Spacer(),
                    if (p.region.isNotEmpty)
                      Chip(
                        label: Text(p.region, style: const TextStyle(fontSize: 11)),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
                const SizedBox(height: 18),

                // ---- specs ----
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(AppRadii.card),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      _spec(Icons.data_usage, '流量', p.dataGb > 0 ? '${_num(p.dataGb)} GB' : '不限'),
                      _divider(),
                      _spec(Icons.schedule, '有效期', '${p.validityDays} 天'),
                      if (p.kind == 'quota') ...[
                        _divider(),
                        _spec(Icons.layers, '卡槽', '+${p.quotaSlots}'),
                      ],
                    ],
                  ),
                ),

                if (p.voiceMinutes > 0 || p.smsCount > 0) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      if (p.voiceMinutes > 0)
                        Expanded(
                          child: _miniStat(
                            Icons.call,
                            '通话',
                            '${p.voiceMinutes} 分钟',
                          ),
                        ),
                      if (p.voiceMinutes > 0 && p.smsCount > 0) const SizedBox(width: 12),
                      if (p.smsCount > 0)
                        Expanded(
                          child: _miniStat(Icons.sms, '短信', '${p.smsCount} 条'),
                        ),
                    ],
                  ),
                ],

                const SizedBox(height: 20),
                const Text('套餐说明', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text(
                  p.description.isNotEmpty ? p.description : '暂无详细说明。',
                  style: const TextStyle(fontSize: 13.5, height: 1.7, color: AppColors.textSub),
                ),

                const SizedBox(height: 20),
                const Text('使用须知', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                const _Bullet('购买后可在「订单」中查看 eSIM 二维码，扫码即可安装。'),
                const _Bullet('请在有效期内激活，激活后开始计算流量与天数。'),
                const _Bullet('实体卡用户可通过蓝牙写卡器将套餐写入卡片。'),
                const _Bullet('激活后不支持退款，请确认目的地后再购买。'),

                const SizedBox(height: 24),
                if (soldOut)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.danger.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(AppRadii.btn),
                    ),
                    child: const Text(
                      '该套餐暂时缺货',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w700),
                    ),
                  )
                else
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _addToCart,
                      icon: const Icon(Icons.add_shopping_cart, size: 18),
                      label: const Text('加入购物车'),
                    ),
                  ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('返回'),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _num(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  Widget _spec(IconData icon, String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, size: 20, color: AppColors.primary),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
        ],
      ),
    );
  }

  Widget _divider() => Container(width: 1, height: 34, color: AppColors.border);

  Widget _miniStat(IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.primary),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
              Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  final String text;
  const _Bullet(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6, right: 8),
            child: Icon(Icons.circle, size: 5, color: AppColors.muted),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13, height: 1.6, color: AppColors.textSub),
            ),
          ),
        ],
      ),
    );
  }
}
