import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

/// Compile-time app identity, shown on the splash screen so a stalled build is
/// still identifiable. Passed in from the build (`--dart-define`), with a
/// fallback that intentionally does not match pubspec so a missing define is
/// obvious rather than silently wrong.
class AppInfo {
  static const version = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');
  static const build = String.fromEnvironment('APP_BUILD', defaultValue: '0');
}

/// Base URL of the backend.
/// - Android emulator reaches the host machine via 10.0.2.2
/// - Real devices and desktop use the deployed server by default
class ApiConfig {
  /// Override at build/run time:
  ///   flutter run --dart-define=API_BASE=http://192.168.1.83:8100
  ///
  /// Defaults:
  ///  - Android emulator -> 10.0.2.2:8100 (the emulator's alias for the host)
  ///  - Android device / desktop -> the deployed backend
  ///
  /// NOTE: this used to default to a specific developer's LAN address
  /// (192.168.1.83). A release build then only worked on that one network, and
  /// on any other one it stalled on the splash screen until the request timed
  /// out. A public default means a plain `flutter build apk` produces a
  /// working app.
  static const _override = String.fromEnvironment('API_BASE');
  static const _emulator = bool.fromEnvironment('EMULATOR');

  /// Deployed shop backend.
  /// 后端与后台同域，走 HTTPS（nginx 反代到本机 8100）。
  static const String productionBaseUrl = "https://app.zkm4m.cn";

  static String get baseUrl {
    if (_override.isNotEmpty) return _override;
    if (!kIsWeb && Platform.isAndroid) {
      return _emulator ? "http://10.0.2.2:8100" : productionBaseUrl;
    }
    return productionBaseUrl;
  }

  /// Resolve a possibly-relative media path (e.g. /media/uploads/x.png) to an
  /// absolute URL on the backend host. Already-absolute and data URIs pass
  /// through unchanged.
  static String resolve(String? path) {
    if (path == null || path.isEmpty) return "";
    if (path.startsWith("http://") || path.startsWith("https://") || path.startsWith("data:")) return path;
    return "$baseUrl${path.startsWith("/") ? "" : "/"}$path";
  }
}

class ApiException implements Exception {
  final String message;
  final int? status;
  ApiException(this.message, {this.status});
  @override
  String toString() => message;
}

class ApiClient {
  final String? Function() tokenGetter;
  ApiClient(this.tokenGetter);

  /// Hard ceiling for a single request. Without this a dead route (wrong host,
  /// firewall drop, stale DNS) leaves the UI spinning forever -- which is
  /// exactly how the "stuck on splash" bug presented on real devices.
  static const _timeout = Duration(seconds: 12);

  Map<String, String> _headers({bool json = false, bool auth = false}) {
    final h = <String, String>{};
    if (json) h["Content-Type"] = "application/json";
    if (auth) {
      final t = tokenGetter();
      if (t != null) h["Authorization"] = "Bearer $t";
    }
    return h;
  }

  Uri _uri(String path, [Map<String, dynamic>? q]) {
    final u = Uri.parse("${ApiConfig.baseUrl}$path");
    if (q == null || q.isEmpty) return u;
    return u.replace(queryParameters: q.map((k, v) => MapEntry(k, "$v")));
  }

  dynamic _decode(http.Response r) {
    if (r.statusCode >= 200 && r.statusCode < 300) {
      if (r.body.isEmpty) return null;
      return jsonDecode(utf8.decode(r.bodyBytes));
    }
    String detail = "HTTP ${r.statusCode}";
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      detail = j["detail"]?.toString() ?? detail;
    } catch (_) {}
    throw ApiException(detail, status: r.statusCode);
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? q, bool auth = false}) async {
    final r = await http
        .get(_uri(path, q), headers: _headers(auth: auth))
        .timeout(_timeout);
    return _decode(r);
  }

  Future<dynamic> post(String path, {Object? body, Map<String, dynamic>? q, bool auth = false, bool form = false}) async {
    final r = await http
        .post(
          _uri(path, q),
          headers: _headers(json: !form, auth: auth),
          body: form ? body : (body != null ? jsonEncode(body) : null),
        )
        .timeout(_timeout);
    return _decode(r);
  }

  Future<dynamic> patch(String path, {Object? body, bool auth = true}) async {
    final r = await http
        .patch(_uri(path), headers: _headers(json: true, auth: auth), body: jsonEncode(body))
        .timeout(_timeout);
    return _decode(r);
  }

  Future<dynamic> delete(String path, {bool auth = true}) async {
    final r = await http.delete(_uri(path), headers: _headers(auth: auth)).timeout(_timeout);
    return _decode(r);
  }
}

