/// Linksfield MP API client (wholesale ordering + lifecycle).
///
/// Covers the 12 documented v2 endpoints. Every call is signed with
/// [MpSigner]; nothing here knows about cards or profiles — it only obtains and
/// manages the activation codes that the BLE writer then installs.
///
/// Response envelope (all endpoints):
///   { "code": 200, "msg": "Success", "data": ..., "requestId": null }
///
/// `code` is the business status; HTTP can be 200 while `code` is an error, so
/// both layers are checked.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'mp_signer.dart';

class MpError implements Exception {
  final String message;
  final int? code;
  final String? requestId;
  final int? httpStatus;

  MpError(this.message, {this.code, this.requestId, this.httpStatus});

  @override
  String toString() {
    final bits = [
      if (code != null) 'code=$code',
      if (httpStatus != null) 'http=$httpStatus',
      if (requestId != null) 'requestId=$requestId',
    ].join(', ');
    return 'MpError: $message${bits.isEmpty ? '' : ' ($bits)'}';
  }
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// One purchasable/owned product specification.
class MpProduct {
  final int goodsId;
  final int productId;
  final String goodsName;
  final String productName;
  final String coverCountry;
  final String coverCountryName;
  final String validity;
  final String validityUnit;

  /// Only present on `purchaseItem`: current stock for the listed cycles.
  final int? stock;
  final String? flow;
  final String? flowUnit;
  final String? orderQuantity;

  const MpProduct({
    required this.goodsId,
    required this.productId,
    required this.goodsName,
    required this.productName,
    required this.coverCountry,
    required this.coverCountryName,
    required this.validity,
    required this.validityUnit,
    this.stock,
    this.flow,
    this.flowUnit,
    this.orderQuantity,
  });

  factory MpProduct.fromJson(Map<String, dynamic> j) => MpProduct(
        goodsId: _int(j['goodsId']) ?? 0,
        productId: _int(j['productId']) ?? 0,
        goodsName: '${j['goodsName'] ?? ''}',
        productName: '${j['productName'] ?? ''}',
        coverCountry: '${j['coverCountry'] ?? ''}',
        coverCountryName: '${j['coverCountryName'] ?? ''}',
        validity: '${j['validity'] ?? ''}',
        validityUnit: '${j['validityUnit'] ?? ''}',
        stock: _int(j['stock']),
        flow: j['flow']?.toString(),
        flowUnit: j['flowUnit']?.toString(),
        orderQuantity: j['orderQuantity']?.toString(),
      );

  /// The cycles this product accepts, e.g. "3,4" → [3, 4].
  List<int> get allowedQuantities {
    final raw = orderQuantity ?? '';
    return raw
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .toList();
  }

  String get label => productName.isNotEmpty ? productName : goodsName;

  @override
  String toString() =>
      'MpProduct($productId, $label, ${coverCountryName.isEmpty ? coverCountry : coverCountryName}, '
      '${validity}${validityUnit}${stock != null ? ", stock=$stock" : ""})';
}

/// Result of activationCode / purchaseAndActivationCode.
class MpActivation {
  final String iccid;
  final String qrCode;
  final String orderCode;

  const MpActivation({
    required this.iccid,
    required this.qrCode,
    required this.orderCode,
  });

  factory MpActivation.fromJson(Map<String, dynamic> j) => MpActivation(
        iccid: '${j['iccid'] ?? ''}',
        qrCode: '${j['qrCode'] ?? ''}',
        orderCode: '${j['orderCode'] ?? ''}',
      );

  @override
  String toString() => 'MpActivation($iccid, $orderCode)';
}

/// Per-order status as reported by queryOrderStatus.
class MpOrderStatus {
  final String? packageCode;
  final String? status;
  final String? actualStartTime;
  final String? plannedEndTime;
  final String? eid;

  const MpOrderStatus({
    this.packageCode,
    this.status,
    this.actualStartTime,
    this.plannedEndTime,
    this.eid,
  });

