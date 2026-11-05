import 'package:flutter/material.dart';

/// OnlyLink 设计系统 v2
///
/// 方向：冷调中性底 + 单一强调色，卡片靠留白和细边框分层，
/// 不用重投影。数字统一等宽，形成「信息密度高但不拥挤」的观感。
class AppColors {
  // ---- 强调色（靛蓝，比原来的纯蓝更沉稳）----
  static const primary = Color(0xFF4F46E5);
  static const primaryDark = Color(0xFF3730A3);
  static const primaryLight = Color(0xFF818CF8);
  static const primaryWash = Color(0xFFEEF0FF);

  // ---- 表面 ----
  static const bg = Color(0xFFF6F7FB);
  static const surface = Colors.white;
  static const surface2 = Color(0xFFFAFBFD);
  static const sky = Color(0xFFEEF2FF);
  static const skyDeep = Color(0xFFE0E7FF);

  // ---- 文字 ----
  static const text = Color(0xFF0F172A);
  static const textSub = Color(0xFF5A6478);
  static const muted = Color(0xFF8B94A6);

  // ---- 线 ----
  static const border = Color(0xFFE6EAF2);
  static const borderSoft = Color(0xFFF0F3F8);

  // ---- 状态 ----
  static const success = Color(0xFF059669);
  static const successWash = Color(0xFFECFDF5);
  static const warn = Color(0xFFB45309);
  static const warnWash = Color(0xFFFFFBEB);
  static const orange = Color(0xFFEA580C);
  static const danger = Color(0xFFDC2626);
  static const dangerWash = Color(0xFFFEF2F2);
  static const gold = Color(0xFFD97706);

  // ---- 渐变 ----
  /// 主视觉卡（余额 / 卡状态）
  static const heroBlue = LinearGradient(
    colors: [Color(0xFF4F46E5), Color(0xFF6366F1), Color(0xFF818CF8)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    stops: [0.0, 0.55, 1.0],
  );

  /// 深色卡片（激活码 / QR）
  static const navyCard = LinearGradient(
    colors: [Color(0xFF111C33), Color(0xFF1E2A4A)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// 页面背景（顶部轻微渐变）
  static const skyBackground = LinearGradient(
    colors: [Color(0xFFEEF2FF), Color(0xFFF6F7FB)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.0, 0.32],
  );

  /// 骨架 / 占位
  static const skeleton = LinearGradient(
    colors: [Color(0xFFF1F4F9), Color(0xFFE8EDF5), Color(0xFFF1F4F9)],
    begin: Alignment(-1, 0),
    end: Alignment(1, 0),
  );
}

class AppRadii {
  static const sm = 8.0;
  static const card = 16.0;
  static const big = 20.0;
  static const btn = 12.0;
  static const pill = 999.0;
}

class AppShadow {
  static const card = [
    BoxShadow(color: Color(0x080F172A), blurRadius: 10, offset: Offset(0, 2)),
  ];
  static const lift = [
    BoxShadow(color: Color(0x0F0F172A), blurRadius: 22, offset: Offset(0, 8)),
  ];
  static const hero = [
    BoxShadow(color: Color(0x334F46E5), blurRadius: 26, offset: Offset(0, 12)),
  ];
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.light,
      surface: AppColors.surface,
    ),
    scaffoldBackgroundColor: AppColors.bg,
    splashFactory: InkSparkle.splashFactory,
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
      fontFamily: null,
    ),

    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        color: AppColors.text,
        fontSize: 16.5,
        fontWeight: FontWeight.w700,
        letterSpacing: -.2,
      ),
    ),

    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.card),
        side: const BorderSide(color: AppColors.border, width: 1),
      ),
    ),

    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.btn)),
        textStyle: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, letterSpacing: -.1),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.primary,
        side: const BorderSide(color: AppColors.border, width: 1.2),
        minimumSize: const Size.fromHeight(46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.btn)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.primary,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
      hintStyle: const TextStyle(color: AppColors.muted, fontSize: 14, fontWeight: FontWeight.w400),
      prefixIconColor: AppColors.muted,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(13),
        borderSide: const BorderSide(color: AppColors.danger),
      ),
    ),

    // 底部导航交给自定义实现，这里只兜底
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Colors.white,
      selectedItemColor: AppColors.primary,
      unselectedItemColor: AppColors.muted,
      type: BottomNavigationBarType.fixed,
      showUnselectedLabels: true,
      elevation: 0,
    ),

    dividerTheme: const DividerThemeData(
      color: AppColors.borderSoft, thickness: 1, space: 1,
    ),

    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.text,
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.big)),
      titleTextStyle: const TextStyle(
        color: AppColors.text, fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -.2,
      ),
    ),

    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),

    chipTheme: base.chipTheme.copyWith(
      backgroundColor: AppColors.surface2,
      side: const BorderSide(color: AppColors.border),
      labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSub),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.pill)),
    ),
  );
}

/// 状态标签 + 颜色（保持向后兼容）
(Color, String) statusStyle(String status) {
  switch (status) {
    case "fulfilled":
      return (AppColors.success, "已完成");
    case "paid":
      return (AppColors.warn, "已支付");
    case "pending":
      return (AppColors.muted, "待支付");
    case "cancelled":
      return (AppColors.danger, "已取消");
    case "refunded":
      return (AppColors.danger, "已退款");
    case "active":
      return (AppColors.success, "使用中");
    case "issued":
      return (AppColors.primary, "待激活");
    case "expired":
      return (AppColors.muted, "已过期");
    default:
      return (AppColors.muted, status);
  }
}