// ---------------- Models ----------------

class Plan {
  final int id;
  final String sku, title, description, kind, countryCode, region, currency;
  final String imageUrl;
  final double dataGb, price;
  final int validityDays, voiceMinutes, smsCount, stock;
  /// Only meaningful when [kind] is `quota`: extra card slots this grants.
  final int quotaSlots;

  Plan.fromJson(Map<String, dynamic> j)
      : id = j["id"],
        sku = j["sku"] ?? "",
        title = j["title"] ?? "",
        description = j["description"] ?? "",
        kind = j["kind"] ?? "esim",
        countryCode = j["country_code"] ?? "",
        region = j["region"] ?? "",
        currency = j["currency"] ?? "USD",
        imageUrl = j["image_url"] ?? "",
        dataGb = (j["data_gb"] ?? 0).toDouble(),
        price = (j["price"] ?? 0).toDouble(),
        validityDays = j["validity_days"] ?? 0,
        voiceMinutes = j["voice_minutes"] ?? 0,
        smsCount = j["sms_count"] ?? 0,
        stock = j["stock"] ?? 0,
        quotaSlots = j["quota_slots"] ?? 0;

  bool get isEsim => kind == "esim";

  /// Backend cover image if set, else empty (caller falls back to destination art).
  String get cover => ApiConfig.resolve(imageUrl);
}

class Esim {
  final int id, planId;
  final String iccid, lpaCode, qrPath, smdpAddress, matchingId, status;
  final double dataUsedMb;
  final DateTime? expiresAt;

  Esim.fromJson(Map<String, dynamic> j)
      : id = j["id"],
        planId = j["plan_id"] ?? 0,
        iccid = j["iccid"] ?? "",
        lpaCode = j["lpa_code"] ?? "",
        qrPath = j["qr_path"] ?? "",
        smdpAddress = j["smdp_address"] ?? "",
        matchingId = j["matching_id"] ?? "",
        status = j["status"] ?? "",
        dataUsedMb = (j["data_used_mb"] ?? 0).toDouble(),
        expiresAt = j["expires_at"] != null ? DateTime.tryParse(j["expires_at"]) : null;

  String get qrUrl => qrPath.isEmpty ? "" : ApiConfig.resolve(qrPath);
}

class OrderItem {
  final int planId, quantity;
  final String title, kind;
  final double unitPrice;
  OrderItem.fromJson(Map<String, dynamic> j)
      : planId = j["plan_id"],
        quantity = j["quantity"] ?? 1,
        title = j["title"] ?? "",
        kind = j["kind"] ?? "",
        unitPrice = (j["unit_price"] ?? 0).toDouble();
}

class Order {
  final int id;
  final String orderNo, email, status, currency, trackingNo, shipName, shipAddress, couponCode;
  final double subtotal, discount, total;
  final DateTime? createdAt;
  final List<OrderItem> items;
  final List<Esim> esims;

  Order.fromJson(Map<String, dynamic> j)
      : id = j["id"],
        orderNo = j["order_no"] ?? "",
        email = j["email"] ?? "",
        status = j["status"] ?? "",
        currency = j["currency"] ?? "USD",
        trackingNo = j["tracking_no"] ?? "",
        shipName = j["ship_name"] ?? "",
        shipAddress = j["ship_address"] ?? "",
        couponCode = j["coupon_code"] ?? "",
        subtotal = (j["subtotal"] ?? 0).toDouble(),
        discount = (j["discount"] ?? 0).toDouble(),
        total = (j["total"] ?? 0).toDouble(),
        createdAt = j["created_at"] != null ? DateTime.tryParse(j["created_at"]) : null,
        items = ((j["items"] ?? []) as List).map((e) => OrderItem.fromJson(e)).toList(),
        esims = ((j["esims"] ?? []) as List).map((e) => Esim.fromJson(e)).toList();
}

