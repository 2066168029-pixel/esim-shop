import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../currency.dart';
import '../i18n.dart';
import '../store.dart';
import '../theme.dart';
import 'support_chat_screen.dart';

/// A simple titled scaffold used by the "info" pages below.
class _SimplePage extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _SimplePage({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text(title)),
      body: ListView(padding: const EdgeInsets.all(16), children: children),
    );
  }
}

Widget _card(BuildContext context, List<Widget> children) => Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppRadii.card), boxShadow: const [BoxShadow(color: Color(0x0F1E3A8A), blurRadius: 18, offset: Offset(0, 8))]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );

// ---------------- Help Center / FAQ ----------------
class HelpPage extends StatelessWidget {
  const HelpPage({super.key});
  @override
  Widget build(BuildContext context) {
    final t = context.watch<AppState>().t;
    final faqs = [
      (t.faq1Q, t.faq1A),
      (t.faq2Q, t.faq2A),
      (t.faq3Q, t.faq3A),
      (t.faq4Q, t.faq4A),
      (t.faq5Q, t.faq5A),
    ];
    return _SimplePage(
      title: t.helpCenter,
      children: [
        _card(context, [
          Row(children: [
            Container(width: 44, height: 44, decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(14)), child: const Icon(Icons.support_agent, color: AppColors.primary)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.support247, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                Text(t.helpOnline, style: TextStyle(color: AppColors.textSub, fontSize: 12.5)),
              ]),
            ),
            FilledButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SupportChatScreen())), child: Text(t.contactSupport)),
          ]),
        ]),
        Text(t.faq, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        const SizedBox(height: 10),
        ...faqs.map((q) => _card(context, [
              Text(q.$1, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              const SizedBox(height: 6),
              Text(q.$2, style: const TextStyle(color: AppColors.textSub, fontSize: 13, height: 1.5)),
            ])),
      ],
    );
  }
}

// ---------------- Notifications ----------------
class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final t = context.watch<AppState>().t;
    final items = [
      (Icons.campaign_outlined, t.notif1T, t.notif1B),
      (Icons.receipt_long_outlined, t.notif2T, t.notif2B),
      (Icons.card_giftcard_outlined, t.notif3T, t.notif3B),
    ];
    return _SimplePage(
      title: t.notifications,
      children: items
          .map((e) => _card(context, [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(width: 40, height: 40, decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)), child: Icon(e.$1, color: AppColors.primary, size: 20)),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(e.$2, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                    const SizedBox(height: 4),
                    Text(e.$3, style: const TextStyle(color: AppColors.textSub, fontSize: 12.5, height: 1.5)),
                  ])),
                ]),
              ]))
          .toList(),
    );
  }
}

// ---------------- Payment methods ----------------
class PaymentPage extends StatelessWidget {
  const PaymentPage({super.key});
  @override
  Widget build(BuildContext context) {
    final t = context.watch<AppState>().t;
    return _SimplePage(
      title: t.payment,
      children: [
        _card(context, [
          Row(children: [
            const Icon(Icons.chat_bubble, color: Color(0xFF22C55E), size: 26),
            const SizedBox(width: 12),
            Expanded(child: Text(t.payWechat, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
            const Icon(Icons.check_circle, color: AppColors.primary, size: 20),
          ]),
        ]),
        _card(context, [
          Row(children: [
            Icon(Icons.account_balance_wallet, color: Color(0xFF3B82F6), size: 26),
            SizedBox(width: 12),
            Expanded(child: Text(t.payAlipay, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
          ]),
        ]),
        _card(context, [
          Row(children: [
            Icon(Icons.credit_card, color: AppColors.textSub, size: 26),
            SizedBox(width: 12),
            Expanded(child: Text(t.payCard, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
          ]),
        ]),
        const SizedBox(height: 4),
        Text(t.payChannelsSoon, style: TextStyle(color: AppColors.muted, fontSize: 12)),
      ],
    );
  }
}

// ---------------- Settings ----------------
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final t = app.t;
    return _SimplePage(
      title: t.settings,
      children: [
        _card(context, [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t.language),
            trailing: Text(app.lang.label, style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700)),
            onTap: () => showModalBottomSheet(
              context: context,
              backgroundColor: Colors.transparent,
              builder: (_) => Container(
                decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
                padding: const EdgeInsets.all(16),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: 14),
                  ...AppLang.values.map((l) => ListTile(
                        title: Text(l.label, style: TextStyle(fontWeight: l == app.lang ? FontWeight.w800 : FontWeight.w500, color: l == app.lang ? AppColors.primary : AppColors.text)),
                        trailing: l == app.lang ? const Icon(Icons.check_circle, color: AppColors.primary) : null,
                        onTap: () { app.setLang(l); Navigator.pop(context); },
                      )),
                ]),
              ),
            ),
          ),
        ]),
        _card(context, [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t.currency),
            trailing: Text(app.currency.code, style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700)),
            onTap: () => showModalBottomSheet(
              context: context,
              backgroundColor: Colors.transparent,
              builder: (_) => Container(
                decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
                padding: const EdgeInsets.all(16),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: 14),
                  ...AppCurrency.values.map((c) => ListTile(
                        title: Text('${c.code}  ${c.symbol}', style: TextStyle(fontWeight: c == app.currency ? FontWeight.w800 : FontWeight.w500, color: c == app.currency ? AppColors.primary : AppColors.text)),
                        trailing: c == app.currency ? const Icon(Icons.check_circle, color: AppColors.primary) : null,
                        onTap: () { app.setCurrency(c); Navigator.pop(context); },
                      )),
                ]),
              ),
            ),
          ),
        ]),
        _card(context, [
          ListTile(contentPadding: EdgeInsets.zero, title: Text(t.settingsClearCache), trailing: const Icon(Icons.chevron_right), onTap: () => _snack(context, t.cacheCleared)),
        ]),
      ],
    );
  }
}

// ---------------- About ----------------
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});
  @override
  Widget build(BuildContext context) {
    final t = context.read<AppState>().t;
    return _SimplePage(
      title: t.aboutUs,
      children: [
        _card(context, [
          Row(children: [
            Container(width: 56, height: 56, decoration: const BoxDecoration(gradient: AppColors.heroBlue, borderRadius: BorderRadius.all(Radius.circular(16))), child: const Icon(Icons.sim_card, color: Colors.white, size: 28)),
            const SizedBox(width: 14),
            const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Onlylink eSIM', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              SizedBox(height: 4),
              Text('\${appVersion()} ', style: TextStyle(color: AppColors.textSub, fontSize: 12.5)),
            ]),
          ]),
        ]),
        _card(context, [
          Text(t.aboutSlogan,
              style: TextStyle(fontSize: 13.5, height: 1.6, color: AppColors.text)),
        ]),
        _card(context, [
          ListTile(contentPadding: EdgeInsets.zero, title: Text(t.termsOfService), trailing: const Icon(Icons.chevron_right), onTap: () => _snack(context, t.openTerms)),
        ]),
      ],
    );
  }
}

void _snack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: AppColors.success, behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2)));
}
