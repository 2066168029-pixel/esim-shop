import 'api.dart';

/// Thin typed wrapper over ApiClient for every backend endpoint.
class ApiService {
  final ApiClient _c;
  ApiService(this._c);

  Future<List<Plan>> plans(
      {String? kind, String? country, String? q, String? sort, String? lang}) async {
    final j = await _c.get("/api/plans", q: {
      if (kind != null && kind.isNotEmpty) "kind": kind,
      if (country != null && country.isNotEmpty) "country": country,
      if (q != null && q.isNotEmpty) "q": q,
      if (sort != null && sort.isNotEmpty) "sort": sort,
      // Server localizes title/description per request; the catalogue stores
      // all languages in one row.
      if (lang != null && lang.isNotEmpty) "lang": lang,
      "page_size": 100,
    });
    return ((j["items"] ?? []) as List).map((e) => Plan.fromJson(e)).toList();
  }

  Future<PlanFilters> filters() async => PlanFilters.fromJson(await _c.get("/api/plans/filters"));

  Future<CouponResult> applyCoupon(String code, double subtotal) async {
    final j = await _c.post("/api/orders/validate-coupon", q: {"code": code, "subtotal": subtotal});
    return CouponResult.fromJson(j);
  }

  /// Create a PayPal order for a pending order; returns {approve_url, ...}.
  Future<Map<String, dynamic>> paypalCreate(String orderNo, {String returnUrl = "", String cancelUrl = ""}) async {
    final j = await _c.post("/api/payments/paypal/create", auth: false, body: {
      "order_no": orderNo,
      if (returnUrl.isNotEmpty) "return_url": returnUrl,
      if (cancelUrl.isNotEmpty) "cancel_url": cancelUrl,
    });
    return (j as Map).cast<String, dynamic>();
  }

