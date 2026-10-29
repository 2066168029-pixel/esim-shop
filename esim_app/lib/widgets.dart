import 'package:flutter/material.dart';
import 'theme.dart';

class StatusChip extends StatelessWidget {
  final String status;
  const StatusChip(this.status, {super.key});
  @override
  Widget build(BuildContext context) {
    final (color, label) = statusStyle(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w700)),
    );
  }
}

/// White rounded card with soft shadow — base container.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  const AppCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap});

  @override
  Widget build(BuildContext context) {
    // Material first, decoration second: ListTiles nested in this card need a
    // Material ancestor, otherwise Flutter asserts that their ink splashes are
    // invisible against the white DecoratedBox.
    final content = Material(
      type: MaterialType.transparency,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppRadii.card),
          boxShadow: const [BoxShadow(color: Color(0x0F1E3A8A), blurRadius: 20, offset: Offset(0, 8))],
        ),
        padding: padding,
        child: child,
      ),
    );
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(borderRadius: BorderRadius.circular(AppRadii.card), onTap: onTap, child: content),
    );
  }
}

class PriceText extends StatelessWidget {
  final double value;
  final double size;
  const PriceText(this.value, {super.key, this.size = 22});
  @override
  Widget build(BuildContext context) => Text(
        '¥${value.toStringAsFixed(2)}',
        style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, color: AppColors.text, height: 1.1, letterSpacing: -0.5),
      );
}

/// Blue accent price (e.g. inside lists).
class PriceAccent extends StatelessWidget {
  final double value;
  final double size;
  const PriceAccent(this.value, {super.key, this.size = 19});
  @override
  Widget build(BuildContext context) => Text(
        '¥${value.toStringAsFixed(2)}',
        style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, color: AppColors.primary, height: 1.1, letterSpacing: -0.5),
      );
}

Widget loadingBox() => const Center(
      child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator(color: AppColors.primary)),
    );

Widget emptyBox(String text, {IconData icon = Icons.inbox_outlined}) => Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(color: Color(0xFFEDF3FB), shape: BoxShape.circle),
              child: Icon(icon, size: 38, color: AppColors.primary),
            ),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textSub, fontSize: 14.5)),
          ],
        ),
      ),
    );

Widget errorBox(String msg) => Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, color: AppColors.danger, size: 44),
            const SizedBox(height: 14),
            const Text('连接失败', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 6),
            Text(msg, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textSub, fontSize: 13)),
          ],
        ),
      ),
    );

/// Soft rounded tag/pill (data, validity, badges).
class SoftTag extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Color color;
  const SoftTag(this.text, {super.key, this.icon, this.color = AppColors.primary});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(9)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 13, color: color), const SizedBox(width: 4)],
          Text(text, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w700)),
        ]),
      );
}