class UserInfo {
  final int id;
  final String email, fullName;
  final bool isAdmin;
  UserInfo.fromJson(Map<String, dynamic> j)
      : id = j["id"],
        email = j["email"] ?? "",
        fullName = j["full_name"] ?? "",
        isAdmin = j["is_admin"] ?? false;
}

class PlanFilters {
  final List<String> countries, regions;
  PlanFilters.fromJson(Map<String, dynamic> j)
      : countries = List<String>.from(j["countries"] ?? []),
        regions = List<String>.from(j["regions"] ?? []);
}

class CouponResult {
  final bool valid;
  final String code, kind, message;
  final double discount, value;
  CouponResult.fromJson(Map<String, dynamic> j)
      : valid = j["valid"] ?? false,
        code = j["code"] ?? "",
        kind = j["kind"] ?? "",
        message = j["message"] ?? "",
        discount = (j["discount"] ?? 0).toDouble(),
        value = (j["value"] ?? 0).toDouble();
}

/// A payment channel configured by the admin (GET /api/payments).
/// Secrets are stripped server-side; `config` only carries public hints
/// such as a QR image URL or a merchant display id.
class PaymentGateway {
  final int id;
  final String provider, name, mode, instructions;
  final Map<String, dynamic> config;
  PaymentGateway.fromJson(Map<String, dynamic> j)
      : id = j["id"] ?? 0,
        provider = j["provider"] ?? "",
        name = j["name"] ?? "",
        mode = j["mode"] ?? "manual",
        instructions = j["instructions"] ?? "",
        config = (j["config"] as Map?)?.cast<String, dynamic>() ?? {};

  String get label => name.isNotEmpty ? name : provider;

  /// Public QR / payment image URL, if the admin provided one.
  String get qrUrl {
    for (final k in const ["qr_url", "qr", "qr_image", "image", "image_url"]) {
      final v = config[k];
      if (v is String && v.isNotEmpty) return ApiConfig.resolve(v);
    }
    return "";
  }
}

// ---------------- support chat ----------------

class SupportMessage {
  final int id;
  final String sender, agentName, body, imageUrl;
  final DateTime? createdAt;
  bool get isAgent => sender == "agent";
  SupportMessage.fromJson(Map<String, dynamic> j)
      : id = j["id"] ?? 0,
        sender = j["sender"] ?? "user",
        agentName = j["agent_name"] ?? "",
        body = j["body"] ?? "",
        imageUrl = j["image_url"] ?? "",
        createdAt = j["created_at"] != null ? DateTime.tryParse(j["created_at"]) : null;
  String get imageUrlResolved => ApiConfig.resolve(imageUrl);
}

class SupportChat {
  final int id;
  final String sessionKey, email, name, subject, status;
  final String agentName;
  final int unreadUser;
  final int rating;
  final String ratingComment;
  final List<SupportMessage> messages;
  SupportChat.fromJson(Map<String, dynamic> j)
      : id = j["id"] ?? 0,
        sessionKey = j["session_key"] ?? "",
        email = j["email"] ?? "",
        name = j["name"] ?? "",
        subject = j["subject"] ?? "",
        status = j["status"] ?? "open",
        agentName = j["agent_name"] ?? "",
        unreadUser = j["unread_user"] ?? 0,
        rating = j["rating"] ?? 0,
        ratingComment = j["rating_comment"] ?? "",
        messages = ((j["messages"] ?? []) as List).map((e) => SupportMessage.fromJson(e)).toList();
}

// ---------------- card writer (BLE write jobs) ----------------

/// One number slot bound onto a user's physical card.
class CardBinding {
  final int slot;
  final String status, imsi, msisdn;
  final DateTime? writtenAt;
  CardBinding.fromJson(Map<String, dynamic> j)
      : slot = j["slot"] ?? 0,
        status = j["status"] ?? "",
        imsi = j["imsi"] ?? "",
        msisdn = j["msisdn"] ?? "",
        writtenAt = j["written_at"] != null ? DateTime.tryParse(j["written_at"]) : null;
}

