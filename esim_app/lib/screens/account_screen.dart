import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../currency.dart';
import '../i18n.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets.dart';
import 'info_pages.dart';
import 'login_screen.dart';
import 'orders_screen.dart';
import 'support_chat_screen.dart';

class AccountScreen extends StatefulWidget {
  final void Function(int tab)? onGoTab;
  const AccountScreen({super.key, this.onGoTab});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().refreshEsimStats();
    });
  }

  String _fmtGb(double gb) {
    if (gb <= 0) return '0 GB';
    if (gb >= 10) return '${gb.toStringAsFixed(0)} GB';
    return '${gb.toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final t = app.t;
    final loggedIn = app.isLoggedIn;
    final name = loggedIn ? (app.user?.fullName.isNotEmpty == true ? app.user!.fullName : 'User') : t.notLoggedIn;
    final email = loggedIn ? app.user!.email : t.logIn;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.skyBackground),
        child: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            children: [
              Row(
                children: [
                  Text(t.navMe, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
                  const Spacer(),
                  _topIcon(Icons.notifications_none_rounded, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationsPage()))),
                  const SizedBox(width: 10),
                  _topIcon(Icons.mail_outline_rounded, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SupportChatScreen()))),
                ],
              ),
              const SizedBox(height: 16),

              // profile card
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: AppColors.heroBlue,
                  borderRadius: BorderRadius.circular(AppRadii.big),
                  boxShadow: const [BoxShadow(color: Color(0x330A66FF), blurRadius: 22, offset: Offset(0, 10))],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 58, height: 58,
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.22), shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: Text(name.characters.first, style: const TextStyle(fontSize: 25, color: Colors.white, fontWeight: FontWeight.w800)),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white)),
                          const SizedBox(height: 3),
                          Text(email, style: const TextStyle(fontSize: 12.5, color: Colors.white70)),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(20)),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(Icons.verified, size: 13, color: Colors.white),
                              const SizedBox(width: 4),
                              Text(t.memberBadge, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                            ]),
                          ),
                        ],
                      ),
                    ),
                    if (!loggedIn)
                      TextButton(
                        style: TextButton.styleFrom(backgroundColor: Colors.white, foregroundColor: AppColors.primary),
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginScreen())),
                        child: Text(t.logIn),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // stats card
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(color: const Color(0xFFEAF2FF), borderRadius: BorderRadius.circular(AppRadii.card)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.sim_card_outlined, size: 18, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Text(t.myEsim, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                      const Spacer(),
                      if (loggedIn)
                        GestureDetector(
                          onTap: app.statsLoading ? null : () => context.read<AppState>().refreshEsimStats(),
                          child: const Icon(Icons.refresh, size: 17, color: AppColors.muted),
                        ),
                    ]),
                    const SizedBox(height: 14),
                    Row(children: [
                      _stat(t.activePlans, '${app.activeEsimCount}'),
                      _vline(),
                      _stat(t.totalData, _fmtGb(app.totalDataGb)),
                      _vline(),
                      _stat(t.dataUsed, _fmtGb(app.usedDataGb)),
                    ]),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              Row(children: [
                _actionCard(context, Icons.receipt_long_outlined, t.myOrders, () {
                  if (widget.onGoTab != null) {
                    widget.onGoTab!(3);
                  } else {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const OrdersScreen()));
                  }
                }),
                const SizedBox(width: 12),
                _actionCard(context, Icons.payments_outlined, t.payment, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PaymentPage()))),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                _actionCard(context, Icons.qr_code_2, t.qrCode, () => widget.onGoTab?.call(2)),
                const SizedBox(width: 12),
                _actionCard(context, Icons.support_agent, t.helpCenter, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SupportChatScreen()))),
              ]),
              const SizedBox(height: 18),

              AppCard(
                padding: EdgeInsets.zero,
                child: Column(children: [
                  _tile(context, Icons.notifications_none_rounded, t.notifications, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationsPage()))),
                  _divider(),
                  _tile(context, Icons.language, t.language, () => _pickLang(context), trailing: Text(app.lang.label, style: const TextStyle(color: AppColors.muted, fontSize: 13))),
                  _divider(),
                  _tile(context, Icons.attach_money, t.currency, () => _pickCurrency(context), trailing: Text(app.currency.code, style: const TextStyle(color: AppColors.muted, fontSize: 13))),
                  _divider(),
                  _tile(context, Icons.support_agent, t.helpCenter, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SupportChatScreen()))),
                  _divider(),
                  _tile(context, Icons.help_outline, t.faq, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpPage()))),
                  _divider(),
                  _tile(context, Icons.settings_outlined, t.settings, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage()))),
                  _divider(),
                  _tile(context, Icons.info_outline, t.aboutUs, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutPage()))),
                  if (loggedIn) ...[
                    _divider(),
                    _tile(context, Icons.logout, t.logOut, () async {
                      await context.read<AppState>().logout();
                    }, color: AppColors.danger),
                  ],
                ]),
              ),
              const SizedBox(height: 22),
              const Center(child: Text('Onlylink Travel eSIM · v1.0.8', style: TextStyle(fontSize: 11, color: AppColors.muted))),
            ],
          ),
        ),
      ),
    );
  }

  void _pickLang(BuildContext context) {
    final app = context.read<AppState>();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _sheet(context, app.t.language, AppLang.values, app.lang, (v) => v.label, (v) {
        app.setLang(v);
        Navigator.pop(context);
      }),
    );
  }

  void _pickCurrency(BuildContext context) {
    final app = context.read<AppState>();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _sheet(context, app.t.currency, AppCurrency.values, app.currency, (v) => '${v.code}  ${v.symbol}', (v) {
        app.setCurrency(v);
        Navigator.pop(context);
      }),
    );
  }

  Widget _sheet<T>(BuildContext context, String title, List<T> options, T current, String Function(T) labelOf, void Function(T) onPick) {
    return Container(
      padding: EdgeInsets.fromLTRB(16, 14, 16, 14 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 16),
          Padding(padding: const EdgeInsets.only(left: 4), child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
          const SizedBox(height: 8),
          // ListTile needs a Material ancestor for its ink splash; the white
          // Container above only paints a background, so without this wrapper
          // Flutter asserts and the rows lose their tap feedback.
          ...options.map((o) => Material(
                type: MaterialType.transparency,
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  title: Text(labelOf(o), style: TextStyle(fontWeight: o == current ? FontWeight.w800 : FontWeight.w500, color: o == current ? AppColors.primary : AppColors.text)),
                  trailing: o == current ? const Icon(Icons.check_circle, color: AppColors.primary) : null,
                  onTap: () => onPick(o),
                ),
              )),
        ],
      ),
    );
  }

  Widget _topIcon(IconData icon, VoidCallback onTap) => Container(
        width: 40, height: 40,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: const [BoxShadow(color: Color(0x0F1E3A8A), blurRadius: 12)]),
        child: Icon(icon, size: 21, color: AppColors.text),
      );

  Widget _stat(String k, String v) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(v, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.primary, letterSpacing: -0.4)),
            const SizedBox(height: 2),
            Text(k, style: const TextStyle(fontSize: 11.5, color: AppColors.textSub)),
          ],
        ),
      );

  Widget _vline() => Container(width: 1, height: 30, color: const Color(0xFFD4E3FA), margin: const EdgeInsets.symmetric(horizontal: 12));

  Widget _actionCard(BuildContext context, IconData icon, String label, VoidCallback onTap) => Expanded(
        child: AppCard(
          onTap: onTap,
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
          child: Column(
            children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(14)),
                child: Icon(icon, color: AppColors.primary, size: 22),
              ),
              const SizedBox(height: 10),
              Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      );

  Widget _tile(BuildContext context, IconData icon, String label, VoidCallback onTap, {Color? color, Widget? trailing}) {
    // These rows sit inside AppCard's white DecoratedBox; ListTile needs its own
    // Material directly above it for the splash, or Flutter asserts.
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
      leading: Container(
        width: 38, height: 38,
        decoration: BoxDecoration(color: (color ?? AppColors.primary).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
        child: Icon(icon, color: color ?? AppColors.primary, size: 20),
      ),
      title: Text(label, style: TextStyle(fontSize: 15, color: color ?? AppColors.text, fontWeight: FontWeight.w600)),
        trailing: trailing != null ? Row(mainAxisSize: MainAxisSize.min, children: [trailing, const SizedBox(width: 4), const Icon(Icons.chevron_right, size: 20, color: AppColors.muted)]) : const Icon(Icons.chevron_right, size: 20, color: AppColors.muted),
        onTap: onTap,
      ),
    );
  }

  Widget _divider() => const Divider(height: 1, indent: 66, color: AppColors.border);
}
