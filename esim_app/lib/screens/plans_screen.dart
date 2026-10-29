import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../countries.dart';
import '../i18n.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets.dart';

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
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: TextField(
                        decoration: InputDecoration(hintText: app.t.searchDest, prefixIcon: const Icon(Icons.search, color: AppColors.muted)),
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
                              separatorBuilder: (_, i) => const SizedBox(height: 12),
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
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: BoxDecoration(
              color: on ? AppColors.primary : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: on ? AppColors.primary : AppColors.border, width: 1.2),
            ),
            alignment: Alignment.center,
            child: Text(label, style: TextStyle(color: on ? Colors.white : AppColors.text, fontSize: 13.5, fontWeight: FontWeight.w700)),
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
    final tag = plan.validityDays <= 7 ? t.budget : (plan.validityDays <= 15 ? t.popular : t.bestSeller);
    final tagColor = plan.validityDays <= 7 ? AppColors.orange : (plan.validityDays <= 15 ? AppColors.primary : AppColors.gold);
    return AppCard(
      padding: const EdgeInsets.all(14),
      onTap: () => _buy(context),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(plan.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800), maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: tagColor.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
                      child: Text(tag, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: tagColor)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.network(destinationPhoto(plan.countryCode, cover: plan.cover), width: 66, height: 66, fit: BoxFit.cover,
                        errorBuilder: (_, e, s) => Container(width: 66, height: 66, color: AppColors.skyDeep)),
                  ),
                  Positioned(
                    top: 4, right: 4,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(color: AppColors.gold, shape: BoxShape.circle),
                      child: const Icon(Icons.star, size: 11, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.check_circle, size: 15, color: AppColors.primary),
              const SizedBox(width: 4),
              Text(plan.dataGb > 0 ? '${plan.dataGb}GB · 4G LTE' : '4G LTE',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.primary, fontWeight: FontWeight.w700)),
              const Spacer(),
              Text(app.price(plan.price), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: AppColors.text, letterSpacing: -0.5)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _sellPoint(Icons.sim_card_outlined, t.noPhysicalSim),
              const SizedBox(width: 12),
              _sellPoint(Icons.qr_code_2, t.instantActivation),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(onPressed: () => _buy(context), child: Text(t.buy)),
          ),
        ],
      ),
    );
  }

  Widget _sellPoint(IconData icon, String text) => Row(children: [
        Icon(icon, size: 13, color: AppColors.textSub),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 11.5, color: AppColors.textSub)),
      ]);

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
