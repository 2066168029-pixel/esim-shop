import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../countries.dart';
import '../i18n.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets.dart';
import 'plan_detail_v2.dart';

class PlansScreen extends StatefulWidget {
  final String? initialCountry;
  final String? title;
  final void Function(int tab)? onGoTab;
  const PlansScreen({super.key, this.initialCountry, this.title, this.onGoTab});
  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  List<Plan>? _plans;
  String? _err;
  String _country = "";
  int? _dayFilter;
  String _q = "";

  @override
  void initState() {
    super.initState();
    _country = widget.initialCountry ?? "";
    _load();
  }

  Future<void> _load() async {
    setState(() { _plans = null; _err = null; });
    try {
      final app = context.read<AppState>();
      final p = await app.api.plans(
          country: _country.isEmpty ? null : _country,
          sort: "price",
          lang: app.lang.code);
      setState(() => _plans = p);
    } catch (e) {
      setState(() => _err = '$e');
    }
  }

  List<int> get _days {
    final set = <int>{for (final p in _plans ?? const <Plan>[]) p.validityDays};
    return set.toList()..sort();
  }

  List<Plan> get _filtered {
    var list = _plans ?? const <Plan>[];
    if (_dayFilter != null) list = list.where((p) => p.validityDays == _dayFilter).toList();
    if (_q.isNotEmpty) {
      final s = _q.toLowerCase();
      list = list.where((p) => p.title.toLowerCase().contains(s) || p.countryCode.toLowerCase().contains(s)).toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text(widget.title ?? (_country.isEmpty ? app.t.choosePlan : countryOf(_country).nameZh)),
        automaticallyImplyLeading: widget.title != null || _country.isNotEmpty,
      ),
      body: _err != null
          ? errorBox(_err!)
          : _plans == null
              ? loadingBox()
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
                      child: TextField(
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          hintText: app.t.searchDest,
                          prefixIcon: const Icon(Icons.search_rounded, size: 20, color: AppColors.muted),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 13),
                          fillColor: Colors.white,
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(13),
                            borderSide: const BorderSide(color: AppColors.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(13),
                            borderSide: const BorderSide(color: AppColors.primary, width: 1.6),
                          ),
                        ),
                        onChanged: (v) => setState(() => _q = v.trim()),
                      ),
                    ),
                    if (_days.length > 1) _dayStrip(app),
                    Expanded(
                      child: _filtered.isEmpty
                          ? emptyBox(app.t.noOrders, icon: Icons.sim_card_outlined)
                          : ListView.separated(
                              padding: const EdgeInsets.all(16),
                              itemCount: _filtered.length,
                              separatorBuilder: (_, i) => const SizedBox(height: 11),
                              itemBuilder: (_, i) => _PlanTile(plan: _filtered[i]),
                            ),
                    ),
                  ],
                ),
    );
  }

  Widget _dayStrip(AppState app) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _chip(app.t.allFilter, _dayFilter == null, () => setState(() => _dayFilter = null)),
          for (final d in _days) _chip('$d${app.t.days}', _dayFilter == d, () => setState(() => _dayFilter = d)),
        ],
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback tap) => Padding(
        padding: const EdgeInsets.only(right: 8, bottom: 6),
        child: GestureDetector(
          onTap: tap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
            decoration: BoxDecoration(
              color: on ? AppColors.primary : Colors.white,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: on ? AppColors.primary : AppColors.border, width: 1.2),
              boxShadow: on
                  ? [BoxShadow(color: AppColors.primary.withValues(alpha: .25), blurRadius: 10, offset: const Offset(0, 3))]
                  : null,
            ),
            alignment: Alignment.center,
            child: Text(label,
                style: TextStyle(
                  color: on ? Colors.white : AppColors.textSub,
                  fontSize: 13,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w600,
                )),
          ),
        ),
      );
}

class _PlanTile extends StatelessWidget {
  final Plan plan;
  const _PlanTile({required this.plan});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final t = app.t;

