import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../currency.dart';
import '../i18n.dart';
import '../store.dart';
import 'my_esims_screen.dart';
import 'my_recharges_screen.dart';
import '../theme.dart';
import '../widgets.dart';
import 'info_pages.dart';
import 'login_screen.dart';
import 'orders_screen.dart';
import 'invite_screen.dart';
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
                  Text(t.navMe,
                      style: const TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -.5,
                          height: 1.2)),
                  const Spacer(),
                  _topIcon(Icons.notifications_none_rounded,
                      () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationsPage()))),
                  const SizedBox(width: 9),
                  _topIcon(Icons.headset_mic_outlined,
                      () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SupportChatScreen()))),
                ],
              ),
              const SizedBox(height: 14),

              // profile card
              Container(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                decoration: BoxDecoration(
                  gradient: AppColors.heroBlue,
                  borderRadius: BorderRadius.circular(AppRadii.big),
                  boxShadow: AppShadow.hero,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 56, height: 56,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .18),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white.withValues(alpha: .3), width: 1.5),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        name.characters.first.toUpperCase(),
                        style: const TextStyle(
                            fontSize: 23, color: Colors.white, fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 17.5,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                  letterSpacing: -.2)),
                          const SizedBox(height: 3),
                          Text(email,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white.withValues(alpha: .75))),
                          if (loggedIn) ...[
                            const SizedBox(height: 9),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: .2),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                const Icon(Icons.verified_rounded, size: 12, color: Colors.white),
                                const SizedBox(width: 4),
                                Text(t.memberBadge,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700)),
                              ]),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (!loggedIn)
                      TextButton(
                        style: TextButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: AppColors.primary,
                          minimumSize: const Size(0, 34),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          textStyle: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                        onPressed: () => Navigator.push(
                            context, MaterialPageRoute(builder: (_) => const LoginScreen())),
                        child: Text(t.logIn),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // stats card —— 点击进入「我的卡」列表
              GestureDetector(
                onTap: loggedIn
                    ? () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const MyEsimsScreen()),
                        )
                    : null,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 15, 16, 14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(AppRadii.card),
                  border: Border.all(color: AppColors.border),
                  boxShadow: AppShadow.card,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Container(
                        width: 30, height: 30,
                        decoration: BoxDecoration(
                          color: AppColors.primaryWash,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: const Icon(Icons.sim_card_rounded,
                            size: 17, color: AppColors.primary),
                      ),
                      const SizedBox(width: 9),
                      Text(t.myEsim,
                          style: const TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w800)),
                      const Spacer(),
                      if (loggedIn)
                        GestureDetector(
                          onTap: app.statsLoading
                              ? null
                              : () => context.read<AppState>().refreshEsimStats(),
                          child: app.statsLoading
                              ? const SizedBox(
                                  width: 15, height: 15,
                                  child: CircularProgressIndicator(strokeWidth: 1.8))
                              : const Icon(Icons.refresh_rounded,
                                  size: 17, color: AppColors.muted),
                        ),
                    ]),
                    const SizedBox(height: 15),
                    Row(children: [
                      _stat(t.activePlans, '${app.activeEsimCount}'),
                      _vline(),
                      _stat(t.totalData, _fmtGb(app.totalDataGb)),
                      _vline(),
                      _stat(t.dataUsed, _fmtGb(app.usedDataGb), highlight: true),
                    ]),
                    if (app.totalDataGb > 0) ...[
                      const SizedBox(height: 15),
                      _usageBar(app),
                    ],
                    const SizedBox(height: 13),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                      decoration: BoxDecoration(
                        color: AppColors.surface2,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.list_alt_rounded,
                              size: 15, color: AppColors.primary),
                          const SizedBox(width: 6),
                          Text(t.viewMyCards,
                              style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primary)),
                          const Spacer(),
                          const Icon(Icons.chevron_right_rounded,
                              size: 17, color: AppColors.primary),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              ),
              const SizedBox(height: 16),

              Row(children: [
                _actionCard(context, Icons.receipt_long_rounded, t.myOrders, AppColors.primary, () {
                  if (widget.onGoTab != null) {
                    widget.onGoTab!(3);
                  } else {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const OrdersScreen()));
                  }
                }),
                const SizedBox(width: 10),
                _actionCard(context, Icons.account_balance_wallet_rounded, t.payment, AppColors.success,
                    () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PaymentPage()))),
                const SizedBox(width: 10),
                _actionCard(context, Icons.replay_rounded, t.rechargeRecords, AppColors.warn,
                    () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MyRechargesScreen()))),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                _actionCard(context, Icons.card_giftcard_rounded, t.inviteFriends, AppColors.orange,
                    () => Navigator.push(context, MaterialPageRoute(builder: (_) => const InviteScreen()))),
                const SizedBox(width: 10),
                _actionCard(context, Icons.headset_mic_rounded, t.helpCenter, const Color(0xFF0EA5E9),
                    () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SupportChatScreen()))),
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
                  _tile(context, Icons.lock_reset, t.changePassword, () => showChangePasswordSheet(context)),
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
              const Center(child: Text('Onlylink Travel eSIM · v1.4.0', style: TextStyle(fontSize: 11, color: AppColors.muted))),
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

  Widget _topIcon(IconData icon, VoidCallback onTap) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Icon(icon, size: 19, color: AppColors.textSub),
          ),
        ),
      );

  Widget _stat(String k, String v, {bool highlight = false}) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(v,
                style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.5,
                    height: 1.1,
                    color: highlight ? AppColors.orange : AppColors.text,
                    fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(height: 3),
            Text(k, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
          ],
        ),
      );

  /// 「我的 eSIM」总流量进度条 —— 已用 / 总量
  Widget _usageBar(dynamic app) {
    final total = app.totalDataGb as double;
    final used = app.usedDataGb as double;
    final pct = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    final over = pct > 0.85;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 7,
            backgroundColor: AppColors.borderSoft,
            valueColor: AlwaysStoppedAnimation(
              over ? const Color(0xFFEF4444) : AppColors.primary,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              '${(pct * 100).toStringAsFixed(1)}%',
              style: const TextStyle(fontSize: 11.5, color: AppColors.muted, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Text(
              '剩余 ${_fmtGb((total - used).clamp(0.0, total))}',
              style: const TextStyle(fontSize: 11.5, color: AppColors.muted),
            ),
          ],
        ),
      ],
    );
  }
  Widget _vline() => Container(width: 1, height: 28, color: AppColors.borderSoft, margin: const EdgeInsets.symmetric(horizontal: 10));

  Widget _actionCard(BuildContext context, IconData icon, String label, Color tint,
          VoidCallback onTap) =>
      Expanded(
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: tint.withValues(alpha: .11),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(icon, color: tint, size: 19),
                  ),
                  const SizedBox(height: 8),
                  Text(label,
                      style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSub),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
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


