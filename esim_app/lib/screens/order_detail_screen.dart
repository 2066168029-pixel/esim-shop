import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api.dart';
import '../currency.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets.dart';

class OrderDetailScreen extends StatefulWidget {
  final String orderNo;
  const OrderDetailScreen({super.key, required this.orderNo});
  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  Order? _order;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _order = null; _err = null; });
    try {
      final o = await context.read<AppState>().api.order(widget.orderNo);
      setState(() => _order = o);
    } catch (e) {
      setState(() => _err = '$e');
    }
  }

  Future<void> _refreshUsage(int esimId) async {
    try {
      final e = await context.read<AppState>().api.refreshUsage(esimId);
      _snack('已使用 ${e.dataUsedMb.toStringAsFixed(1)} MB');
      _load();
    } catch (e) {
      _snack('$e', error: true);
    }
  }

  void _snack(String m, {bool error = false}) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(m),
      backgroundColor: error ? AppColors.danger : AppColors.success,
      behavior: SnackBarBehavior.floating,
    ));
  }

  void _showQr(Esim e) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _QrSheet(esim: e, onCopied: () => _snack('激活码已复制')),
    );
  }

  /// Open the "pay now" sheet for a still-pending order. Loads the enabled
  /// channels from the backend so it always mirrors the admin settings.
  Future<void> _payNow(Order o) async {
    List<PaymentGateway> gateways = [];
    try {
      gateways = await context.read<AppState>().api.paymentGateways();
    } catch (_) {}
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _PaySheet(
        order: o,
        gateways: gateways,
        onPayPal: _payWithPayPal,
        onDone: () => _load(),
      ),
    );
  }

  Future<void> _payWithPayPal(Order o) async {
    try {
      final res = await context.read<AppState>().api.paypalCreate(o.orderNo);
      final url = res['approve_url'] as String? ?? '';
      if (url.isEmpty) {
        _snack('PayPal 下单失败，请稍后重试', error: true);
        return;
      }
      final uri = Uri.tryParse(url);
      if (uri != null) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      if (mounted) {
        _snack('完成 PayPal 付款后返回本页，点击刷新订单状态');
        _load();
      }
    } catch (e) {
      _snack('$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('订单详情')),
      body: _err != null
          ? errorBox(_err!)
          : _order == null
              ? loadingBox()
              : RefreshIndicator(onRefresh: _load, color: AppColors.primary, child: _content(_order!)),
    );
  }

  Widget _content(Order o) {
    final pending = o.status == 'pending';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Awaiting-payment banner + CTA
        if (pending) _pendingCard(o),

        // Active eSIM hero card (per eSIM)
        ...o.esims.map((e) => _esimHero(o, e)),

        // Order summary
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text('订单号 ${o.orderNo}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5))),
                  StatusChip(o.status),
                ],
              ),
              const SizedBox(height: 6),
              Text(o.createdAt != null ? DateFormat('yyyy-MM-dd HH:mm').format(o.createdAt!.toLocal()) : '',
                  style: const TextStyle(color: AppColors.muted, fontSize: 12)),
              Text(o.email, style: const TextStyle(color: AppColors.muted, fontSize: 12)),
              const Divider(height: 24),
              ...o.items.map((i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(child: Text('${i.title} x ${i.quantity}', style: const TextStyle(fontSize: 13.5))),
                        Text(formatInCurrency(i.unitPrice * i.quantity, o.currency), style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  )),
              if (o.discount > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Text('优惠 ${o.couponCode}', style: const TextStyle(color: AppColors.success, fontSize: 13.5)),
                    const Spacer(),
                    Text('-${formatInCurrency(o.discount, o.currency)}', style: const TextStyle(fontSize: 13.5, color: AppColors.success)),
                  ]),
                ),
              const Divider(height: 24),
              Row(children: [
                const Text('合计', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                const Spacer(),
                Text(formatInCurrency(o.total, o.currency),
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 19, color: AppColors.primary)),
              ]),
              if (o.items.any((i) => i.kind == 'physical_sim')) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: AppColors.warn.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                  child: Text(
                    '实体卡将发往：${o.shipName} · ${o.shipAddress}'
                    '${o.trackingNo.isNotEmpty ? '\n运单号：${o.trackingNo}' : ''}',
                    style: const TextStyle(fontSize: 12.5, color: AppColors.text),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Banner shown while an order is still awaiting payment.
  Widget _pendingCard(Order o) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.warn.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadii.big),
          border: Border.all(color: AppColors.warn.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.hourglass_bottom, color: AppColors.warn, size: 20),
              const SizedBox(width: 8),
              const Text('待付款', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              const Spacer(),
                Text(formatInCurrency(o.total, o.currency), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            ]),
            const SizedBox(height: 6),
            const Text('请完成付款，付款后系统将自动发放 eSIM。', style: TextStyle(fontSize: 12.5, color: AppColors.textSub)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => _payNow(o),
                child: const Text('去支付'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Big blue active-eSIM card with usage ring + action buttons (Onlylink style).
  Widget _esimHero(Order o, Esim e) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        decoration: BoxDecoration(
          gradient: AppColors.heroBlue,
          borderRadius: BorderRadius.circular(AppRadii.big),
          boxShadow: const [BoxShadow(color: Color(0x330A66FF), blurRadius: 24, offset: Offset(0, 12))],
        ),
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sim_card, color: AppColors.gold, size: 22),
                const SizedBox(width: 8),
                Text(o.items.isNotEmpty ? o.items.first.title : 'eSIM',
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                const Spacer(),
                StatusChip(e.status),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                SizedBox(
                  width: 84, height: 84,
                  child: _UsageRing(usedMb: e.dataUsedMb, totalGb: _planGb(o)),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('数据余额', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      Text(_remainingLabel(o, e), style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                      const SizedBox(height: 6),
                      Text('已用 ${e.dataUsedMb.toStringAsFixed(1)} MB',
                          style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      if (e.expiresAt != null)
                        Text('有效期至 ${DateFormat('yyyy-MM-dd').format(e.expiresAt!.toLocal())}',
                            style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white, foregroundColor: AppColors.primary,
                      minimumSize: const Size(0, 44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => _showQr(e),
                    child: const Text('查看二维码', style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.orange, foregroundColor: Colors.white,
                      minimumSize: const Size(0, 44),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => _refreshUsage(e.id),
                    child: const Text('刷新流量', style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  double _planGb(Order o) {
    // matches the first esim's plan data
    return o.esims.isNotEmpty ? 10 : 10;
  }

  String _remainingLabel(Order o, Esim e) {
    // remaining = total - used (we don't store total GB on esim, approximate by _planGb)
    final totalMb = _planGb(o) * 1024;
    final remaining = (totalMb - e.dataUsedMb).clamp(0, totalMb);
    return '${(remaining / 1024).toStringAsFixed(1)} GB';
  }
}

class _UsageRing extends StatelessWidget {
  final double usedMb;
  final double totalGb;
  const _UsageRing({required this.usedMb, required this.totalGb});
  @override
  Widget build(BuildContext context) {
    final totalMb = math.max(totalGb * 1024, 1);
    final fraction = (usedMb / totalMb).clamp(0.0, 1.0);
    return Stack(
      alignment: Alignment.center,
      children: [
        SizedBox(
          width: 84, height: 84,
          child: CircularProgressIndicator(
            value: fraction,
            strokeWidth: 7,
            backgroundColor: Colors.white24,
            valueColor: const AlwaysStoppedAnimation(Colors.white),
          ),
        ),
        Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${(fraction * 100).toStringAsFixed(0)}%', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
        ]),
      ],
    );
  }
}

class _PaySheet extends StatelessWidget {
  final Order order;
  final List<PaymentGateway> gateways;
  final Future<void> Function(Order) onPayPal;
  final VoidCallback onDone;
  const _PaySheet({required this.order, required this.gateways, required this.onPayPal, required this.onDone});

  static const _icons = <String, IconData>{
    'alipay': Icons.account_balance_wallet,
    'wechat': Icons.chat_bubble,
    'paypal': Icons.account_balance,
    'stripe': Icons.credit_card,
    'bank': Icons.account_balance,
    'custom': Icons.payments,
    'mock': Icons.credit_card,
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
          ),
          const SizedBox(height: 18),
          Row(children: [
            const Text('选择支付方式', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const Spacer(),
            Text(formatInCurrency(order.total, order.currency), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.primary)),
          ]),
          const SizedBox(height: 14),
          if (gateways.isEmpty)
            const Text('暂无可用支付方式，请联系客服。', style: TextStyle(color: AppColors.muted)),
          ...gateways.map((g) => _row(context, g)),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, PaymentGateway g) {
    final icon = _icons[g.provider] ?? Icons.payments;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: AppColors.primary, size: 26),
      title: Text(g.label, style: const TextStyle(fontWeight: FontWeight.w700)),
      trailing: const Icon(Icons.chevron_right, color: AppColors.muted),
      onTap: () async {
        Navigator.pop(context);
        if (g.provider == 'paypal') {
          await onPayPal(order);
          return;
        }
        await _showInstructions(context, g);
      },
    );
  }

  Future<void> _showInstructions(BuildContext context, PaymentGateway g) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => Container(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).padding.bottom),
        decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
            ),
            const SizedBox(height: 18),
            Text('${g.label} 支付', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            if (g.qrUrl.isNotEmpty) ...[
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border)),
                  child: Image.network(g.qrUrl, width: 200, height: 200,
                      errorBuilder: (_, _, _) => const SizedBox(width: 200, height: 200, child: Icon(Icons.broken_image, color: AppColors.muted)),
                      loadingBuilder: (_, child, p) => p == null ? child : const SizedBox(width: 200, height: 200, child: Center(child: CircularProgressIndicator(strokeWidth: 2)))),
                ),
              ),
              const SizedBox(height: 14),
            ],
            Text(
              g.instructions.isNotEmpty
                  ? g.instructions
                  : '请按上述方式完成付款 ${formatInCurrency(order.total, order.currency)}，付款后联系客服或等待系统确认，完成后即可发放 eSIM。',
              style: const TextStyle(fontSize: 13.5, height: 1.5),
            ),
            const SizedBox(height: 8),
            Text('订单号：${order.orderNo}', style: const TextStyle(fontSize: 12, color: AppColors.muted)),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('我知道了'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QrSheet extends StatelessWidget {
  final Esim esim;
  final VoidCallback onCopied;
  const _QrSheet({required this.esim, required this.onCopied});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 18),
          const Text('扫描二维码激活 eSIM', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: AppColors.border)),
            child: QrImageView(data: esim.lpaCode, size: 220, version: QrVersions.auto, backgroundColor: Colors.white),
          ),
          const SizedBox(height: 16),
          _kv(context, 'ICCID', esim.iccid),
          _kv(context, '激活码', esim.lpaCode, copyable: true),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: esim.lpaCode));
              onCopied();
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('复制激活码'),
          ),
          const SizedBox(height: 10),
          const Text('设置 → 蜂窝网络 / eSIM → 添加 eSIM → 扫描二维码',
              style: TextStyle(fontSize: 11.5, color: AppColors.muted), textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v, {bool copyable = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(width: 66, child: Text(k, style: const TextStyle(color: AppColors.textSub, fontSize: 13))),
            Expanded(child: Text(v, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
            if (copyable)
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: v));
                  onCopied();
                },
                child: const Icon(Icons.copy, size: 15, color: AppColors.muted),
              ),
          ],
        ),
      );
}