/// The physical card assigned to this account.
class MyCard {
  final int id;
  final String iccid, serial, vendor, model, status, writeAdapter;
  final int capacity, boundCount, freeSlots;
  final List<CardBinding> bindings;

  MyCard({
    this.id = 0,
    this.iccid = "",
    this.serial = "",
    this.vendor = "",
    this.model = "",
    this.status = "",
    this.writeAdapter = "",
    this.capacity = 0,
    this.boundCount = 0,
    this.freeSlots = 0,
    this.bindings = const [],
  });

  bool get exists => id > 0;

  /// Human label for the reader the operator selected.
  String get adapterLabel {
    switch (writeAdapter) {
      case "esim_sgp22":
        return "标准 eUICC（SGP.22）";
      case "linksfield_ble":
        return "Linksfield";
      case "beesim_ble":
        return "BeeSIM";
      case "mock":
        return "模拟";
      default:
        return writeAdapter.isEmpty ? "未配置" : writeAdapter;
    }
  }

  factory MyCard.fromJson(Map<String, dynamic> j) {
    final c = j["card"];
    final rows = (j["bindings"] ?? []) as List;
    if (c == null) {
      return MyCard(bindings: rows.map((e) => CardBinding.fromJson(e)).toList());
    }
    final m = (c as Map).cast<String, dynamic>();
    return MyCard(
      id: m["id"] ?? 0,
      iccid: m["iccid"] ?? "",
      serial: m["serial"] ?? "",
      vendor: m["vendor"] ?? "",
      model: m["model"] ?? "",
      status: m["status"] ?? "",
      writeAdapter: m["write_adapter"] ?? "",
      capacity: m["capacity"] ?? 0,
      boundCount: m["bound_count"] ?? 0,
      freeSlots: m["free_slots"] ?? 0,
      bindings: rows.map((e) => CardBinding.fromJson(e)).toList(),
    );
  }
}

/// What the server says about a physical card's remaining write allowance.
///
/// [allowed] is false for several distinct reasons ([reason]), and they must
/// not collapse into one message: an unregistered card needs an operator, a
/// full card needs a new one, and a card owned by someone else needs support.
class CardQuota {
  final int cardId;
  final bool known;
  final bool allowed;
  final String reason;
  final int capacity;
  final int boundCount;
  final int freeSlots;
  final String status;

  const CardQuota({
    this.cardId = 0,
    this.known = false,
    this.allowed = false,
    this.reason = "",
    this.capacity = 0,
    this.boundCount = 0,
    this.freeSlots = 0,
    this.status = "",
  });

  factory CardQuota.fromJson(Map<String, dynamic> j) => CardQuota(
        cardId: j["card_id"] ?? 0,
        known: j["known"] == true,
        allowed: j["allowed"] == true,
        reason: j["reason"] ?? "",
        capacity: j["capacity"] ?? 0,
        boundCount: j["bound_count"] ?? 0,
        freeSlots: j["free_slots"] ?? 0,
        status: j["status"] ?? "",
      );

  /// Machine-readable reason turned into something a customer can act on.
  String get reasonText {
    switch (reason) {
      case "card_not_registered":
        return "这张卡未在系统登记，请联系客服";
      case "card_belongs_to_another_user":
        return "这张卡属于其他账号，请联系客服";
      case "no_free_slots":
        return "配额已满（$boundCount / $capacity），无法继续写入";
      case "card_is_lost":
        return "这张卡已被标记为丢失，不可使用";
      case "card_is_retired":
        return "这张卡已停用";
      default:
        return reason.isEmpty ? "无法写入" : reason;
    }
  }
}

/// Result of reconciling a card's profile list with the server.
class CardSync {
  final int cardId, onCard, bound, freeSlots, capacity, createdNumbers, revoked;

  const CardSync({
    this.cardId = 0,
    this.onCard = 0,
    this.bound = 0,
    this.freeSlots = 0,
    this.capacity = 0,
    this.createdNumbers = 0,
    this.revoked = 0,
  });