    // 标签：短周期=省钱，中周期=热门，长周期=超值
    final (tag, tagColor, tagBg) = plan.validityDays <= 7
        ? (t.budget, AppColors.orange, const Color(0xFFFFF3E8))
        : plan.validityDays <= 15
            ? (t.popular, AppColors.primary, AppColors.primaryWash)
            : (t.bestSeller, AppColors.gold, const Color(0xFFFFF8E6));

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadow.card,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => PlanDetailScreenV2(plan: plan)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(13),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ---------------- 左：封面 ----------------
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.network(
                        destinationPhoto(plan.countryCode, cover: plan.cover),
                        width: 72, height: 72, fit: BoxFit.cover,
                        errorBuilder: (_, e, st) => Container(
                          width: 72, height: 72,
                          decoration: const BoxDecoration(gradient: AppColors.heroBlue),
                          child: const Icon(Icons.public_rounded, color: Colors.white38, size: 28),
                        ),
                      ),
                    ),
                    if (plan.validityDays >= 30)
                      Positioned(
                        left: 0, bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: .55),
                            borderRadius: const BorderRadius.only(
                              topRight: Radius.circular(8),
                              bottomLeft: Radius.circular(12),
                            ),
                          ),
                          child: const Text('LONG',
                              style: TextStyle(
                                  color: Colors.white, fontSize: 8,
                                  fontWeight: FontWeight.w800, letterSpacing: .5)),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),

                // ---------------- 右：信息 ----------------
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 标题 + 标签
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              plan.title,
                              style: const TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w700,
                                  height: 1.35,
                                  letterSpacing: -.1),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
                            decoration: BoxDecoration(
                                color: tagBg, borderRadius: BorderRadius.circular(6)),
                            child: Text(tag,
                                style: TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w800,
                                    color: tagColor,
                                    letterSpacing: .2)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // 规格行
                      Row(
                        children: [
                          _spec(
                            Icons.bolt_rounded,
                            plan.dataGb > 0 ? '${_fmtGb(plan.dataGb)}' : 'Unlimited',
                          ),
                          const SizedBox(width: 10),
                          _spec(Icons.schedule_rounded, '${plan.validityDays}${t.days}'),
                          const SizedBox(width: 10),
                          _spec(Icons.network_cell_rounded, '4G/5G'),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // 价格 + 购买
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(app.price(plan.price),
                              style: const TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -.6,
                                  height: 1.0,
                                  fontFeatures: [FontFeature.tabularFigures()])),
                          const SizedBox(width: 5),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 1.5),
                            child: Text('/ ${plan.validityDays}${t.days}',
                                style: const TextStyle(fontSize: 10.5, color: AppColors.muted)),
                          ),
                          const Spacer(),
                          SizedBox(
                            height: 32,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                minimumSize: const Size(0, 32),
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(9)),
                                textStyle: const TextStyle(
                                    fontSize: 12.5, fontWeight: FontWeight.w700),
                              ),
                              onPressed: () => _buy(context),
                              child: Text(t.buy),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 1.0 → 1，1.5 → 1.5，10.0 → 10
  String _fmtGb(double gb) =>
      gb == gb.roundToDouble() ? '${gb.toInt()}GB' : '${gb}GB';

  Widget _spec(IconData icon, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12.5, color: AppColors.muted),
          const SizedBox(width: 3),
          Text(text,
              style: const TextStyle(
                  fontSize: 11.5, color: AppColors.textSub, fontWeight: FontWeight.w600)),
        ],
      );

  void _buy(BuildContext context) {
    final app = context.read<AppState>();
    app.addToCart(plan);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(
        children: [
          const Icon(Icons.check_circle_rounded, size: 18, color: Colors.white),
          const SizedBox(width: 9),
          Expanded(child: Text('${app.t.addedToCart}: ${plan.title}')),
        ],
      ),
      backgroundColor: AppColors.text,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      duration: const Duration(seconds: 2),
    ));
  }
}


