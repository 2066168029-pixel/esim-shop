import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../countries.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets.dart';
import 'checkout_screen.dart';

class CartScreen extends StatelessWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('购物车')),
      body: app.cart.isEmpty
          ? emptyBox('购物车还是空的\n去挑一个目的地吧', icon: Icons.shopping_bag_outlined)
          : Column(
              children: [
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: app.cart.length,
                    separatorBuilder: (_, i) => const SizedBox(height: 12),
                    itemBuilder: (_, i) => _line(context, app.cart[i], context.read<AppState>()),
                  ),
                ),
                _bar(context, app),
              ],
            ),
    );
  }

  Widget _line(BuildContext context, CartLine line, AppState app) {
    final p = line.plan;
    final c = countryOf(p.countryCode);
    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(destinationPhoto(p.countryCode, cover: p.cover), width: 56, height: 56, fit: BoxFit.cover,
                errorBuilder: (_, e, s) => Container(width: 56, height: 56, color: AppColors.skyDeep)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text('${c.nameZh} · ${p.dataGb > 0 ? '${p.dataGb}GB' : '语音'} · ${p.validityDays}天',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSub)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    PriceAccent(p.price, size: 16),
                    const Spacer(),
                    _stepper(context, line),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: AppColors.muted),
            onPressed: () => context.read<AppState>().removeLine(p.id),
          ),
        ],
      ),
    );
  }

  Widget _stepper(BuildContext context, CartLine line) {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFFF0F4FA), borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        _stepBtn(Icons.remove, () => context.read<AppState>().setQty(line.plan.id, line.quantity - 1)),
        SizedBox(width: 26, child: Text('${line.quantity}', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14))),
        _stepBtn(Icons.add, () => context.read<AppState>().setQty(line.plan.id, line.quantity + 1)),
      ]),
    );
  }

  Widget _stepBtn(IconData icon, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(padding: const EdgeInsets.all(6), child: Icon(icon, size: 16, color: AppColors.text)),
      );

  Widget _bar(BuildContext context, AppState app) {
    return Container(
      padding: EdgeInsets.fromLTRB(20, 14, 20, 14 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        boxShadow: [BoxShadow(color: Color(0x141E3A8A), blurRadius: 20, offset: Offset(0, -4))],
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [Text('合计', style: TextStyle(fontSize: 12, color: AppColors.textSub)), SizedBox(height: 2)],
          ),
          PriceText(app.cartTotal),
          const Spacer(),
          SizedBox(
            width: 168,
            child: ElevatedButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CheckoutScreen())),
              child: Text('去结算 (${app.cartCount})'),
            ),
          ),
        ],
      ),
    );
  }
}