  factory MpOrderStatus.fromJson(Map<String, dynamic> j) => MpOrderStatus(
        packageCode: j['packageCode']?.toString(),
        status: j['status']?.toString(),
        actualStartTime: j['actualStartTime']?.toString(),
        plannedEndTime: j['plannedEndTime']?.toString(),
        eid: j['eid']?.toString(),
      );

  /// 0 not enabled · 1 in use · 2 suspended · 3 finished.
  String get statusLabel {
    switch (status) {
      case '0':
        return '未启用';
      case '1':
        return '使用中';
      case '2':
        return '已暂停';
      case '3':
        return '已结束';
      default:
        return '未知';
    }
  }
}

class MpTraffic {
  final String? packageCode;
  final int? packageFlow; // MB
  final int? packageUsedFlow; // MB
  final String? cycle;

  const MpTraffic({
    this.packageCode,
    this.packageFlow,
    this.packageUsedFlow,
    this.cycle,
  });

  factory MpTraffic.fromJson(Map<String, dynamic> j) => MpTraffic(
        packageCode: j['packageCode']?.toString(),
        packageFlow: _int(j['packageFlow']),
        packageUsedFlow: _int(j['packageUsedFlow']),
        cycle: j['cycle']?.toString(),
      );

  double get usedRatio {
    final total = packageFlow ?? 0;
    if (total <= 0) return 0;
    return ((packageUsedFlow ?? 0) / total).clamp(0, 1);
  }
}

class MpInventory {
  final String coverage;
  final int productId;
  final String productName;
  final int orderQuantity;
  final int inventoryNum;

  const MpInventory({
    required this.coverage,
    required this.productId,
    required this.productName,
    required this.orderQuantity,
    required this.inventoryNum,
  });

  factory MpInventory.fromJson(Map<String, dynamic> j) => MpInventory(
        coverage: '${j['coverage'] ?? ''}',
        productId: _int(j['productId']) ?? 0,
        productName: '${j['productName'] ?? ''}',
        orderQuantity: _int(j['orderQuantity']) ?? 0,
        inventoryNum: _int(j['inventoryNum']) ?? 0,
      );
}

class MpSimInfo {
  final String? iccid;
  final String? assetId;
  final String? apn;

  const MpSimInfo({this.iccid, this.assetId, this.apn});

  factory MpSimInfo.fromJson(Map<String, dynamic> j) => MpSimInfo(
        iccid: j['iccid']?.toString(),
        assetId: j['assetId']?.toString(),
        apn: j['apn']?.toString(),
      );

  bool get exists => (iccid ?? '').isNotEmpty;
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

/// Switch values accepted by `switchOrder`.
enum MpSwitch { on, suspend, restart, off }

extension on MpSwitch {
  String get wire {
    switch (this) {
      case MpSwitch.on:
        return 'ON';
      case MpSwitch.suspend:
        return 'SUSPEND';
      case MpSwitch.restart:
        return 'RESTART';
      case MpSwitch.off:
        return 'OFF';
    }
  }
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

class MpClient {
  final MpCredentials credentials;

  /// Defaults to the documented production host.
  final String host;

  final http.Client _http;
  final Duration timeout;