/// Change the password of the signed-in account.
///
/// Uses POST /api/auth/change-password, which requires the current password,
/// so a borrowed unlocked phone cannot be used to take over the account.
Future<void> showChangePasswordSheet(BuildContext context) async {
  final current = TextEditingController();
  final next = TextEditingController();
  final again = TextEditingController();
  var busy = false;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final insets = MediaQuery.of(ctx).viewInsets.bottom;
        void msg(String m, {bool ok = false}) {
          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
            content: Text(m),
            backgroundColor: ok ? AppColors.success : AppColors.danger,
            behavior: SnackBarBehavior.floating,
          ));
        }

        Future<void> submit() async {
          if (next.text.length < 6) return msg('新密码至少 6 位');
          if (next.text != again.text) return msg('两次输入的新密码不一致');
          setSheet(() => busy = true);
          try {
            await context.read<AppState>().api.changePassword(current.text, next.text);
            if (!ctx.mounted) return;
            Navigator.pop(ctx);
            msg('密码已修改', ok: true);
          } catch (e) {
            msg(e.toString().replaceFirst('Exception: ', ''));
          } finally {
            if (ctx.mounted) setSheet(() => busy = false);
          }
        }

        return Padding(
          padding: EdgeInsets.only(bottom: insets),
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 16),
              Text(context.read<AppState>().t.changePassword, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 16),
              TextField(controller: current, obscureText: true, decoration: const InputDecoration(labelText: '当前密码')),
              const SizedBox(height: 12),
              TextField(controller: next, obscureText: true, decoration: const InputDecoration(labelText: '新密码（至少 6 位）')),
              const SizedBox(height: 12),
              TextField(controller: again, obscureText: true, decoration: const InputDecoration(labelText: '确认新密码')),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: busy ? null : submit,
                child: busy
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('保存'),
              ),
            ]),
          ),
        );
      },
    ),
  );

  current.dispose();
  next.dispose();
  again.dispose();
}
