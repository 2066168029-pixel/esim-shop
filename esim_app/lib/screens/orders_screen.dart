import 'dart:math' as math;
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../api.dart';
import '../currency.dart';
import '../store.dart';
import '../theme.dart';
import '../topbar.dart';
import '../widgets.dart';
import 'info_pages.dart';
import 'login_screen.dart';
import 'order_detail_screen.dart';

class OrdersScreen extends StatefulWidget {
  final void Function(int tab)? onGoTab;
  const OrdersScreen({super.key, this.onGoTab});
  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  List<Order>? _orders;
  String? _err;
  int _tab = 0; // 0 all, 1 active, 2 expired, 3 pending

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final app = context.read<AppState>();
    if (!app.isLoggedIn) {
      setState(() => _orders = []);
      return;
    }
    setState(() { _orders = null; _err = null; });
    try {
      final o = await app.api.myOrders();
      setState(() => _orders = o);
    } catch (e) {
      setState(() => _err = '$e');
    }
  }

  List<Order> get _filtered {
    final list = _orders ?? const <Order>[];
    switch (_tab) {
      case 1:
        return list.where((o) => o.status == 'fulfilled' || o.status == 'active').toList();
      case 2:
        return list.where((o) => o.status == 'cancelled' || o.status == 'refunded').toList();
      case 3:
        return list.where((o) => o.status == 'pending' || o.status == 'paid' || o.status == 'issued').toList();
      default:
        return list;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final loggedIn = app.isLoggedIn;
    final t = app.t;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.skyBackground),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              const TopBar(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 20, 12),
                child: Row(
                  children: [
                    Text(t.myOrders, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
                    const Spacer(),
                    if (loggedIn) IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
                  ],
                ),
              ),
              if (loggedIn) _tabs(t),
              Expanded(
                child: !loggedIn
                    ? _needLogin(app)
                    : _err != null
                        ? errorBox(_err!)
                        : _orders == null
                            ? loadingBox()
                            : _filtered.isEmpty
                                ? emptyBox(t.noOrders, icon: Icons.sim_card_outlined)
                                : RefreshIndicator(onRefresh: _load, color: AppColors.primary, child: _list(app)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabs(dynamic t) {
    final labels = [t.tabAll, t.tabValid, t.tabPending, t.tabExpired];
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: labels.length,
        separatorBuilder: (_, i) => const SizedBox(width: 8),
        itemBuilder: (_, i) => GestureDetector(
          onTap: () => setState(() => _tab = i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
            decoration: BoxDecoration(
              color: _tab == i ? AppColors.primary : Colors.white,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                  color: _tab == i ? AppColors.primary : AppColors.border, width: 1.2),
              boxShadow: _tab == i
                  ? [BoxShadow(color: AppColors.primary.withValues(alpha: .25), blurRadius: 10, offset: const Offset(0, 3))]
                  : null,
            ),
            alignment: Alignment.center,
            child: Text(labels[i],
                style: TextStyle(
                    color: _tab == i ? Colors.white : AppColors.textSub,
                    fontSize: 13,
                    fontWeight: _tab == i ? FontWeight.w700 : FontWeight.w600)),
          ),
        ),
      ),
    );
  }

  Widget _needLogin(AppState app) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            emptyBox('${app.t.logIn} · ${app.t.myOrders}', icon: Icons.lock_outline),
            ElevatedButton(
              style: ElevatedButton.styleFrom(minimumSize: const Size(170, 50)),
              onPressed: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
                _load();
              },
              child: Text(app.t.logIn),
            ),
          ],
        ),
      );

  Widget _list(AppState app) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: _filtered.length,
      separatorBuilder: (_, i) => const SizedBox(height: 11),
      itemBuilder: (_, i) => _orderCard(app, _filtered[i]),
    );
  }

  Widget _orderCard(AppState app, Order o) {
    final t = app.t;
    final firstEsim = o.esims.isNotEmpty ? o.esims.first : null;
    final title = o.items.isNotEmpty ? o.items.first.title : 'eSIM';
    final gb = _estimateGb(o);
    final used = firstEsim?.dataUsedMb ?? 0;
    final remainMb = (gb * 1024 - used).clamp(0, gb * 1024);
    final pending = _isPending(o);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: pending ? const Color(0xFFFFE0B2) : AppColors.border),
        boxShadow: AppShadow.card,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openDetail(app, o),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
                child: Column(
                  children: [
                    // ---- 标题行 ----
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(title,
                              style: const TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w700,
                                  height: 1.35),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 8),
                        _statusPill(app, o.status),
                      ],
                    ),
                    const SizedBox(height: 9),
                    // ---- 单号 / 日期 / 金额 ----
                    Row(
                      children: [
                        Text(
                          o.createdAt != null
                              ? DateFormat('yyyy-MM-dd').format(o.createdAt!.toLocal())
                              : '',
                          style: const TextStyle(fontSize: 11, color: AppColors.muted),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          width: 2.5, height: 2.5,
                          decoration: const BoxDecoration(
                              color: AppColors.muted, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 8),
                        Text('No.${o.orderNo.length > 8 ? o.orderNo.substring(o.orderNo.length - 8) : o.orderNo}',
                            style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.muted,
                                fontFeatures: [FontFeature.tabularFigures()])),
                        const Spacer(),
                        Text(formatInCurrency(o.total, o.currency),
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -.35,
                                height: 1.1,
                                fontFeatures: [FontFeature.tabularFigures()])),
                      ],
                    ),
                  ],
                ),
              ),

              // ---- 待支付 CTA ----
              if (pending)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 13),
                  child: SizedBox(
                    width: double.infinity,
                    height: 40,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(0, 40),
                        backgroundColor: AppColors.warn,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => OrderDetailScreen(orderNo: o.orderNo))),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.payments_rounded, size: 17),
                          const SizedBox(width: 6),
                          Text(app.t.payNow,
                              style: const TextStyle(
                                  fontSize: 13.5, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                ),

              // ---- 流量用量 ----
              if (firstEsim != null) ...[
                Container(
                  margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surface2,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      SizedBox(width: 62, height: 62,
                          child: _UsageRing(usedMb: used, totalGb: gb)),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.dataBalance,
                                style: const TextStyle(fontSize: 10.5, color: AppColors.muted)),
                            const SizedBox(height: 2),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                Text((remainMb / 1024).toStringAsFixed(1),
                                    style: const TextStyle(
                                        fontSize: 21,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: -.6,
                                        height: 1.0,
                                        fontFeatures: [FontFeature.tabularFigures()])),
                                const SizedBox(width: 2),
                                const Text('GB',
                                    style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.muted)),
                              ],
                            ),
                            const SizedBox(height: 7),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: LinearProgressIndicator(
                                value: (used / (gb * 1024)).clamp(0.0, 1.0),
                                minHeight: 5,
                                backgroundColor: AppColors.border,
                                valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text('${t.used} ${(used / 1024).toStringAsFixed(1)} / ${gb} GB',
                                style: const TextStyle(fontSize: 10.5, color: AppColors.muted)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // ---- 操作按钮 ----
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 13),
                  child: Row(
                    children: [
                      Expanded(child: _ghostBtn(Icons.qr_code_2_rounded, t.viewQr, () => _showQr(app, firstEsim))),
                      const SizedBox(width: 8),
                      Expanded(child: _ghostBtn(Icons.replay_rounded, t.buyAgain, () => widget.onGoTab?.call(1))),
                      const SizedBox(width: 8),
                      Expanded(child: _ghostBtn(Icons.help_outline_rounded, t.help,
                          () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpPage())))),
                    ],
                  ),
                ),
              ] else
                const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ghostBtn(IconData icon, String label, VoidCallback onTap) => Material(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 14, color: AppColors.textSub),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSub)),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _statusPill(AppState app, String status) {
    final (color, _) = statusStyle(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
      child: Text(app.t.statusLabel(status), style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w700)),
    );
  }

  double _estimateGb(Order o) {
    for (final it in o.items) {
      final m = RegExp(r'(\d+(?:\.\d+)?)\s*GB', caseSensitive: false).firstMatch(it.title);
      if (m != null) return double.tryParse(m.group(1)!) ?? 10;
    }
    return 10;
  }

  static bool _isPending(Order o) =>
      o.status == 'pending' || o.status == 'pending_payment' || o.status == 'unpaid';

  /// Open the full order detail page (used for both paid and pending orders).
  Future<void> _openDetail(AppState app, Order o) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => OrderDetailScreen(orderNo: o.orderNo)));
    _load();
  }

  void _showQr(AppState app, Esim e) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => Container(
        padding: EdgeInsets.fromLTRB(20, 18, 20, 18 + MediaQuery.of(context).padding.bottom),
        decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: AppColors.border)),
              child: QrImageView(data: e.lpaCode, size: 210, version: QrVersions.auto, backgroundColor: Colors.white),
            ),
            const SizedBox(height: 14),
            Text(e.iccid, style: const TextStyle(fontSize: 12.5, color: AppColors.textSub)),
            const SizedBox(height: 6),
            Text(e.lpaCode, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: e.lpaCode));
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(app.t.copied), backgroundColor: AppColors.success, behavior: SnackBarBehavior.floating));
              },
              icon: const Icon(Icons.copy, size: 18),
              label: Text(app.t.copyCode),
            ),
          ],
        ),
      ),
    );
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
          width: 72, height: 72,
          child: CircularProgressIndicator(
            value: fraction,
            strokeWidth: 7,
            backgroundColor: AppColors.border,
            valueColor: const AlwaysStoppedAnimation(AppColors.primary),
          ),
        ),
        Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${(fraction * 100).toStringAsFixed(0)}%', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.text)),
        ]),
      ],
    );
  }
}