  MpClient({
    required this.credentials,
    this.host = 'lk-api-v2.linksfield.net',
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _http = client ?? http.Client();

  Uri _uri(String path, Map<String, String> query) {
    final base = host.contains('://') ? host : 'https://$host';
    final uri = Uri.parse('${base.replaceAll(RegExp(r'/+$'), '')}$path');
    return query.isEmpty ? uri : uri.replace(queryParameters: query);
  }

  /// Signs and sends one request. [query] must be in its final wire form
  /// (already percent-encoded) because the signature covers exactly those bytes.
  Future<Object?> _call(
    String method,
    String path, {
    Map<String, String> query = const {},
    Map<String, dynamic>? body,
  }) async {
    if (!credentials.isConfigured) {
      throw MpError('MP 凭证未配置（access_key / secret_key）');
    }

    final sig = MpSigner.sign(
      credentials: credentials,
      method: method,
      path: path,
      query: query,
    );
    final headers = MpSigner.authHeaders(credentials, sig);

    final uri = _uri(path, query);
    http.Response rsp;
    try {
      rsp = method == 'GET'
          ? await _http.get(uri, headers: headers).timeout(timeout)
          : await _http
              .post(uri,
                  headers: headers,
                  body: body == null ? null : jsonEncode(body))
              .timeout(timeout);
    } on TimeoutException {
      throw MpError('$path 请求超时（${timeout.inSeconds}s）');
    } catch (e) {
      throw MpError('$path 请求失败：$e');
    }

    if (rsp.statusCode == 401 || rsp.statusCode == 403) {
      throw MpError(
        '签名或权限被拒（HTTP ${rsp.statusCode}）。'
        '先核对 access_key/secret_key，再看签名头是否被网关剥掉。',
        httpStatus: rsp.statusCode,
      );
    }
    if (rsp.statusCode < 200 || rsp.statusCode >= 300) {
      throw MpError('HTTP ${rsp.statusCode}: ${_short(rsp.body)}',
          httpStatus: rsp.statusCode);
    }

    Object? json;
    try {
      json = jsonDecode(rsp.body);
    } on FormatException {
      throw MpError('响应不是 JSON: ${_short(rsp.body)}');
    }
    if (json is! Map<String, dynamic>) {
      throw MpError('响应不是对象: ${_short(rsp.body)}');
    }

    final code = _int(json['code']);
    if (code != null && code != 200) {
      throw MpError(
        '${json['msg'] ?? '未知错误'}',
        code: code,
        requestId: json['requestId']?.toString(),
      );
    }
    return json['data'];
  }

  static String _short(String s) =>
      s.length <= 200 ? s : '${s.substring(0, 200)}…';

  List<Map<String, dynamic>> _asList(Object? data) {
    if (data is List) {
      return data
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    return const [];
  }

  // --------------------------------------------------------------- ordering

  /// Products already purchased into this reseller's inventory.
  Future<List<MpProduct>> productList({String? requestId}) async {
    final data = await _call('GET', '/mp-api/api/esim/v2/productList',
        query: {if (requestId != null) 'requestId': requestId});
    return _asList(data).map(MpProduct.fromJson).toList();
  }

  /// Products available to buy, with live stock.
  Future<List<MpProduct>> purchaseItem({String? requestId}) async {
    final data = await _call('GET', '/mp-api/api/esim/v2/purchaseItem',
        query: {if (requestId != null) 'requestId': requestId});
    return _asList(data).map(MpProduct.fromJson).toList();
  }

  /// Inventory count per product.
  Future<List<MpInventory>> queryInventoryNumber({String? requestId}) async {
    final data = await _call(
        'GET', '/mp-api/api/esim/v2/queryInventoryNumber',
        query: {if (requestId != null) 'requestId': requestId});
    return _asList(data).map(MpInventory.fromJson).toList();
  }

  /// Creates an order for an eSIM already in inventory and returns its code.
  ///
  /// [orderQuantity] is the number of **cycles**, not the number of cards:
  /// omitting it takes the product's minimum. Passing a value the product does
  /// not support yields "No ICCID found" — check [MpProduct.allowedQuantities].
  Future<MpActivation> activationCode({
    int? goodsId,
    required int productId,
    int? orderQuantity,
    String? iccid,
    double? price,
    bool? activate,
    String? requestId,
  }) async {
    final data = await _call('POST', '/mp-api/api/esim/v2/activationCode',
        body: {
          if (goodsId != null) 'goodsId': goodsId,
          'productId': productId,
          if (orderQuantity != null) 'orderQuantity': orderQuantity,
          if (iccid != null && iccid.isNotEmpty) 'iccid': iccid,
          if (price != null) 'price': price,
          if (activate != null) 'activateFlag': activate ? 'yes' : 'no',
          if (requestId != null) 'requestId': requestId,
        });
    if (data is! Map) throw MpError('activationCode 返回格式异常');
    return MpActivation.fromJson(data.cast<String, dynamic>());
  }

  /// Buys one eSIM from the market, activates it, and returns the code.
  ///
  /// This is the one-step path: no inventory bookkeeping needed on our side.
  Future<MpActivation> purchaseAndActivationCode({
    required int goodsId,
    required int productId,
    required int orderQuantity,
    bool activate = true,
    String? requestId,
  }) async {
    final data = await _call(
        'POST', '/mp-api/api/esim/v2/purchaseAndActivationCode',
        body: {
          'goodsId': goodsId,
          'productId': productId,
          'orderQuantity': orderQuantity,
          'activateFlag': activate ? 'yes' : 'no',
          if (requestId != null) 'requestId': requestId,
        });
    if (data is! Map) throw MpError('purchaseAndActivationCode 返回格式异常');
    return MpActivation.fromJson(data.cast<String, dynamic>());
  }

  /// Buys stock into inventory without issuing a code.
  Future<void> purchaseOrder({
    required int goodsId,
    required int productId,
    required int orderQuantity,
    required int purchaseTotalCount,
    String? requestId,
  }) =>
      _call('POST', '/mp-api/api/esim/v2/purchaseOrder', body: {
        'goodsId': goodsId,
        'productId': productId,
        'orderQuantity': orderQuantity,
        'purchaseTotalCount': purchaseTotalCount,
        if (requestId != null) 'requestId': requestId,
      });

  // ------------------------------------------------------------- lifecycle

  Future<List<MpOrderStatus>> queryOrderStatus({
    required String orderCode,
    String? requestId,
  }) async {
    final data = await _call('GET', '/mp-api/api/esim/queryOrderStatus', query: {
      'orderCode': orderCode,
      if (requestId != null) 'requestId': requestId,
    });
    return _asList(data).map(MpOrderStatus.fromJson).toList();
  }

  Future<List<MpTraffic>> queryTraffic({
    required String orderCode,
    String? requestId,
  }) async {
    final data = await _call('GET', '/mp-api/api/esim/queryTraffic', query: {
      'orderCode': orderCode,
      if (requestId != null) 'requestId': requestId,
    });
    return _asList(data).map(MpTraffic.fromJson).toList();
  }

  Future<void> switchOrder({
    required String orderCode,
    required MpSwitch action,
    String? requestId,
  }) =>
      _call('POST', '/mp-api/api/esim/switchOrder', body: {
        'orderCode': orderCode,
        'switchButton': action.wire,
        if (requestId != null) 'requestId': requestId,
      });

  /// Tops up an order generated by `activationCode`. Finished orders reject it.
  Future<({int renewPeriod, String orderCode})> topUp({
    required String orderCode,
    String? requestId,
  }) async {
    final data = await _call('POST', '/mp-api/api/esim/v2/topUp', body: {
      'orderCode': orderCode,
      if (requestId != null) 'requestId': requestId,
    });
    if (data is! Map) throw MpError('topUp 返回格式异常');
    final m = data.cast<String, dynamic>();
    return (
      renewPeriod: _int(m['renewPeriod']) ?? 0,
      orderCode: '${m['orderCode'] ?? ''}',
    );
  }

  /// Daily usage rows, oldest first.
  Future<List<({String day, int bytes})>> queryHistoryDailyTraffic({
    required String orderCode,
    String? requestId,
  }) async {
    final data = await _call(
        'GET', '/mp-api/api/esim/v2/queryHistoryDailyTraffic',
        query: {
          'orderCode': orderCode,
          if (requestId != null) 'requestId': requestId,
        });
    if (data is! Map) return const [];
    final rows = (data['dailyTraffic'] as List?) ?? const [];
    return rows
        .whereType<Map>()
        .map((r) => (
              day: '${r['flowUseTime'] ?? ''}',
              bytes: _int(r['useFlow']) ?? 0,
            ))
        .where((r) => r.day.isNotEmpty)
        .toList();
  }

  Future<MpSimInfo> querySimInfo({
    required String iccid,
    String? requestId,
  }) async {
    final data = await _call('GET', '/mp-api/api/esim/v2/querySimInfo', query: {
      'iccid': iccid,
      if (requestId != null) 'requestId': requestId,
    });
    if (data is! Map) return const MpSimInfo();
    return MpSimInfo.fromJson(data.cast<String, dynamic>());
  }

  void close() => _http.close();
}
