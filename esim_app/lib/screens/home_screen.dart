import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../countries.dart';
import '../i18n.dart';
import '../store.dart';
import '../theme.dart';
import '../topbar.dart';
import '../widgets.dart';
import 'support_chat_screen.dart';

class HomeScreen extends StatefulWidget {
  final void Function(int tab)? onGoTab;
  const HomeScreen({super.key, this.onGoTab});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Plan>? _plans;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _err = null; _plans = null; });
    try {
      final app = context.read<AppState>();
      final p = await app.api.plans(lang: app.lang.code);
      setState(() => _plans = p);
    } catch (e) {
      setState(() => _err = '$e');
    }
  }

  void _go(int tab) {
    if (widget.onGoTab != null) widget.onGoTab!(tab);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.watch<AppState>().t;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.skyBackground),
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: _load,
            color: AppColors.primary,
            child: CustomScrollView(
              slivers: [
                const SliverToBoxAdapter(child: TopBar(showBrand: true)),
                if (_err != null)
                  SliverFillRemaining(child: errorBox(_err!))
                else if (_plans == null)
                  SliverFillRemaining(hasScrollBody: false, child: loadingBox())
                else ...[
                  SliverToBoxAdapter(child: _hero(t)),
                  SliverToBoxAdapter(child: _quickActions(t)),
                  SliverToBoxAdapter(child: _sectionTitle(t.popularPlans, () => _go(1))),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    sliver: SliverList.separated(
                      itemCount: _plans!.take(4).length,
                      separatorBuilder: (_, i) => const SizedBox(height: 12),
                      itemBuilder: (_, i) => PlanCard(plan: _plans![i]),
                    ),
                  ),
                  SliverToBoxAdapter(child: _tipFooter(t)),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _hero(dynamic t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.travelEsim, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -1, height: 1.1)),
          const SizedBox(height: 2),
          Text(t.tagline, style: const TextStyle(fontSize: 13.5, color: AppColors.textSub)),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              gradient: AppColors.heroBlue,
              borderRadius: BorderRadius.circular(AppRadii.big),
              boxShadow: const [BoxShadow(color: Color(0x330A66FF), blurRadius: 24, offset: Offset(0, 12))],
            ),
            child: Stack(
              children: [
                Positioned.fill(child: ClipRRect(borderRadius: BorderRadius.circular(AppRadii.big), child: CustomPaint(painter: _WorldMapPainter()))),
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.sim_card, color: AppColors.gold, size: 24),
                          const SizedBox(width: 8),
                          Text(t.myEsim, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(20)),
                            child: Text(t.notLoggedIn, style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(t.noEsimYet, style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Text(t.pickDest, style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white, foregroundColor: AppColors.primary,
                              minimumSize: const Size(0, 42), padding: const EdgeInsets.symmetric(horizontal: 18),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: () => _go(1),
                            child: Text(t.buyEsim, style: const TextStyle(fontWeight: FontWeight.w800)),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white, side: const BorderSide(color: Colors.white54),
                              minimumSize: const Size(0, 42), padding: const EdgeInsets.symmetric(horizontal: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: () => _go(3),
                            child: Text(t.myPlans),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _quickActions(dynamic t) {
    final actions = [
      (Icons.download_rounded, t.buyEsim, () => _go(1)),
      (Icons.qr_code_scanner_rounded, t.scanQr, () => _go(2)),
      (Icons.receipt_long_outlined, t.myOrders, () => _go(3)),
      (Icons.support_agent, t.helpCenter, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SupportChatScreen()))),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 22, 8, 0),
      child: Row(
        children: actions.map((a) {
          return Expanded(
            child: Column(
              children: [
                InkWell(
                  onTap: a.$3,
                  borderRadius: BorderRadius.circular(30),
                  child: Container(
                    width: 58, height: 58,
                    decoration: BoxDecoration(
                      gradient: AppColors.heroBlue,
                      shape: BoxShape.circle,
                      boxShadow: const [BoxShadow(color: Color(0x330A66FF), blurRadius: 16, offset: Offset(0, 8))],
                    ),
                    child: Icon(a.$1, color: Colors.white, size: 26),
                  ),
                ),
                const SizedBox(height: 8),
                Text(a.$2, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.text), textAlign: TextAlign.center),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  /// Rotating travel tip from the content API (falls back to a default).
  Widget _tipFooter(dynamic t) {
    final app = context.read<AppState>();
    final tips = app.content['home_tip'] ?? const [];
    final lang = app.lang.code;
    String body = '';
    if (tips.isNotEmpty) {
      final match = tips.firstWhere((m) => m['lang'] == lang, orElse: () => tips.firstWhere((m) => (m['lang'] ?? '') == '', orElse: () => tips.first));
      body = (match['body'] ?? '').toString();
    }
    if (body.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: const Color(0xFFFFF8E6), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFFFE7A8))),
        child: Row(children: [
          const Icon(Icons.lightbulb_outline, size: 18, color: AppColors.warn),
          const SizedBox(width: 8),
          Expanded(child: Text(body, style: const TextStyle(fontSize: 12.5, color: AppColors.text))),
        ]),
      ),
    );
  }

  Widget _sectionTitle(String title, VoidCallback onAll) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 12),
      child: Row(
        children: [
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
          const Spacer(),
          GestureDetector(
            onTap: onAll,
            child: Text(context.read<AppState>().t.viewAll, style: const TextStyle(fontSize: 13, color: AppColors.primary, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _WorldMapPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final rnd = math.Random(7);
    for (int i = 0; i < 14; i++) {
      final start = Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
      final end = Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..quadraticBezierTo(size.width / 2, size.height * (0.2 + rnd.nextDouble() * 0.6), end.dx, end.dy);
      canvas.drawPath(path, paint);
    }
    final dot = Paint()..color = Colors.white.withValues(alpha: 0.5);
    for (int i = 0; i < 10; i++) {
      canvas.drawCircle(Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height), 1.6, dot);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Onlylink plan card with price shown in the selected currency.
class PlanCard extends StatelessWidget {
  final Plan plan;
  const PlanCard({super.key, required this.plan});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final t = app.t;
    return AppCard(
      padding: const EdgeInsets.all(12),
      onTap: () => _buy(context),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.network(destinationPhoto(plan.countryCode, cover: plan.cover), width: 68, height: 68, fit: BoxFit.cover,
                errorBuilder: (_, e, s) => Container(width: 68, height: 68, color: AppColors.skyDeep)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(plan.title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 6),
                Row(children: [
                  SoftTag(plan.dataGb > 0 ? '${plan.dataGb}GB' : t.support247, icon: Icons.bolt, color: AppColors.primary),
                  const SizedBox(width: 6),
                  SoftTag('${plan.validityDays}${t.days}', icon: Icons.schedule, color: AppColors.textSub),
                ]),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(app.price(plan.price), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.primary, letterSpacing: -0.5)),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => _buy(context),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(gradient: AppColors.heroBlue, borderRadius: BorderRadius.circular(11)),
                        child: Text(t.buy, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _buy(BuildContext context) {
    final app = context.read<AppState>();
    app.addToCart(plan);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${app.t.addedToCart}: ${plan.title}'),
      backgroundColor: AppColors.success,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }
}
