import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../currency.dart';
import '../store.dart';
import '../theme.dart';
import '../pay_icons.dart';
import '../widgets.dart';
import 'order_detail_screen.dart';

class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});
  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  final _email = TextEditingController();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _coupon = TextEditingController();
  final _notes = TextEditingController();

  CouponResult? _couponResult;
  // 现金券（人民币余额）：默认不用，用户显式勾选才抵扣
  bool _useVoucher = false;
  double _voucherBalance = 0;
  bool _busy = false;
  String _payMethod = "";

  // Payment channels loaded from the admin backend (GET /api/payments).
  List<PaymentGateway> _gateways = [];
  bool _loadingPayments = true;

  /// Fallback used only when the backend has no enabled channels configured.
  static const _fallback = [
    ("mock", "测试支付（Mock）", "mock"),
  ];

  @override
  void initState() {
    super.initState();
    _email.text = context.read<AppState>().user?.email ?? "";
    _loadPayments();
    _loadVoucher();
  }

  /// 现金券余额（人民币）。未登录或接口失败时保持 0，界面自然不显示开关。
  Future<void> _loadVoucher() async {
    final app = context.read<AppState>();
    if (!app.isLoggedIn) return;
    try {
      final v = await app.api.myVoucher();
      if (!mounted) return;
      setState(() {
        _voucherBalance = (v['balance'] as num?)?.toDouble() ?? 0;
      });
    } catch (_) {
      // 忽略：没有现金券就不显示抵扣入口
    }
  }

  Future<void> _loadPayments() async {
    try {
      final list = await context.read<AppState>().api.paymentGateways();
      if (!mounted) return;
      setState(() {
        _gateways = list;
        _loadingPayments = false;
        if (_gateways.isNotEmpty) {
          _payMethod = _gateways.first.provider;
        } else {
          _payMethod = _fallback.first.$1;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingPayments = false;
        _payMethod = _fallback.first.$1;
      });
    }
  }

  @override
  void dispose() {
    for (final c in [_email, _name, _phone, _address, _coupon, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _needsShipping => context.read<AppState>().cart.any((l) => !l.plan.isEsim);

  double get _subtotal => context.read<AppState>().cartTotal;
  double get _discount => _couponResult?.valid == true ? _couponResult!.discount : 0;
  double get _total => (_subtotal - _discount).clamp(0, double.infinity);

  Future<void> _applyCoupon() async {
    if (_coupon.text.trim().isEmpty) return;
    try {
      final r = await context.read<AppState>().api.applyCoupon(_coupon.text.trim(), _subtotal);
      setState(() => _couponResult = r);
      _snack(r.message, error: !r.valid);
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

  Future<void> _submit() async {
    final app = context.read<AppState>();
    if (_email.text.trim().isEmpty) {
      _snack('请填写邮箱', error: true);
      return;
    }
    if (_needsShipping && _address.text.trim().isEmpty) {
      _snack('实体卡需要填写收货地址', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final order = await app.api.checkout(
        useVoucher: _useVoucher && _voucherBalance > 0,
        items: app.cart.map((l) => {"plan_id": l.plan.id, "quantity": l.quantity}).toList(),
        email: _email.text.trim(),
        couponCode: _couponResult?.valid == true ? _couponResult!.code : "",
        paymentProvider: _payMethod.isEmpty ? "mock" : _payMethod,
        currency: app.currency.code,
        shipName: _name.text.trim(),
        shipPhone: _phone.text.trim(),
        shipAddress: _address.text.trim(),
        notes: _notes.text.trim(),
      );
      app.clearCart();
      if (!mounted) return;
      // Alipay/WeChat are paid from the order page (H5 cashier / instructions),
      // so carry the chosen channel through instead of making the user pick
      // again.
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => OrderDetailScreen(
            orderNo: order.orderNo,
            autoPay: _payMethod,
          ),
        ),
      );
    } catch (e) {
      _snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final t = app.t;
    return Scaffold(
      appBar: AppBar(title: const Text('确认订单')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('联系方式', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                const SizedBox(height: 12),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(hintText: '邮箱（用于接收 eSIM）'),
                ),
              ],
            ),
          ),
          if (_needsShipping) ...[
            const SizedBox(height: 12),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('收货信息（实体卡）', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  const SizedBox(height: 12),
                  TextField(controller: _name, decoration: const InputDecoration(hintText: '收件人姓名')),
                  const SizedBox(height: 10),
                  TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(hintText: '联系电话')),
                  const SizedBox(height: 10),
                  TextField(controller: _address, maxLines: 3, decoration: const InputDecoration(hintText: '收货地址', alignLabelWithHint: true)),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('优惠码', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _coupon,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(hintText: '输入优惠码，如 WELCOME10'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(minimumSize: const Size(80, 50)),
                      onPressed: _applyCoupon,
                      child: const Text('使用'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('支付方式', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                const SizedBox(height: 8),
                if (_loadingPayments)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Center(
                      child: SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else if (_gateways.isNotEmpty)
                  ..._gateways.map((g) => _gatewayTile(g))
                else
                  ..._fallback.map((f) => _payTile(f.$1, Icons.credit_card, AppColors.muted, f.$2)),
                ..._gateways.where((g) => g.instructions.trim().isNotEmpty).map(
                      (g) => Padding(
                        padding: const EdgeInsets.only(top: 6, left: 4, right: 4),
                        child: Text(
                          g.instructions,
                          style: const TextStyle(fontSize: 11, color: AppColors.muted),
                        ),
                      ),
                    ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          AppCard(
            child: Column(
              children: [
                _amountRow('商品小计', _subtotal),
                if (_discount > 0) _amountRow('优惠（${_couponResult!.code}）', -_discount),
                if (app.isLoggedIn && _voucherBalance > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.redeem_rounded,
                            size: 17, color: AppColors.success),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${t.useVoucher}（¥${_voucherBalance.toStringAsFixed(2)}）',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        Switch(
                          value: _useVoucher,
                          onChanged: (v) => setState(() => _useVoucher = v),
                        ),
                      ],
                    ),
                  ),
                const Divider(height: 22),
                Row(
                  children: [
                    const Text('应付金额', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    const Spacer(),
                    Text(context.read<AppState>().price(_total),
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.primary)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text('支付 ${context.read<AppState>().price(_total)}'),
          ),
          const SizedBox(height: 8),
          const Text('支付方式由后台配置，实时同步。',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: AppColors.muted)),
        ],
      ),
    );
  }

  Widget _payTile(String value, IconData icon, Color color, String label) {
    final selected = _payMethod == value;
    return RadioListTile<String>(
      value: value,
      groupValue: _payMethod,
      onChanged: (v) => setState(() => _payMethod = v ?? value),
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Row(children: [
        if (PayIcons.iconUrl(value).isNotEmpty)
          SizedBox(width: 28, child: PayIcon(provider: value, size: 22))
        else
          Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Text(label),
      ]),
      selected: selected,
    );
  }

  static const _providerIcons = <String, IconData>{
    'alipay': Icons.account_balance_wallet,
    'wechat': Icons.chat_bubble,
    'paypal': Icons.account_balance,
    'stripe': Icons.credit_card,
    'bank': Icons.account_balance,
    'custom': Icons.payments,
    'mock': Icons.credit_card,
  };

  static const _providerColors = <String, Color>{
    'alipay': Color(0xFF1677FF),
    'wechat': Color(0xFF07C160),
    'paypal': Color(0xFF003087),
    'stripe': Color(0xFF635BFF),
    'bank': Color(0xFF6B7280),
    'custom': Color(0xFF6B7280),
    'mock': Color(0xFF9CA3AF),
  };

  Widget _gatewayTile(PaymentGateway g) {
    final icon = _providerIcons[g.provider] ?? Icons.payments;
    final color = _providerColors[g.provider] ?? AppColors.muted;
    final selected = _payMethod == g.provider;
    return RadioListTile<String>(
      value: g.provider,
      groupValue: _payMethod,
      onChanged: (v) => setState(() => _payMethod = v ?? g.provider),
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Row(children: [
        if (PayIcons.iconUrl(g.provider).isNotEmpty)
          SizedBox(width: 28, child: PayIcon(provider: g.provider, size: 22))
        else
          Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Text(g.label),
      ]),
      subtitle: g.mode == 'live'
          ? null
          : const Text('人工确认', style: TextStyle(fontSize: 11, color: AppColors.muted)),
      selected: selected,
    );
  }

  Widget _amountRow(String label, double v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
            const Spacer(),
            Text(v < 0 ? '-${context.read<AppState>().price(-v)}' : context.read<AppState>().price(v),
                style: const TextStyle(fontSize: 13)),
          ],
        ),
      );
}
