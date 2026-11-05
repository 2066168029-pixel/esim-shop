import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../countries.dart';
import '../i18n.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets.dart';
import 'checkout_screen.dart';

class CartScreen extends StatelessWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.read<AppState>().t;
    final app = context.watch<AppState>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text(t.ctTitle)),
      body: app.cart.isEmpty
          ? emptyBox(t.ctEmptyHint, icon: Icons.shopping_bag_outlined)
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
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadow.card,
      ),
      padding: const EdgeInsets.all(11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: Image.network(
              destinationPhoto(p.countryCode, cover: p.cover),
              width: 62, height: 62, fit: BoxFit.cover,
              errorBuilder: (_, e, s) => Container(
                width: 62, height: 62,
                decoration: const BoxDecoration(gradient: AppColors.heroBlue),
                child: const Icon(Icons.public_rounded, color: Colors.white38, size: 24),
              ),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(p.title,
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, height: 1.35),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                    ),
                    InkWell(
                      onTap: () => context.read<AppState>().removeLine(p.id),
                      borderRadius: BorderRadius.circular(20),
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.close_rounded, size: 16, color: AppColors.muted),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  '${c.nameZh} · ${p.dataGb > 0 ? '${p.dataGb}GB' : 'Voice'} · ${p.validityDays}天',
                  style: const TextStyle(fontSize: 11.5, color: AppColors.muted),
                ),
                const SizedBox(height: 9),
                Row(
                  children: [
                    Text(app.price(p.price * line.quantity),
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -.3,
                            fontFeatures: [FontFeature.tabularFigures()])),
                    const Spacer(),
                    _stepper(context, line),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepper(BuildContext context, CartLine line) {
    return Container(
      height: 30,
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        _stepBtn(Icons.remove_rounded,
            line.quantity <= 1 ? null : () => context.read<AppState>().setQty(line.plan.id, line.quantity - 1)),
        SizedBox(
          width: 24,
          child: Text('${line.quantity}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ),
        _stepBtn(Icons.add_rounded,
            line.quantity >= 20 ? null : () => context.read<AppState>().setQty(line.plan.id, line.quantity + 1)),
      ]),
    );
  }

  Widget _stepBtn(IconData icon, VoidCallback? onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: SizedBox(
          width: 30,
          height: 30,
          child: Icon(icon,
              size: 15,
              color: onTap == null ? AppColors.border : AppColors.textSub),
        ),
      );

  Widget _bar(BuildContext context, AppState app) {
    return Container(
      padding: EdgeInsets.fromLTRB(18, 14, 18, 14 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: Colors.white,
        border: const Border(top: BorderSide(color: AppColors.borderSoft)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F172A).withValues(alpha: .06),
            blurRadius: 22, offset: const Offset(0, -6),
          ),
        ],
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('合计 · ${app.cartCount} 件',
                  style: const TextStyle(fontSize: 11, color: AppColors.muted)),
              const SizedBox(height: 3),
              Text(app.price(app.cartTotal),
                  style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.6,
                      height: 1.0,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ],
          ),
          const Spacer(),
          SizedBox(
            width: 158,
            height: 46,
            child: ElevatedButton(
              onPressed: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => const CheckoutScreen())),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(0, 46),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('去结算', style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 3),
                  const Icon(Icons.arrow_forward_rounded, size: 17),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
