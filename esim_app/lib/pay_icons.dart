import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'api.dart' show ApiConfig;
/// 支付方式品牌图标。
///
/// 图标从后端 `/media/pay/*.svg` 加载，由后台统一维护，
/// 变更图标不需要重新发版。
class PayIcons {
  /// provider -> 文件名（不含 .svg）
  static const Map<String, String> _files = {
    'alipay': 'alipay-icon',
    'wechat': 'wechat-pay-icon',
    'wechatpay': 'wechat-pay-icon',
    'stripe': 'stripe-icon',
    'paypal': 'paypal-icon',
  };

  /// 横向 logo（带文字）
  static const Map<String, String> _wide = {
    'alipay': 'alipay',
    'wechat': 'wechat-pay',
    'wechatpay': 'wechat-pay',
    'stripe': 'stripe',
    'paypal': 'paypal',
  };

  static String iconUrl(String provider, {bool wide = false}) {
    final key = provider.toLowerCase();
    final name = (wide ? _wide : _files)[key] ?? _files[key] ?? (wide ? _wide : _files)['default'];
    if (name == null) return "";
    return "${ApiConfig.baseUrl}/media/pay/$name.svg";
  }

  /// 品牌色（用于没有图标时的兜底）
  static Color color(String provider) {
    switch (provider.toLowerCase()) {
      case 'alipay':
        return const Color(0xFF1677FF);
      case 'wechat':
      case 'wechatpay':
        return const Color(0xFF07C160);
      case 'stripe':
        return const Color(0xFF635BFF);
      case 'paypal':
        return const Color(0xFF003087);
      default:
        return const Color(0xFF64748B);
    }
  }

  static String label(String provider) {
    switch (provider.toLowerCase()) {
      case 'alipay':
        return '支付宝';
      case 'wechat':
      case 'wechatpay':
        return '微信支付';
      case 'stripe':
        return 'Stripe';
      case 'paypal':
        return 'PayPal';
      default:
        return provider;
    }
  }
}


/// 单个支付图标。加载失败时退回品牌色圆角块 + 首字母。
class PayIcon extends StatelessWidget {
  final String provider;
  final double size;
  final bool wide;

  const PayIcon({super.key, required this.provider, this.size = 26, this.wide = false});

  @override
  Widget build(BuildContext context) {
    final url = PayIcons.iconUrl(provider, wide: wide);
    final fallback = _fallback();

    if (url.isEmpty) return fallback;

    return SizedBox(
      height: size,
      child: SvgPicture.network(
        url,
        height: size,
        fit: BoxFit.contain,
        placeholderBuilder: (_) => fallback,
        // 加载失败也显示兜底
      ),
    );
  }

  Widget _fallback() {
    final c = PayIcons.color(provider);
    final text = PayIcons.label(provider);
    return Container(
      height: size,
      padding: EdgeInsets.symmetric(horizontal: size * 0.28),
      decoration: BoxDecoration(
        color: c.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(color: c.withValues(alpha: .25)),
      ),
      child: Center(
        child: Text(
          text.characters.first.toUpperCase(),
          style: TextStyle(
            fontSize: size * 0.46,
            fontWeight: FontWeight.w800,
            color: c,
          ),
        ),
      ),
    );
  }
}

/// 一排支付图标
class PayIconRow extends StatelessWidget {
  final List<String> providers;
  final double size;

  const PayIconRow({
    super.key,
    this.providers = const ['alipay', 'wechat', 'stripe', 'paypal'],
    this.size = 22,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < providers.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Container(
            height: size + 12,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE8EDF4)),
            ),
            child: Center(child: PayIcon(provider: providers[i], size: size)),
          ),
        ],
      ],
    );
  }
}