  /// Enabled payment channels as configured in the admin backend.
  /// Falls back to an empty list on error so the caller can use a default.
  Future<List<PaymentGateway>> paymentGateways() async {
    final j = await _c.get("/api/payments");
    return (j as List).map((e) => PaymentGateway.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Order> checkout({
    required List<Map<String, dynamic>> items,
    required String email,
    String couponCode = "",
    String paymentProvider = "mock",
    String currency = "",
    String shipName = "",
    String shipPhone = "",
    String shipAddress = "",
    String notes = "",
  }) async {
    final j = await _c.post("/api/orders/checkout", auth: true, body: {
      "items": items,
      "email": email,
      "payment_provider": paymentProvider,
      "currency": currency,
      "coupon_code": couponCode,
      "ship_name": shipName,
      "ship_phone": shipPhone,
      "ship_address": shipAddress,
      "notes": notes,
    });
    return Order.fromJson(j);
  }

  Future<Order> order(String orderNo) async => Order.fromJson(await _c.get("/api/orders/$orderNo"));

  Future<List<Order>> myOrders() async {
    final j = await _c.get("/api/orders", q: {"page_size": 50}, auth: true);
    return ((j["items"] ?? []) as List).map((e) => Order.fromJson(e)).toList();
  }

  Future<Esim> refreshUsage(int esimId) async {
    final j = await _c.get("/api/orders/esims/$esimId/usage");
    return Esim.fromJson(j);
  }

  Future<Map<String, dynamic>> login(String email, String password) async {
    final j = await _c.post("/api/auth/login",
        auth: false, form: true, body: {"username": email, "password": password});
    return j as Map<String, dynamic>;
  }

  /// Live FX rates (units per 1 USD). Falls back to built-in table on error.
  Future<Map<String, double>> fxRates() async {
    final j = await _c.get("/api/fx/rates");
    final raw = (j["rates"] ?? {}) as Map;
    return raw.map((k, v) => MapEntry("$k", (v as num).toDouble()));
  }

  /// Admin-editable per-language string overrides (merged over built-in defaults).
  Future<Map<String, String>> langPack(String lang) async {
    final j = await _c.get("/api/i18n/$lang");
    final raw = (j["strings"] ?? {}) as Map;
    return raw.map((k, v) => MapEntry("$k", "$v"));
  }

  /// Content blocks for a slot (banners, tips, categories).
  Future<List<Map<String, dynamic>>> content(String slot, {String lang = ""}) async {
    final j = await _c.get("/api/content", q: {"slot": slot, if (lang.isNotEmpty) "lang": lang});
    return (j as List).cast<Map<String, dynamic>>();
  }

  /// All content grouped by slot.
  Future<Map<String, dynamic>> contentAll() async {
    final j = await _c.get("/api/content/all");
    return (j as Map).cast<String, dynamic>();
  }

  /// Current user. Accepts an optional [timeout] so callers that must not block
  /// app startup can bound the wait (see AppState._load).
  Future<UserInfo> me({Duration? timeout}) async {
    final f = _c.get("/api/auth/me", auth: true);
    final j = timeout == null ? await f : await f.timeout(timeout);
    return UserInfo.fromJson(j);
  }

  Future<UserInfo> register(String email, String password, String name) async {
    final j = await _c.post("/api/auth/register",
        auth: false, body: {"email": email, "password": password, "full_name": name});
    return UserInfo.fromJson(j);
  }

  // ---------------- support chat ----------------
  /// Start (or re-open) a support conversation for this device.
  Future<SupportChat> supportStart({String name = "", String email = "", String subject = "", String message = "", String sessionKey = ""}) async {
    final j = await _c.post("/api/support/start",
        auth: false, body: {"name": name, "email": email, "subject": subject, "message": message, "session_key": sessionKey});
    return SupportChat.fromJson(j);
  }

  Future<SupportChat> supportFetch(String sessionKey) async =>
      SupportChat.fromJson(await _c.get("/api/support/$sessionKey"));

  Future<SupportChat> supportSend(String sessionKey, String body) async =>
      SupportChat.fromJson(await _c.post("/api/support/$sessionKey/message", body: {"body": body}));

  Future<SupportChat> supportRate(String sessionKey, int rating, String comment) async =>
      SupportChat.fromJson(await _c.post("/api/support/$sessionKey/rate", body: {"rating": rating, "comment": comment}));

  // ---------------- card writer (BLE write jobs) ----------------
  /// The card currently assigned to this user, plus its bound number slots.
  /// Returns `card == null` when the account has no card allocated.
  Future<MyCard> myCard() async => MyCard.fromJson(await _c.get("/api/sim/my-card", auth: true));

  /// Write/read jobs the operator queued for this user's card.
  ///
  /// [status] defaults to `queued`. The payload of a queued job is stripped of
  /// its steps until the app claims it, so a phone cannot write a card the
  /// server never released.
  Future<List<SimJob>> myCardJobs({String status = "queued"}) async {
    final j = await _c.get("/api/sim/jobs", q: {"status": status}, auth: true);
    return (j as List).map((e) => SimJob.fromJson(e)).toList();
  }

  /// Claim a job. Server flips `queued` -> `sent` and returns the executable
  /// payload (activation code / ES10 op steps) only at this point.
  Future<SimJob> claimJob(String jobNo) async =>
      SimJob.fromJson(await _c.post("/api/sim/jobs/$jobNo/send", auth: true));

  /// Report what happened on the card. Idempotent for finished jobs.
  Future<SimJob> reportJob(String jobNo, {required bool ok, String message = "", Map<String, dynamic> detail = const {}}) async =>
      SimJob.fromJson(await _c.post("/api/sim/jobs/$jobNo/result",
          auth: true, body: {"ok": ok, "message": message, "detail": detail}));

  /// Ask the server whether this physical card may be written to.  ///
  /// Identified by EID, not ICCID: a multi-profile eUICC carries one ICCID per
  /// stored profile and those change as profiles are written or deleted, while
  /// the EID is fixed for the life of the chip.
  ///
  /// This is the only place that knows the card's remaining slot count, so a
  /// write must not proceed when [CardQuota.allowed] is false.
  Future<CardQuota> bindCard(String eid) async =>
      CardQuota.fromJson(await _c.post("/api/sim/bind-card",
          auth: true, body: {"eid": eid}));

  /// Reconcile the server's record of this card with what is actually on it.
  ///
  /// A card can arrive already holding profiles the backend never recorded
  /// (vendor pre-installs, or writes done before this shop tracked cards).
  /// Without this the server's "used" count starts at zero on a card that is
  /// partly full, so the capacity limit is measured against a wrong baseline.
  ///
  /// Idempotent; safe to call on every connect.
  Future<CardSync> syncProfiles(String eid, List<Map<String, dynamic>> profiles) async =>
      CardSync.fromJson(await _c.post("/api/sim/sync-profiles",
          auth: true, body: {"eid": eid, "profiles": profiles}));
}