  factory CardSync.fromJson(Map<String, dynamic> j) => CardSync(
        cardId: j["card_id"] ?? 0,
        onCard: j["on_card"] ?? 0,
        bound: j["bound"] ?? 0,
        freeSlots: j["free_slots"] ?? 0,
        capacity: j["capacity"] ?? 0,
        createdNumbers: j["created_numbers"] ?? 0,
        revoked: j["revoked"] ?? 0,
      );
}

/// One instruction the card driver executes (`es9p.*` / `es10b.*` / `es10c.*`).
class SimStep {
  final String op, note;
  final Map<String, dynamic> data;
  SimStep.fromJson(Map<String, dynamic> j)
      : op = j["op"] ?? "",
        note = j["note"] ?? "",
        data = (j["data"] as Map?)?.cast<String, dynamic>() ?? {};
}

/// A queued/claimed write, revoke, switch or read-info job.
class SimJob {
  final int id, cardId, attempts;
  final String jobNo, action, adapter, status, error;
  final Map<String, dynamic> payload;
  final DateTime? createdAt, completedAt;

  SimJob.fromJson(Map<String, dynamic> j)
      : id = j["id"] ?? 0,
        cardId = j["card_id"] ?? 0,
        attempts = j["attempts"] ?? 0,
        jobNo = j["job_no"] ?? "",
        action = j["action"] ?? "",
        adapter = j["adapter"] ?? "",
        status = j["status"] ?? "",
        error = j["error"] ?? "",
        payload = (j["payload"] as Map?)?.cast<String, dynamic>() ?? {},
        createdAt = j["created_at"] != null ? DateTime.tryParse(j["created_at"]) : null,
        completedAt = j["completed_at"] != null ? DateTime.tryParse(j["completed_at"]) : null;

  List<SimStep> get steps =>
      ((payload["steps"] ?? []) as List).map((e) => SimStep.fromJson((e as Map).cast<String, dynamic>())).toList();

  /// Server-rendered metadata: activation code, SM-DP+ host, expected ICCID, ...
  Map<String, dynamic> get meta => (payload["meta"] as Map?)?.cast<String, dynamic>() ?? {};

  bool get verified => payload["verified"] == true;

  /// The activation code this job installs, empty for read/revoke jobs.
  String get activationCode => (meta["activation_code"] ?? "").toString();

  /// ICCID the server expects the card to end up with (read-back validation).
  String get expectedIccid => (meta["iccid"] ?? "").toString();

  String get actionLabel {
    switch (action) {
      case "write":
        return "写入 eSIM";
      case "revoke":
        return "删除 eSIM";
      case "switch":
        return "切换号码";
      case "read_info":
        return "读取卡信息";
      default:
        return action;
    }
  }
}





/// 上游卡流量查询结果。对应后端 /api/orders/esims/{id}/usage。
class EsimUsage {
  final int id;
  final String status;
  final double usedMb;
  final double totalMb;
  final DateTime? expiresAt;

  const EsimUsage({
    required this.id,
    required this.status,
    required this.usedMb,
    required this.totalMb,
    this.expiresAt,
  });

  double get remainingMb {
    if (totalMb <= 0) return 0;
    final r = totalMb - usedMb;
    return r < 0 ? 0 : r;
  }

  double get percent {
    if (totalMb <= 0) return 0;
    final p = usedMb / totalMb * 100;
    return p > 100 ? 100 : p;
  }

  bool get hasQuota => totalMb > 0;

  factory EsimUsage.fromJson(Map<String, dynamic> j) => EsimUsage(
        id: (j["id"] ?? 0) as int,
        status: (j["status"] ?? "") as String,
        usedMb: ((j["data_used_mb"] ?? 0) as num).toDouble(),
        totalMb: ((j["data_total_mb"] ?? 0) as num).toDouble(),
        expiresAt: j["expires_at"] != null ? DateTime.tryParse(j["expires_at"]) : null,
      );

