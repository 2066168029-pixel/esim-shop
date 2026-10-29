import 'package:flutter/material.dart';

/// Onlylink-style palette: iOS blue, light-blue gradient backgrounds, white cards.
class AppColors {
  static const primary = Color(0xFF0A66FF); // iOS-ish blue used across the app
  static const primaryDark = Color(0xFF0052CC);
  static const primaryLight = Color(0xFF3B8CFF);
  static const sky = Color(0xFFE6F2FF); // top gradient
  static const skyDeep = Color(0xFFCFE6FF);
  static const bg = Color(0xFFF5F8FC);
  static const card = Colors.white;
  static const text = Color(0xFF0B1220);
  static const textSub = Color(0xFF6B7280);
  static const muted = Color(0xFF9AA4B2);
  static const border = Color(0xFFE8EDF4);
  static const success = Color(0xFF22C55E);
  static const orange = Color(0xFFF97316);
  static const warn = Color(0xFFF59E0B);
  static const danger = Color(0xFFEF4444);
  static const gold = Color(0xFFF5B301);

  /// Blue used for the active-eSIM hero card.
  static const heroBlue = LinearGradient(
    colors: [Color(0xFF0A66FF), Color(0xFF3B8CFF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Deep navy used for the QR activation card.
  static const navyCard = LinearGradient(
    colors: [Color(0xFF0A2A66), Color(0xFF0A66FF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const skyBackground = LinearGradient(
    colors: [Color(0xFFE6F2FF), Color(0xFFFFFFFF)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.0, 0.45],
  );
}

class AppRadii {
  static const card = 18.0;
  static const big = 22.0;
  static const btn = 14.0;
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: AppColors.primary, brightness: Brightness.light),
    scaffoldBackgroundColor: AppColors.bg,
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppColors.text,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(color: AppColors.text, fontSize: 17, fontWeight: FontWeight.w700),
    ),
    cardTheme: CardThemeData(
      color: AppColors.card,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.card)),
      margin: EdgeInsets.zero,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.btn)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
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
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      hintStyle: const TextStyle(color: AppColors.muted, fontSize: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: AppColors.primary, width: 1.5)),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Colors.white,
      selectedItemColor: AppColors.primary,
      unselectedItemColor: AppColors.muted,
      type: BottomNavigationBarType.fixed,
      showUnselectedLabels: true,
      selectedLabelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
      unselectedLabelStyle: TextStyle(fontSize: 11),
      elevation: 10,
    ),
    dividerTheme: const DividerThemeData(color: AppColors.border, thickness: 1, space: 1),
  );
}

/// Status label + color.
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
