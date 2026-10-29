import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../countries.dart';
import '../i18n.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets.dart';
import 'plans_screen.dart';

/// Onlylink-style "Choose destination" picker.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  List<Plan>? _plans;
  String _q = "";

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    app.api.plans(lang: app.lang.code).then((p) {
      if (mounted) setState(() => _plans = p);
    }).catchError((_) {
      if (mounted) setState(() => _plans = []);
    });
  }

  @override
  Widget build(BuildContext context) {
    final all = kFeaturedOrder
        .where((code) => _plans?.any((p) => p.countryCode == code) ?? false)
        .map(countryOf)
        .where((c) => _q.isEmpty || c.nameZh.contains(_q) || c.nameEn.toLowerCase().contains(_q.toLowerCase()) || c.code.toLowerCase() == _q.toLowerCase())
        .toList();

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('选择目的地')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              decoration: const InputDecoration(hintText: '搜索目的地', prefixIcon: Icon(Icons.search, color: AppColors.muted)),
              onChanged: (v) => setState(() => _q = v.trim()),
            ),
          ),
          Expanded(
            child: _plans == null
                ? loadingBox()
                : all.isEmpty
                    ? emptyBox('没有找到相关目的地', icon: Icons.search_off)
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: all.length,
                        separatorBuilder: (_, i) => const SizedBox(height: 10),
                        itemBuilder: (_, i) => _Tile(c: all[i]),
                      ),
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final Country c;
  const _Tile({required this.c});
  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(10),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PlansScreen(initialCountry: c.code, title: c.nameZh))),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(destinationPhoto(c.code), width: 56, height: 56, fit: BoxFit.cover,
                errorBuilder: (_, e, s) => Container(width: 56, height: 56, color: AppColors.skyDeep)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.nameZh, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(c.nameEn, style: const TextStyle(fontSize: 12.5, color: AppColors.textSub)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: AppColors.muted),
        ],
      ),
    );
  }
}