  /// 人类可读的流量。小于 1GB 显示 MB，否则显示 GB。
  static String fmt(double mb) {
    if (mb <= 0) return "0 MB";
    if (mb >= 1024) {
      final gb = mb / 1024;
      return "${gb.toStringAsFixed(gb >= 10 ? 1 : 2)} GB";
    }
    return "${mb.toStringAsFixed(mb >= 100 ? 0 : 1)} MB";
  }
}
/// 已购买的卡，「我的卡」列表项。
class MyEsim {
  final int id;
  final String orderNo;
  final int orderId;
  final String iccid;
  final String status;
  final String planTitle;
  /// "esim" 或 "physical_card"。实体卡的名字必须由前端按语言显示，
  /// 之前后端写死中文「实体卡」，导致其他语言页面上出现中文。
  final String kind;
  final String lpaCode;
  final String qrPath;
  final String smdpAddress;
  final String matchingId;
  final DateTime? activatedAt;
  final DateTime? expiresAt;
  final double dataUsedMb;
  final double dataTotalMb;
  final DateTime? usageCheckedAt;

  const MyEsim({
    required this.id,
    required this.orderNo,
    required this.orderId,
    required this.iccid,
    required this.status,
    required this.planTitle,
    this.kind = 'esim',
    required this.lpaCode,
    required this.qrPath,
    required this.smdpAddress,
    required this.matchingId,
    this.activatedAt,
    this.expiresAt,
    required this.dataUsedMb,
    required this.dataTotalMb,
    this.usageCheckedAt,
  });

  double get remainingMb {
    if (dataTotalMb <= 0) return 0;
    final r = dataTotalMb - dataUsedMb;
    return r < 0 ? 0 : r;
  }

  double get percent {
    if (dataTotalMb <= 0) return 0;
    final p = dataUsedMb / dataTotalMb * 100;
    return p > 100 ? 100 : p;
  }

  bool get hasQuota => dataTotalMb > 0;

  /// 实体卡（后台绑定的物理卡，没有订单行）
  bool get isPhysicalCard => kind == 'physical_card' || id < 0;
  String get qrUrl => qrPath.isEmpty ? "" : ApiConfig.resolve(qrPath);

  factory MyEsim.fromJson(Map<String, dynamic> j) => MyEsim(
        id: (j["id"] ?? 0) as int,
        orderNo: (j["order_no"] ?? "") as String,
        orderId: (j["order_id"] ?? 0) as int,
        iccid: (j["iccid"] ?? "") as String,
        status: (j["status"] ?? "") as String,
        planTitle: (j["plan_title"] ?? "") as String,
        kind: (j["kind"] ?? "esim") as String,
        lpaCode: (j["lpa_code"] ?? "") as String,
        qrPath: (j["qr_path"] ?? "") as String,
        smdpAddress: (j["smdp_address"] ?? "") as String,
        matchingId: (j["matching_id"] ?? "") as String,
        activatedAt: j["activated_at"] != null ? DateTime.tryParse(j["activated_at"]) : null,
        expiresAt: j["expires_at"] != null ? DateTime.tryParse(j["expires_at"]) : null,
        dataUsedMb: ((j["data_used_mb"] ?? 0) as num).toDouble(),
        dataTotalMb: ((j["data_total_mb"] ?? 0) as num).toDouble(),
        usageCheckedAt: j["usage_checked_at"] != null
            ? DateTime.tryParse(j["usage_checked_at"])
            : null,
      );

  /// 流量格式化：小于 1GB 用 MB，否则用 GB
  static String fmt(double mb) {
    if (mb <= 0) return "0 MB";
    if (mb >= 1024) {
      final gb = mb / 1024;
      return "${gb.toStringAsFixed(gb >= 10 ? 1 : 2)} GB";
    }
    return "${mb.toStringAsFixed(mb >= 100 ? 0 : 1)} MB";
  }
}
/// 卡流量 / 状态查询结果（用户端，对应 /api/card/flow）。
class CardFlowInfo {
  final bool ok;
  final String simId;
  final double? totalFlow;
  final double? usedFlow;
  final double? remainingFlow;
  final String expireDate;
  final String status;
  final String? error;

  const CardFlowInfo({
    required this.ok,
    this.simId = "",
    this.totalFlow,
    this.usedFlow,
    this.remainingFlow,
    this.expireDate = "",
    this.status = "",
    this.error,
  });

