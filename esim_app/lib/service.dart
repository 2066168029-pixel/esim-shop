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
  /// Capture a PayPal order after the buyer approved it in the browser.
  ///
  /// The backend is idempotent: calling capture twice returns already=True
  /// rather than double-charging. Returns the settled order status.
  Future<Map<String, dynamic>> paypalCapture(String orderNo) async {
    final j = await _c.post("/api/payments/paypal/capture",
        auth: true, body: {"order_no": orderNo});
    return (j as Map).cast<String, dynamic>();
  }

  /// Start an Alipay payment for a pending order.
  ///
  /// Returns `{order_string, charge_url, amount, currency, ...}`. The H5
  /// cashier is built from these (see `alipay_h5.dart`); `charge_url` is the
  /// gateway endpoint the signed order string is posted to (sandbox and live
  /// differ), so it must come from the server rather than being hardcoded.
  Future<Map<String, dynamic>> alipayCreate(String orderNo) async {
    final j = await _c.post("/api/payments/alipay/create",
        auth: true, body: {"order_no": orderNo});
    return (j as Map).cast<String, dynamic>();
  }

  /// Poll the settlement state of an Alipay order (public, no token).
  Future<String> alipayStatus(String orderNo) async {
    final j = await _c.get("/api/payments/alipay/status", q: {"order_no": orderNo});
    return (j as Map)["status"] as String? ?? "";
  }

  /// Start an Alipay Global (Antom) payment for a pending order.
  ///
  /// Returns `{normal_url, applink_url, client_secret, payment_id, amount,
  /// currency}`. The cashier URL is opened in a WebView and the result is
  /// confirmed by polling [antomStatus]; the same flow works on iOS and Android.
  Future<Map<String, dynamic>> antomCreate(
    String orderNo, {
    String paymentMethodType = "",
    String terminalType = "WAP",
    String osType = "",
  }) async {
    final j = await _c.post("/api/payments/antom/create", auth: true, body: {
      "order_no": orderNo,
      if (paymentMethodType.isNotEmpty) "payment_method_type": paymentMethodType,
      "terminal_type": terminalType,
      if (osType.isNotEmpty) "os_type": osType,
    });
    return (j as Map).cast<String, dynamic>();
  }

  /// Poll the settlement state of an Antom order (public, no token).
  Future<String> antomStatus(String orderNo) async {
    final j = await _c.get("/api/payments/antom/status", q: {"order_no": orderNo});
    return (j as Map)["status"] as String? ?? "";
  }

  /// Public payment instructions for this deployment (manual mode text, QR, ...).
  Future<Map<String, dynamic>> paymentInfo() async {
    final j = await _c.get("/api/orders/payment-info", auth: false);
    return (j as Map).cast<String, dynamic>();
  }

  /// Customer-initiated cancellation. Only allowed while the order is still
  /// pending; the server rejects anything already paid.
  Future<Order> cancelOrder(String orderNo) async {
    final j = await _c.post("/api/orders/$orderNo/cancel", auth: true);
    return Order.fromJson(j);
  }

  /// Single plan by id, for the detail screen.
  Future<Plan> plan(int id) async =>
      Plan.fromJson(await _c.get("/api/plans/$id", auth: false));

  /// App update check. Returns the raw payload so the caller can decide what to
  /// show: {version, build, url, notes, force}.
  Future<Map<String, dynamic>> appVersion() async {
    final j = await _c.get("/api/app/version", auth: false);
    return (j as Map).cast<String, dynamic>();
  }

  /// Absolute URL of the newest APK, for a direct browser download.
  String appDownloadUrl() => "/api/app/download";

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
    bool useVoucher = false,
  }) async {
    final j = await _c.post("/api/orders/checkout", auth: true, body: {
      "items": items,
      "email": email,
      "payment_provider": paymentProvider,
      "currency": currency,
      "coupon_code": couponCode,
      "use_voucher": useVoucher,
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

  /// Live usage for one issued eSIM. The backend queries the upstream card API
  /// by ICCID and returns both used and total MB, so the app can render a real
  /// progress bar instead of guessing a budget from the plan title.
  /// 当前用户已购买的卡，带实时流量。
  /// 按 ICCID 查卡流量与状态。
  Future<CardFlowInfo> cardFlow(String simId) async {
    final j = await _c.get("/api/card/flow",
        q: {"sim_id": simId}, auth: true);
    return CardFlowInfo.fromJson((j as Map).cast<String, dynamic>());
  }

  /// 按卡号返回：当前套餐 + 可充值套餐。
  Future<CardPackagesResult> cardPackagesByCard(String simId) async {
    final j = await _c.get("/api/card/card-packages",
        q: {"sim_id": simId}, auth: true);
    return CardPackagesResult.fromJson((j as Map).cast<String, dynamic>());
  }

  /// 我的充值订单列表。
  Future<List<RechargeOrder>> myRecharges() async {
    final j = await _c.get("/api/recharge/orders", auth: true);
    return (j as List)
        .map((e) => RechargeOrder.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  /// 创建充值订单（待支付）。
  Future<RechargeOrder> createRecharge({
    required String simId,
    required String mealId,
    String mealName = "",
    int days = 0,
    String flowSizeMb = "",
    required double amount,
    String currency = "USD",
    String provider = "manual",
  }) async {
    final j = await _c.post("/api/recharge/orders", auth: true, body: {
      "sim_id": simId,
      "meal_id": mealId,
      "meal_name": mealName,
      "days": days,
      "flow_size_mb": flowSizeMb,
      "amount": amount,
      "currency": currency,
      "payment_provider": provider,
    });
    return RechargeOrder.fromJson((j as Map).cast<String, dynamic>());
  }

  /// 付款并触发充值。返回是否成功。
  Future<bool> payRecharge(String orderNo) async {
    final j = await _c.post("/api/recharge/orders/$orderNo/pay",
        auth: true, body: {"provider": "manual", "ref": ""});
    final m = (j as Map).cast<String, dynamic>();
    return m["status"] == "fulfilled";
  }

  /// 按 ICCID 查卡状态。
  Future<CardFlowInfo> cardStatus(String simId) async {
    final j = await _c.get("/api/card/status",
        q: {"sim_id": simId}, auth: true);
    return CardFlowInfo.fromJson((j as Map).cast<String, dynamic>());
  }

  /// 可充值的套餐列表。
  Future<List<CardPackage>> cardPackages() async {
    final j = await _c.get("/api/card/packages", auth: true);
    final list = (j as Map)["packages"] as List? ?? [];
    return list.map((e) => CardPackage.fromJson((e as Map).cast<String, dynamic>())).toList();
  }

  /// 给卡充值套餐。返回是否成功。
  Future<bool> cardRecharge({required String simId, required String mealId}) async {
    final j = await _c.post("/api/card/recharge",
        auth: true,
        body: {
          "sim_id": simId,
          "meal_id": mealId,
          "count_num": 1,
          "effect_type": "",
          "confirm": true,
        });
    return (j as Map)["ok"] == true;
  }

  Future<List<MyEsim>> myEsims({bool refresh = true}) async {
    final j = await _c.get("/api/orders/my-esims", q: {"refresh": refresh}, auth: true);
    return (j as List).map((e) => MyEsim.fromJson((e as Map).cast<String, dynamic>())).toList();
  }

  Future<EsimUsage> usage(int esimId) async {
    final j = await _c.get("/api/orders/esims/$esimId/usage");
    return EsimUsage.fromJson((j as Map).cast<String, dynamic>());
  }

  /// Backwards-compatible shim for callers that still expect an Esim.
  Future<Esim> refreshUsage(int esimId) async {
    final j = await _c.get("/api/orders/esims/$esimId/usage");
    return Esim.fromJson((j as Map).cast<String, dynamic>());
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

  Future<UserInfo> register(
    String email,
    String password,
    String name, {
    String code = "",
  }) async {
    final j = await _c.post("/api/auth/register", auth: false, body: {
      "email": email,
      "password": password,
      "full_name": name,
      "code": code,
    });
    return UserInfo.fromJson(j);
  }

  /// Ask the backend to email a one-time code.
  ///
  /// [purpose] is "register" or "reset". Throws on rate limiting so the UI can
  /// show the server's own wording (it already includes the wait time).
  Future<int> sendCode(String email, {String purpose = "register"}) async {
    final j = await _c.post("/api/auth/send-code", auth: false, body: {
      "email": email,
      "purpose": purpose,
    });
    final m = (j as Map).cast<String, dynamic>();
    return (m["ttl_minutes"] as num?)?.toInt() ?? 10;
  }

  /// Reset a password with a code issued for purpose="reset".
  Future<void> resetPassword(String email, String code, String password) async {
    await _c.post("/api/auth/reset-password", auth: false, body: {
      "email": email,
      "code": code,
      "password": password,
    });
  }

  /// Invite-a-friend: my code, the 10% discount and my stats.
  Future<Map<String, dynamic>> referralMe() async {
    final j = await _c.get("/api/referral/me", auth: true);
    return (j as Map).cast<String, dynamic>();
  }

  /// Friends I invited, with their status.
  Future<Map<String, dynamic>> referralList() async {
    final j = await _c.get("/api/referral/list", auth: true);
    return (j as Map).cast<String, dynamic>();
  }

  /// Bind the signed-in account to an inviter's code.
  Future<Map<String, dynamic>> referralClaim(String code) async {
    final j = await _c.post("/api/referral/claim", auth: true, body: {"code": code});
    return (j as Map).cast<String, dynamic>();
  }

  /// My cash voucher balance (CNY).
  Future<Map<String, dynamic>> myVoucher() async {
    final j = await _c.get("/api/referral/voucher", auth: true);
    return (j as Map).cast<String, dynamic>();
  }

  /// Change the password of the signed-in account.
  Future<void> changePassword(String currentPassword, String newPassword) async {
    await _c.post("/api/auth/change-password", auth: true, body: {
      "current_password": currentPassword,
      "password": newPassword,
    });
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
  /// Ask the server whether this card may take another profile.
  ///
  /// [iccid] is an optional fallback for a card that has never been read:
  /// the printed ICCID identifies it until the EID has been filled in.
  Future<CardQuota> bindCard(String eid, {String iccid = ""}) async =>
      CardQuota.fromJson(await _c.post("/api/sim/bind-card",
          auth: true, body: {"eid": eid, "iccid": iccid}));

  /// Reconcile the server's record of this card with what is actually on it.
  ///
  /// A card can arrive already holding profiles the backend never recorded
  /// (vendor pre-installs, or writes done before this shop tracked cards).
  /// Without this the server's "used" count starts at zero on a card that is
  /// partly full, so the capacity limit is measured against a wrong baseline.
  ///
  /// Idempotent; safe to call on every connect.
  Future<CardSync> syncProfiles(String eid, List<Map<String, dynamic>> profiles,
          {String iccid = ""}) async =>
      CardSync.fromJson(await _c.post("/api/sim/sync-profiles",
          auth: true, body: {"eid": eid, "iccid": iccid, "profiles": profiles}));
}
