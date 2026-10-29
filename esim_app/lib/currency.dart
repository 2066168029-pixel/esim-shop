/// Supported currencies with symbols and static reference rates (per 1 USD).
/// In production, rates should be refreshed from a live FX API; we keep a
/// local table so prices convert instantly and offline.
enum AppCurrency { usd, cny, jpy, krw, thb, vnd }

extension AppCurrencyInfo on AppCurrency {
  String get code => const {
        AppCurrency.usd: 'USD', AppCurrency.cny: 'CNY', AppCurrency.jpy: 'JPY',
        AppCurrency.krw: 'KRW', AppCurrency.thb: 'THB', AppCurrency.vnd: 'VND',
      }[this]!;

  String get symbol => const {
        AppCurrency.usd: '\$', AppCurrency.cny: '¥', AppCurrency.jpy: '¥',
        AppCurrency.krw: '₩', AppCurrency.thb: '฿', AppCurrency.vnd: '₫',
      }[this]!;

  String get label => const {
        AppCurrency.usd: 'USD', AppCurrency.cny: 'CNY', AppCurrency.jpy: 'JPY',
        AppCurrency.krw: 'KRW', AppCurrency.thb: 'THB', AppCurrency.vnd: 'VND',
      }[this]!;

  /// Units of this currency per 1 USD.
  double get perUsd => const {
        AppCurrency.usd: 1.0, AppCurrency.cny: 7.20, AppCurrency.jpy: 155.0,
        AppCurrency.krw: 1380.0, AppCurrency.thb: 36.5, AppCurrency.vnd: 25400.0,
      }[this]!;

  /// Decimals to show (VND/KRW/JPY usually no decimals).
  int get decimals => const {
        AppCurrency.usd: 2, AppCurrency.cny: 2, AppCurrency.jpy: 0,
        AppCurrency.krw: 0, AppCurrency.thb: 2, AppCurrency.vnd: 0,
      }[this]!;
}

/// Formats a base-USD price into the currently selected currency.
/// [liveRates] (code -> per-USD) overrides the built-in table when provided.
String formatPrice(double baseUsd, AppCurrency cur, {bool withSymbol = true, Map<String, double>? liveRates}) {
  final perUsd = liveRates?[cur.code] ?? cur.perUsd;
  final v = baseUsd * perUsd;
  final s = v.toStringAsFixed(cur.decimals);
  // thousands separators
  final parts = s.split('.');
  final whole = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  final out = parts.length > 1 ? '$whole.${parts[1]}' : whole;
  return withSymbol ? '${cur.symbol}$out' : out;
}

/// Format an amount that is ALREADY in [code] (e.g. an order stored in CNY).
/// Used so the order's displayed amount+currency match what was saved.
String formatInCurrency(double amount, String code) {
  final cur = AppCurrency.values.firstWhere(
    (c) => c.code.toUpperCase() == code.toUpperCase(),
    orElse: () => AppCurrency.usd,
  );
  final s = amount.toStringAsFixed(cur.decimals);
  final parts = s.split('.');
  final whole = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  final out = parts.length > 1 ? '$whole.${parts[1]}' : whole;
  return '${cur.symbol}$out';
}
