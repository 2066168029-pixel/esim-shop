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

/// Brand mark used on the sign-in / register screens.
///
/// This is the OnlyLinkCard artwork (SIM inside a globe with orbits) drawn
/// natively instead of shipping the launcher PNG, so it stays crisp at any
/// size and inherits the theme colour. It replaces the generic
/// `Icons.sim_card` placeholder that used to stand in for the logo.
class BrandMark extends StatelessWidget {
  final double size;
  final bool filled;
  const BrandMark({super.key, this.size = 44, this.filled = true});

  @override
  Widget build(BuildContext context) {
    final side = size;
    return Container(
      width: side,
      height: side,
      decoration: BoxDecoration(
        color: filled ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(side * 0.28),
        boxShadow: filled
            ? const [
                BoxShadow(
                    color: Color(0x1F1E3A8A),
                    blurRadius: 18,
                    offset: Offset(0, 6))
              ]
            : null,
      ),
      padding: EdgeInsets.all(side * 0.16),
      child: CustomPaint(
        painter: _BrandMarkPainter(
          color: AppColors.primaryDark,
          stroke: (side * 0.045).clamp(1.2, 3.0),
        ),
      ),
    );
  }
}

/// SIM card inside a globe with two orbital rings.
///
/// Geometry is expressed in a 0..100 box and scaled by the paint size, so the
/// same painter works for a 24px chip and an 88px splash logo.
class _BrandMarkPainter extends CustomPainter {
  final Color color;
  final double stroke;
  const _BrandMarkPainter({required this.color, required this.stroke});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    Offset o(double x, double y) =>
        Offset(x / 100 * size.width, y / 100 * size.height);
    double s(double v) => v / 100 * size.shortestSide;

    final c = o(50, 50);
    final r = s(30);

    // ---- two orbital ellipses, tilted opposite ways ----
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(-0.55);
    canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: r * 2.85, height: r * 1.42), p);
    canvas.restore();

    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(0.55);
    canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: r * 2.85, height: r * 1.42), p);
    canvas.restore();

    // ---- globe ----
    canvas.drawCircle(c, r, p);
    canvas.drawOval(
        Rect.fromCenter(center: c, width: r * 2, height: r * 0.82), p);
    canvas.drawOval(
        Rect.fromCenter(center: c, width: r * 0.82, height: r * 2), p);

    // ---- SIM card, knocked out of the globe so the lines do not collide ----
    final simRect = Rect.fromCenter(
        center: Offset(c.dx, c.dy + s(1)), width: r * 0.95, height: r * 1.10);
    final sim = RRect.fromRectAndRadius(simRect, Radius.circular(s(5)));

    canvas.drawRRect(sim, p);

    // notch: the classic cut corner, top-right
    final notch = Path()
      ..moveTo(sim.outerRect.right - s(9), sim.outerRect.top)
      ..lineTo(sim.outerRect.right, sim.outerRect.top + s(9));
    canvas.drawPath(notch, p);

    // contact pads (2 x 4)
    final pw = r * 0.16, ph = r * 0.13;
    final gapX = r * 0.045, gapY = r * 0.05;
    final gridW = pw * 4 + gapX * 3;
    final left = c.dx - gridW / 2;
    final top = c.dy + s(6);
    for (int row = 0; row < 2; row++) {
      for (int col = 0; col < 4; col++) {
        canvas.drawRect(
          Rect.fromLTWH(left + col * (pw + gapX), top + row * (ph + gapY), pw, ph),
          p,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BrandMarkPainter old) =>
      old.color != color || old.stroke != stroke;
}

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
