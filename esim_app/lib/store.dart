import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'service.dart';
import 'i18n.dart';
import 'currency.dart';

class CartLine {
  final Plan plan;
  int quantity;
  CartLine(this.plan, this.quantity);
}

/// Central app state: auth token/user, cart, and the API service.
class AppState extends ChangeNotifier {
  late final ApiClient client;
  late final ApiService api;

  String? _token;
  UserInfo? user;
  final List<CartLine> cart = [];
  bool ready = false;

  /// Escape hatch for the startup watchdog: let the UI in even if
  /// initialisation never completed, so a bug cannot brick the app behind a
  /// splash screen. Records why, for the next debugging round.
  String? readyForcedReason;
  void forceReady(String reason) {
    if (ready) return;
    ready = true;
    readyForcedReason = reason;
    notifyListeners();
  }

  AppLang _lang = AppLang.zh;
  AppCurrency _currency = AppCurrency.usd;
  Map<String, String> _i18nOverrides = {};

  /// Live FX rates (units per 1 USD), keyed by currency code. Seeded from the
  /// built-in table, refreshed from the backend on startup.
  Map<String, double> fxRates = {
    'USD': 1.0, 'CNY': 7.20, 'JPY': 155.0, 'KRW': 1380.0, 'THB': 36.5, 'VND': 25400.0,
  };

  /// Admin-editable content, grouped by slot (home_banner, home_tip, ...).
  Map<String, List<Map<String, dynamic>>> content = {};

  AppLang get lang => _lang;
  AppCurrency get currency => _currency;
  L get t => L(_lang, overrides: _i18nOverrides);

  /// Format a base-USD price using the live rate for the selected currency.
  String price(double baseUsd) => formatPrice(baseUsd, _currency, liveRates: fxRates);

  AppState() {
    client = ApiClient(() => _token);
    api = ApiService(client);
    _load();
  }

