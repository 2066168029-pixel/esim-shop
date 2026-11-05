import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../store.dart';
import '../theme.dart';
import '../i18n.dart';
import '../main.dart' show showSnack;
import 'cart_screen.dart';

/// 商品详情页 —— 套餐信息 + 加入购物车。
///
/// 设计：顶部大图渐变区（国家/地区 + 流量数字），中间规格卡，
/// 底部固定价格栏。点「加入购物车」后直接进购物车。
class PlanDetailScreenV2 extends StatefulWidget {
  final Plan plan;

  const PlanDetailScreenV2({super.key, required this.plan});

  @override
  State<PlanDetailScreenV2> createState() => _PlanDetailScreenV2State();
}

class _PlanDetailScreenV2State extends State<PlanDetailScreenV2> {
  bool _adding = false;

  Plan get p => widget.plan;

  /// 当前语言文案（页面里所有标签都走这里，不再写死中文）
  L get t => context.read<AppState>().t;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: CustomScrollView(
        slivers: [
          // ---- 顶部大图 ----
          SliverAppBar(
            expandedHeight: 260,
            pinned: true,
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.pop(context),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: _hero(),
              collapseMode: CollapseMode.parallax,
            ),
          ),

          // ---- 主体 ----
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _titleBlock(),
                  const SizedBox(height: 16),
                  _specGrid(),
                  if (p.description.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _descCard(),
                  ],
                  const SizedBox(height: 16),
                  _noticeCard(),
                ],
              ),
            ),
          ),
        ],
      ),

      // ---- 底部固定栏 ----
      bottomNavigationBar: _bottomBar(app),
    );
  }

  // ---------------------------------------------------------------- hero

  Widget _hero() {
    final code = p.countryCode.toUpperCase();
    final flag = _flagEmoji(code);
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0A66FF), Color(0xFF3B8CFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        children: [
          // 装饰圆
          Positioned(
            right: -40,
            top: -30,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: .08),
              ),
            ),
          ),
          Positioned(
            right: 30,
            bottom: -60,
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: .06),
              ),
            ),
          ),
          // 内容
          Positioned(
            left: 20,
            right: 20,
            bottom: 22,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (flag.isNotEmpty)
                        Text(flag, style: const TextStyle(fontSize: 34)),
                      const SizedBox(height: 8),
                      Text(
                        p.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          height: 1.25,
                          letterSpacing: -.3,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        p.kind == 'physical_sim' ? t.kindPhysicalSim : 'eSIM',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: .85),
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (p.dataGb > 0)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        p.dataGb % 1 == 0
                            ? p.dataGb.toStringAsFixed(0)
                            : p.dataGb.toStringAsFixed(1),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 40,
                          fontWeight: FontWeight.w900,
                          height: 1,
                          letterSpacing: -1.5,
                        ),
                      ),
                      Text(
                        'GB',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: .9),
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
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

  // ---------------------------------------------------------------- blocks

  Widget _titleBlock() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                p.title,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, height: 1.3),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (p.countryCode.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEAF2FF),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        p.countryCode.toUpperCase(),
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  Text(
                    p.kind == 'physical_sim' ? t.kindPhysicalCard : 'eSIM',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSub),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _specGrid() {
    final items = <(IconData, String, String)>[
      (Icons.data_usage, '流量', p.dataGb > 0 ? '${_num(p.dataGb)} GB' : '不限'),
      (Icons.schedule, '有效期', p.validityDays > 0 ? '${p.validityDays} 天' : '—'),
      (Icons.sim_card_outlined, t.kindSim, p.kind == 'physical_sim' ? t.kindPhysicalCard : 'eSIM'),
      (Icons.inventory_2_outlined, '库存', p.stock < 0 ? '不限' : '${p.stock}'),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: const Color(0xFFEDF1F7)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0)
              Container(width: 1, height: 34, color: const Color(0xFFF0F3F8)),
            Expanded(
              child: Column(
                children: [
                  Icon(items[i].$1, size: 18, color: AppColors.primary.withValues(alpha: .8)),
                  const SizedBox(height: 6),
                  Text(
                    items[i].$3,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    items[i].$2,
                    style: const TextStyle(fontSize: 11, color: AppColors.muted),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _descCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: const Color(0xFFEDF1F7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('套餐说明', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(
            p.description,
            style: const TextStyle(fontSize: 13, height: 1.65, color: AppColors.textSub),
          ),
        ],
      ),
    );
  }

  Widget _noticeCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F7FF),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFFD6E7FF)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 16, color: AppColors.primary),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              p.kind == 'physical_sim'
                  ? '实体卡需要邮寄，下单后请保持手机号畅通。'
                  : '购买后立即获得激活码，扫码即可安装。',
              style: const TextStyle(fontSize: 12.5, height: 1.6, color: Color(0xFF1E4B8F)),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- bottom

  Widget _bottomBar(AppState app) {
    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: const Color(0xFFE8EDF4), width: 1)),
        boxShadow: const [
          BoxShadow(color: Color(0x0F0B1526), blurRadius: 16, offset: Offset(0, -4)),
        ],
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('价格', style: TextStyle(fontSize: 11, color: AppColors.muted)),
              Text(
                app.price(p.price),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: AppColors.primary,
                  letterSpacing: -.5,
                ),
              ),
            ],
          ),
          const Spacer(),
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _adding ? null : () => _addToCart(app),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(160, 48),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                backgroundColor: AppColors.primary,
              ),
              icon: _adding
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.add_shopping_cart, size: 19),
              label: Text(
                _adding ? '添加中…' : '加入购物车',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- logic

  Future<void> _addToCart(AppState app) async {
    setState(() => _adding = true);
    HapticFeedback.lightImpact();
    try {
      app.addToCart(p);
      if (!mounted) return;
      showSnack(context, '已加入购物车');
      // 直接进购物车
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const CartScreen()),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showSnack(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  // ---------------------------------------------------------------- util

  String _num(double v) => v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  /// 国家码 -> emoji 国旗
  String _flagEmoji(String code) {
    if (code.length != 2) return "";
    const base = 0x1F1E6;
    final chars = code.codeUnits;
    if (chars.any((c) => c < 65 || c > 90)) return "";
    return String.fromCharCodes(chars.map((c) => base + (c - 65)));
  }
}
