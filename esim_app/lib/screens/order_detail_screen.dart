import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api.dart';
import '../currency.dart';
import '../i18n.dart';
import '../store.dart';
import '../theme.dart';
import '../pay_icons.dart';
import '../payment_return.dart';
import '../widgets.dart';

class OrderDetailScreen extends StatefulWidget {
  final String orderNo;
  const OrderDetailScreen({super.key, required this.orderNo});
  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  L get t => context.read<AppState>().t;

  Order? _order;
  String? _err;

  /// Guards the PayPal capture button while the request is in flight, so a
  /// double tap cannot fire two captures.
  bool _busyPay = false;

  /// 正在等支付结果（从浏览器 / 支付宝回来后核对中）。
  bool _confirmingPay = false;

  /// App 回到前台时自动核对订单 —— 付款完成不需要用户再点一次。
  late final PaymentReturnWatcher _payWatcher = PaymentReturnWatcher(
    onReturn: () {
      if (!mounted) return;
      setState(() => _confirmingPay = true);
    },
    onCheck: _confirmPaymentResult,
  );

  @override
  void initState() {
    super.initState();
    _payWatcher.attach();
    _load();
  }

  @override
  void dispose() {
    _payWatcher.detach();
    super.dispose();
  }

  /// 回到前台后确认这笔订单到底付没付。
  ///
  /// 支付宝走的是服务端异步通知，钱在服务端就已经结清了，这里只是查结果；
  /// PayPal 还差一步 capture，需要在这里补上。两种都幂等，重复问不会重复扣款。
  Future<bool> _confirmPaymentResult() async {
    final api = context.read<AppState>().api;
    final orderNo = PendingPayment.instance.orderNo ?? widget.orderNo;
    final provider = PendingPayment.instance.provider ?? '';

    try {
      if (provider == 'paypal') {
        // capture 本身就带结算，成功即结束
        final r = await api.paypalCapture(orderNo);
        final st = r['status'] as String? ?? '';
        final ok = r['ok'] == true || st == 'paid' || st == 'fulfilled';
        if (ok) {
          PendingPayment.instance.markSettled(orderNo);
          if (mounted) {
            setState(() => _confirmingPay = false);
            _snack(t.odPaySuccess);
            await _load();
          }
        }
        return ok;
      }

      // Stripe 和支付宝一样：后端结算，这里只问结果
      if (provider == 'stripe') {
        final r = await api.stripeStatus(orderNo);
        final st = r['status'] as String? ?? '';
        final paid = st == 'paid' || st == 'fulfilled';
        if (paid) {
          PendingPayment.instance.markSettled(orderNo);
          if (mounted) {
            setState(() => _confirmingPay = false);
            _snack(t.odPaySuccess);
            await _load();
          }
          return true;
        }
        if (mounted) await _load();
        return false;
      }

      // 支付宝：问后端拿到的是权威状态
      final r = await api.alipayStatus(orderNo);
      final st = r['status'] as String? ?? '';
      final paid = st == 'paid' || st == 'fulfilled';
      if (paid) {
        PendingPayment.instance.markSettled(orderNo);
        if (mounted) {
          setState(() => _confirmingPay = false);
          _snack(t.odPaySuccess);
          await _load();
        }
        return true;
      }
      if (mounted) await _load();
      return false;
    } catch (_) {
      return false;
    }
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
      _snack(t.odUsedMb(e.dataUsedMb.toStringAsFixed(1)));
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
      builder: (_) => _QrSheet(esim: e, onCopied: () => _snack(t.odCodeCopied)),
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
        onAlipay: _payWithAlipay,
        onStripe: _payWithStripe,
        onDone: () => _load(),
      ),
    );
  }

  Future<void> _payWithPayPal(Order o) async {
    final api = context.read<AppState>().api;
    try {
      final res = await api.paypalCreate(o.orderNo);
      final url = res['approve_url'] as String? ?? '';
      if (url.isEmpty) {
        _snack(t.odPaypalFailed, error: true);
        return;
      }
      // 记下这笔支付，App 回到前台时会自动核对结果 —— 不需要用户再点确认。
      PendingPayment.instance.begin(o.orderNo, 'paypal');

      final uri = Uri.tryParse(url);
      if (uri != null) {
        final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (!opened) {
          PendingPayment.instance.clear();
          _snack(t.odPaypalFailed, error: true);
          return;
        }
      }

      // 用户可能没付就回来了，这里只提示「已跳转」，结果由 watcher 判定。
      _snack(t.odOrderKept);
    } catch (e) {
      _snack('$e', error: true);
    }
  }

  /// 支付宝 App 支付。
  ///
  /// 服务端签名出 orderString，App 拉起支付宝。付款完成后支付宝自己回到本 App，
  /// App 回到前台时由 _payWatcher 自动确认结果 —— 用户什么都不用点。
  Future<void> _payWithAlipay(Order o) async {
    final api = context.read<AppState>().api;
    setState(() => _busyPay = true);
    try {
      final res = await api.alipayCreate(o.orderNo);
      final orderString = res['order_string'] as String? ?? '';
      if (orderString.isEmpty) {
        _snack('支付宝下单失败：服务端没有返回 order_string', error: true);
        return;
      }

      PendingPayment.instance.begin(o.orderNo, 'alipay');

      // 支付宝 SDK 由原生侧提供（alipay_kit 插件）。没有装插件时退化成
      // 「记下这笔支付，回前台再查状态」，至少不会丢单。
      final ok = await _invokeAlipay(orderString);
      if (!ok) {
        PendingPayment.instance.clear();
        _snack('未检测到支付宝客户端，请先安装支付宝', error: true);
        return;
      }
    } catch (e) {
      PendingPayment.instance.clear();
      _snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _busyPay = false);
    }
  }

  /// Stripe 结账。
  ///
  /// Stripe 只认浏览器：服务端建 Checkout Session，App 用外部浏览器打开，
  /// 付完 Stripe 把用户重定向到 success_url，用户关掉浏览器就回到 App。
  /// 回来时 _payWatcher 自动查状态，和支付宝同一条路径。
  Future<void> _payWithStripe(Order o) async {
    final api = context.read<AppState>().api;
    setState(() => _busyPay = true);
    try {
      final res = await api.stripeCreate(
        o.orderNo,
        successUrl: 'https://8.218.203.94.nip.io/pay-return?order=${o.orderNo}',
      );
      final url = res['url'] as String? ?? '';
      if (url.isEmpty) {
        _snack('Stripe 下单失败：服务端没有返回跳转地址', error: true);
        return;
      }

      PendingPayment.instance.begin(o.orderNo, 'stripe');

      final uri = Uri.tryParse(url);
      final opened = uri != null &&
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) {
        PendingPayment.instance.clear();
        _snack('打不开浏览器，无法完成 Stripe 支付', error: true);
      }
    } catch (e) {
      PendingPayment.instance.clear();
      _snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _busyPay = false);
    }
  }

  /// 调起支付宝。走 MethodChannel，原生侧没实现时返回 false。
  Future<bool> _invokeAlipay(String orderString) async {
    const ch = MethodChannel('onlylink/alipay');
    try {
      final r = await ch.invokeMethod<String>('pay', {"orderString": orderString});
      // 9000 = 支付成功；6001 = 用户取消；其余为失败。
      // 这里不信任返回码，最终以服务端状态为准，返回码只用来决定要不要继续等。
      return r != null;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Cancel a still-pending order, with a confirmation step.
  Future<void> _cancelOrder(Order o) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t.odCancelOrder),
        content: Text('${t.odCancelConfirm}，请先联系客服。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.odBack)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: Text(t.odConfirmCancel),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;

    try {
      final api = context.read<AppState>().api;
      await api.cancelOrder(o.orderNo);
      if (!mounted) return;
      _snack(t.odCancelled);
      await _load();
    } catch (e) {
      if (mounted) _snack(t.odCancelFailed('$e'), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text(t.odTitle)),
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
                  Expanded(child: Text(t.odNumber(o.orderNo), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5))),
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
                    Text('${t.odDiscount} ${o.couponCode}', style: const TextStyle(color: AppColors.success, fontSize: 13.5)),
                    const Spacer(),
                    Text('-${formatInCurrency(o.discount, o.currency)}', style: const TextStyle(fontSize: 13.5, color: AppColors.success)),
                  ]),
                ),
              const Divider(height: 24),
              Row(children: [
                Text(t.odTotal, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
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
              Text(t.odAwaitPay, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              const Spacer(),
                Text(formatInCurrency(o.total, o.currency), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            ]),
            const SizedBox(height: 6),
            const Text('请完成付款，付款后系统将自动发放 eSIM。', style: TextStyle(fontSize: 12.5, color: AppColors.textSub)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: (_busyPay || _confirmingPay) ? null : () => _payNow(o),
                child: _busyPay
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Text(t.odGoPay),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: _busyPay ? null : () => _cancelOrder(o),
                child: Text(
                  t.odCancelOrder,
                  style: TextStyle(color: AppColors.danger, fontSize: 13),
                ),
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
                      Text(t.odDataBalance, style: TextStyle(color: Colors.white70, fontSize: 12)),
                      Text(_remainingLabel(o, e), style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                      const SizedBox(height: 6),
                      Text(t.odUsedMb(e.dataUsedMb.toStringAsFixed(1)),
                          style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      if (e.expiresAt != null)
                        Text(t.odValidUntil(DateFormat('yyyy-MM-dd').format(e.expiresAt!.toLocal())),
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
                    child: Text(t.odViewQr, style: TextStyle(fontWeight: FontWeight.w800)),
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
                    child: Text(t.odRefreshUsage, style: TextStyle(fontWeight: FontWeight.w800)),
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
  final Future<void> Function(Order) onAlipay;
  final Future<void> Function(Order) onStripe;
  final VoidCallback onDone;
  const _PaySheet({required this.order, required this.gateways, required this.onPayPal,
      required this.onAlipay, required this.onStripe, required this.onDone});

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
    final t = context.read<AppState>().t;
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
            Text(t.odChoosePayment, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const Spacer(),
            Text(formatInCurrency(order.total, order.currency), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.primary)),
          ]),
          const SizedBox(height: 14),
          if (gateways.isEmpty)
            Text(t.odNoPayment, style: TextStyle(color: AppColors.muted)),
          ...gateways.map((g) => _row(context, g)),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, PaymentGateway g) {
    final icon = _icons[g.provider] ?? Icons.payments;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: SizedBox(
        width: 34,
        child: PayIcons.iconUrl(g.provider).isNotEmpty
            ? Center(child: PayIcon(provider: g.provider, size: 26))
            : Icon(icon, color: AppColors.primary, size: 26),
      ),
      title: Text(g.label, style: const TextStyle(fontWeight: FontWeight.w700)),
      trailing: const Icon(Icons.chevron_right, color: AppColors.muted),
      onTap: () async {
        Navigator.pop(context);
        if (g.provider == 'paypal') {
          await onPayPal(order);
          return;
        }
        if (g.provider == 'alipay') {
          await onAlipay(order);
          return;
        }
        if (g.provider == 'stripe') {
          await onStripe(order);
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
            Text(context.read<AppState>().t.odPayWith(g.label), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
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
                child: Text(context.read<AppState>().t.odGotIt),
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
    final t = context.read<AppState>().t;
    return Container(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 18),
          Text(t.odScanQrActivate, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: AppColors.border)),
            child: QrImageView(data: esim.lpaCode, size: 220, version: QrVersions.auto, backgroundColor: Colors.white),
          ),
          const SizedBox(height: 16),
          _kv(context, 'ICCID', esim.iccid),
          _kv(context, t.odActivationCode, esim.lpaCode, copyable: true),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: esim.lpaCode));
              onCopied();
            },
            icon: const Icon(Icons.copy, size: 18),
            label: Text(t.odCopyCode),
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