  Future<void> setLang(AppLang l) async {
    _lang = l;
    final sp = await SharedPreferences.getInstance();
    await sp.setString('lang', l.code);
    notifyListeners();
    // fetch this language's admin overrides
    try {
      _i18nOverrides = await api.langPack(l.code);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setCurrency(AppCurrency c) async {
    _currency = c;
    final sp = await SharedPreferences.getInstance();
    await sp.setString('currency', c.code);
    notifyListeners();
  }

  Future<void> _load() async {
    final sp = await SharedPreferences.getInstance();
    _token = sp.getString("token");
    final lc = sp.getString('lang');
    if (lc != null) {
      _lang = AppLang.values.firstWhere((e) => e.code == lc, orElse: () => AppLang.zh);
    }
    final cc = sp.getString('currency');
    if (cc != null) {
      _currency = AppCurrency.values.firstWhere((e) => e.code == cc, orElse: () => AppCurrency.usd);
    }
    final userJson = sp.getString("user");
    if (userJson != null) {
      try { user = UserInfo.fromJson(jsonDecode(userJson)); } catch (_) {}
    }
    final cartJson = sp.getString("cart");
    if (cartJson != null) {
      // Cart persists by plan reference re-fetched lazily; storing minimal here.
    }
    ready = true;
    // validate token in background
    if (_token != null) {
      try {
        // Bounded on purpose: a slow or unreachable backend must not keep the
        // app on the splash screen.
        user = await api.me(timeout: const Duration(seconds: 8));
      } catch (e) {
        // Only a definite "this token is no good" answer should log the user
        // out. A timeout, DNS failure, or refused connection says nothing
        // about the token, and wiping the session there would kick every
        // customer out whenever the shop backend hiccups.
        final rejected = e is ApiException && (e.status == 401 || e.status == 403);
        if (rejected) {
          _token = null;
          user = null;
          final sp2 = await SharedPreferences.getInstance();
          await sp2.remove("token");
          await sp2.remove("user");
        }
      }
    }
    // fire-and-forget remote config (never blocks startup)
    _loadRemoteConfig();
    notifyListeners();
  }

  /// Pull live FX rates, i18n overrides for the current language, and content.
  Future<void> _loadRemoteConfig() async {
    try {
      final r = await api.fxRates();
      if (r.isNotEmpty) fxRates = {...fxRates, ...r};
    } catch (_) {}
    try {
      _i18nOverrides = await api.langPack(_lang.code);
    } catch (_) {}
    try {
      content = (await api.contentAll()).map(
        (k, v) => MapEntry(k, (v as List).cast<Map<String, dynamic>>()),
      );
    } catch (_) {}
    notifyListeners();
  }

  bool get isLoggedIn => _token != null;
  bool get isAdmin => user?.isAdmin ?? false;
  int get cartCount => cart.fold(0, (s, l) => s + l.quantity);
  double get cartTotal => cart.fold(0.0, (s, l) => s + l.plan.price * l.quantity);

  // ---------- eSIM usage stats (real data, loaded from my orders) ----------
  int activeEsimCount = 0;
  double totalDataGb = 0;
  double usedDataGb = 0;
  bool statsLoading = false;

  /// Recompute the account-page eSIM stats.
  ///
  /// Traffic now comes from the upstream card API (by ICCID) through
  /// `/api/orders/esims/{id}/usage`, which returns both used and total MB.
  /// The plan-title heuristic is only used as a fallback when the upstream
  /// has no quota data for a profile.
  Future<void> refreshEsimStats() async {
    if (!isLoggedIn) {
      activeEsimCount = 0;
      totalDataGb = 0;
      usedDataGb = 0;
      esimUsages.clear();
      statsLoading = false;
      notifyListeners();
      return;
    }
    statsLoading = true;
    notifyListeners();
    try {
      // my-esims is the single source of truth: it returns issued eSIM profiles
      // AND physical cards bound to this customer. Counting from myOrders()
      // alone missed bound cards entirely, which is why "活跃套餐" stayed 0
      // for a customer who only had a card.
      final items = await api.myEsims(refresh: false);

      // 有卡但还没流量数据时，再拉一次带上游刷新的。实体卡刚绑定的时候
      // 库里是 0/0，不刷的话「我的」页只显示活跃套餐、总流量和已用都是 0。
      // 只在缺失时才付出这次开销，正常的列表不重复请求。
      List<MyEsim> source = items;
      if (items.any((e) => e.status != 'expired' && e.dataTotalMb <= 0)) {
        try {
          source = await api.myEsims();
        } catch (_) {
          source = items;
        }
      }

      var count = 0;
      var totalMb = 0.0;
      var usedMb = 0.0;
      final usages = <int, EsimUsage>{};

      for (final e in source) {
        if (e.status == 'expired') continue;
        count += 1;

        double total = e.dataTotalMb;
        double used = e.dataUsedMb;
        if (total <= 0) {
          // Upstream has no quota for this profile (common for freshly bound
          // cards): fall back to the GB figure in the plan title.
          total = _titleGbs(e.planTitle) * 1024;
        }
        usages[e.id] = EsimUsage(
          id: e.id,
          status: e.status,
          usedMb: used,
          totalMb: total,
        );
        totalMb += total;
        usedMb += used;
      }

      esimUsages
        ..clear()
        ..addAll(usages);
      activeEsimCount = count;
      totalDataGb = totalMb / 1024.0;
      usedDataGb = usedMb / 1024.0;
    } catch (_) {
      // keep previous values on failure
    } finally {
      statsLoading = false;
      notifyListeners();
    }
  }

  /// Per-eSIM live usage, keyed by esim id. Filled by [refreshEsimStats].
  final Map<int, EsimUsage> esimUsages = {};

  EsimUsage? usageOf(int esimId) => esimUsages[esimId];
  /// Pull a GB figure out of an item title like "Japan eSIM 20GB 30 Days".
  /// Pull the GB figure out of a plan title ("Japan 2GB 1 Day eSIM" -> 2).
  /// Used as a quota fallback when upstream reports no total for a profile,
  /// which is normal for a freshly bound card.
  double _titleGbs(String title) {
    if (title.isEmpty) return 0;
    final m = RegExp(r'(\d+(?:\.\d+)?)\s*GB', caseSensitive: false).firstMatch(title);
    if (m != null) {
      return double.tryParse(m.group(1)!) ?? 0;
    }
    return 0;
  }

  Future<void> _persistAuth() async {
    final sp = await SharedPreferences.getInstance();
    if (_token != null) {
      await sp.setString("token", _token!);
      await sp.setString("user", jsonEncode({
        "id": user?.id, "email": user?.email, "full_name": user?.fullName, "is_admin": user?.isAdmin,
      }));
    } else {
      await sp.remove("token");
      await sp.remove("user");
    }
  }

  Future<UserInfo> login(String email, String password) async {
    final r = await api.login(email, password);
    _token = r["access_token"];
    user = await api.me();
    await _persistAuth();
    notifyListeners();
    return user!;
  }

  Future<UserInfo> register(
    String email,
    String password,
    String name, {
    String code = '',
  }) async {
    await api.register(email, password, name, code: code);
    return login(email, password);
  }

  /// Request an email verification code. Returns the code's lifetime in minutes.
  Future<int> sendCode(String email, {String purpose = 'register'}) =>
      api.sendCode(email, purpose: purpose);

  /// Complete a password reset using a code issued for purpose='reset'.
  Future<void> resetPassword(String email, String code, String password) =>
      api.resetPassword(email, code, password);

  Future<void> logout() async {
    _token = null;
    user = null;
    await _persistAuth();
    notifyListeners();
  }

  void addToCart(Plan plan) {
    final existing = cart.where((l) => l.plan.id == plan.id).toList();
    if (existing.isNotEmpty) {
      existing.first.quantity++;
    } else {
      cart.add(CartLine(plan, 1));
    }
    notifyListeners();
  }

  void setQty(int planId, int q) {
    cart.removeWhere((l) => l.plan.id == planId && q <= 0);
    for (final l in cart) {
      if (l.plan.id == planId) l.quantity = q;
    }
    notifyListeners();
  }

  void removeLine(int planId) {
    cart.removeWhere((l) => l.plan.id == planId);
    notifyListeners();
  }

  void clearCart() {
    cart.clear();
    notifyListeners();
  }
}