  factory CardFlowInfo.fromJson(Map<String, dynamic> j) => CardFlowInfo(
        ok: j["ok"] == true,
        simId: (j["sim_id"] ?? "") as String,
        totalFlow: (j["total_flow"] as num?)?.toDouble(),
        usedFlow: (j["used_flow"] as num?)?.toDouble(),
        remainingFlow: (j["remaining_flow"] as num?)?.toDouble(),
        expireDate: (j["expire_date"] ?? "") as String,
        status: (j["status"] ?? "") as String,
        error: j["error"] as String?,
      );

  static String fmt(double mb) {
    if (mb <= 0) return "0 MB";
    if (mb >= 1024) {
      final gb = mb / 1024;
      return "${gb.toStringAsFixed(gb >= 10 ? 1 : 2)} GB";
    }
    return "${mb.toStringAsFixed(mb >= 100 ? 0 : 1)} MB";
  }
}

/// 可充值的套餐（对应 /api/card/packages）。
class CardPackage {
  final String id;
  final String mealId;
  final String name;
  final String money;
  final String desc;
  final String flowSizeMb;
  final int days;

  const CardPackage({
    required this.id,
    this.mealId = "",
    required this.name,
    required this.money,
    this.desc = "",
    this.flowSizeMb = "",
    this.days = 0,
  });

  /// 下单要用 mealId，没有就退回 id
  String get orderId => mealId.isNotEmpty ? mealId : id;

  static String fmtFlow(String mb) {
    final v = double.tryParse(mb) ?? 0;
    if (v <= 0) return "—";
    if (v >= 1024) {
      final gb = v / 1024;
      return "${gb.toStringAsFixed(gb >= 10 ? 1 : 2)} GB";
    }
    return "${v.toStringAsFixed(0)} MB";
  }

  factory CardPackage.fromJson(Map<String, dynamic> j) => CardPackage(
        id: "${j["id"] ?? ""}",
        mealId: "${j["meal_id"] ?? ""}",
        name: (j["name"] ?? "") as String,
        money: "${j["money"] ?? ""}",
        desc: (j["desc"] ?? "") as String,
        flowSizeMb: "${j["flow_size_mb"] ?? ""}",
        days: (j["days"] as num?)?.toInt() ?? 0,
      );
}
/// findByCardNo 的返回：当前套餐 + 可充值套餐
class CardPackagesResult {
  final CardPackage? current;
  final List<CardPackage> packages;
  final List<CardPackage> extra;

  const CardPackagesResult({
    this.current,
    this.packages = const [],
    this.extra = const [],
  });

  factory CardPackagesResult.fromJson(Map<String, dynamic> j) => CardPackagesResult(
        current: j["current"] is Map
            ? CardPackage.fromJson((j["current"] as Map).cast<String, dynamic>())
            : null,
        packages: ((j["packages"] ?? []) as List)
            .map((e) => CardPackage.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        extra: ((j["extra_packages"] ?? []) as List)
            .map((e) => CardPackage.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}

/// 用户充值订单（对应 /api/recharge/orders）
class RechargeOrder {
  final int id;
  final String orderNo;
  final String simId;
  final String mealId;
  final String mealName;
  final String status;
  final double amount;
  final String currency;
  final String upstreamMsg;
  final DateTime? createdAt;

  const RechargeOrder({
    required this.id,
    required this.orderNo,
    required this.simId,
    required this.mealId,
    required this.mealName,
    required this.status,
    required this.amount,
    required this.currency,
    this.upstreamMsg = "",
    this.createdAt,
  });

  bool get isDone => status == "fulfilled";
  bool get isFailed => status == "failed";
  bool get isPending => status == "pending";

  factory RechargeOrder.fromJson(Map<String, dynamic> j) => RechargeOrder(
        id: (j["id"] ?? 0) as int,
        orderNo: (j["order_no"] ?? "") as String,
        simId: (j["sim_id"] ?? "") as String,
        mealId: (j["meal_id"] ?? "") as String,
        mealName: (j["meal_name"] ?? "") as String,
        status: (j["status"] ?? "") as String,
        amount: ((j["amount"] ?? 0) as num).toDouble(),
        currency: (j["currency"] ?? "USD") as String,
        upstreamMsg: (j["upstream_msg"] ?? "") as String,
        createdAt: j["created_at"] != null ? DateTime.tryParse(j["created_at"]) : null,
      );
}
