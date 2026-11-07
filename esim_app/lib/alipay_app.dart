import 'dart:async';

import 'package:flutter/services.dart';

/// 支付宝 App 支付结果。
///
/// 注意：这里的 `success` 只表示**支付宝端流程走完了**，不代表钱到账。
/// 真正的到账判定永远来自服务端异步通知，所以调用方拿到结果后应该
/// 再去轮询 `/api/payments/alipay/status`，而不是直接发放 eSIM。
class AlipayAppResult {
  /// 支付宝返回码：9000 成功 / 6001 用户取消 / 8000 处理中 / error 本地异常
  final String resultStatus;
  final String memo;
  final String raw;

  const AlipayAppResult({
    required this.resultStatus,
    required this.memo,
    required this.raw,
  });

  bool get success => resultStatus == '9000';
  bool get cancelled => resultStatus == '6001';

  /// 8000 表示支付宝那边还没出结果，需要继续等服务端通知。
  bool get pending => resultStatus == '8000';

  factory AlipayAppResult.fromMap(Map<dynamic, dynamic> m) {
    return AlipayAppResult(
      resultStatus: (m['resultStatus'] as String?) ?? '',
      memo: (m['memo'] as String?) ?? '',
      raw: (m['result'] as String?) ?? '',
    );
  }

  String get friendlyMessage {
    switch (resultStatus) {
      case '9000':
        return '支付完成，正在确认到账…';
      case '6001':
        return '已取消支付，订单仍保留';
      case '8000':
        return '支付处理中，请稍候在订单页查看结果';
      case '6002':
        return '网络异常，请检查网络后重试';
      case '4000':
        return '支付失败（订单已失效或已被支付）';
      case '5000':
        return '支付失败，请重试';
      default:
        return memo.isNotEmpty ? memo : '支付未完成';
    }
  }
}

/// 调用原生 App 支付 SDK。
///
/// 为什么不用 H5：
///   支付宝的 H5 收银台（mclient.alipay.com/h5pay/landing）只是个「跳板」，
///   正文永远只有“加载中”，实际靠 alipays:// 唤起客户端。WebView 里这条
///   链路在真机上极不稳定 —— 要么白屏，要么跳到 App 后回不来。
///   App 支付 SDK 走的是官方通道，付完自动回到 App 并带回结果。
///
/// 两端实现：
///   Android → PayTask.payV2（alipaysdk-android）
///   iOS     → AlipaySDK payOrder:fromScheme:（AlipaySDK.framework）
class AlipayAppPay {
  static const MethodChannel _channel = MethodChannel('onlylink/alipay');

  /// 拉起支付宝并等待结果。
  ///
  /// [orderInfo] 必须是服务端 `/api/payments/alipay/app-create` 返回的
  /// 已签名字符串，客户端绝不能自己拼或签名。
  static Future<AlipayAppResult> pay(String orderInfo) async {
    if (orderInfo.isEmpty) {
      return const AlipayAppResult(
        resultStatus: 'error',
        memo: '订单信息为空',
        raw: '',
      );
    }
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'pay',
        {'orderInfo': orderInfo},
      );
      if (res == null) {
        return const AlipayAppResult(
          resultStatus: 'error',
          memo: '支付没有返回结果',
          raw: '',
        );
      }
      return AlipayAppResult.fromMap(res);
    } on PlatformException catch (e) {
      return AlipayAppResult(
        resultStatus: 'error',
        memo: e.message ?? '支付调用失败',
        raw: '',
      );
    } on MissingPluginException {
      // 原生通道没接上（比如旧包）：明确告知，不要静默失败。
      return const AlipayAppResult(
        resultStatus: 'error',
        memo: '当前版本不支持 App 支付，请更新到最新版',
        raw: '',
      );
    }
  }

  /// 设备上是否装了支付宝。
  static Future<bool> isInstalled() async {
    try {
      return await _channel.invokeMethod<bool>('isInstalled') ?? false;
    } catch (_) {
      return false;
    }
  }
}
