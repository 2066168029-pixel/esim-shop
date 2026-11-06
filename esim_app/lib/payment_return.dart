// 支付回调工具 —— 让「付完款回到 App」这件事自动发生。
//
// 原先的流程是：跳浏览器 → 回来后弹框让用户手动点「确认支付」。
// 那是个设计缺陷：用户不点，订单永远 pending；点了又不知道到底付没付。
//
// 这里的做法不依赖 URL Scheme 或深度链接（那需要改 Xcode / Info.plist，
// 而且支付宝、PayPal、微信各不一样），而是：
//
//   1. 支付前记一笔「有订单在支付中」
//   2. App 回到前台时（AppLifecycleState.resumed）自动去问后端订单状态
//   3. 后端状态已经是 paid / fulfilled 就算成功
//   4. PayPal 还有 capture 这一步，也在这时自动补上
//
// 这样 iOS / Android 一套逻辑，且不依赖任何平台配置。
import 'dart:async';

import 'package:flutter/widgets.dart';

/// 有订单正在支付中。App 回到前台时 PendingPayment 会去核对。
class PendingPayment {
  PendingPayment._();

  static final PendingPayment instance = PendingPayment._();

  /// 正在等待结果的订单号；空表示当前没有支付在飞。
  String? orderNo;

  /// 支付渠道：alipay / paypal。
  String? provider;

  /// 这次支付是从什么时候开始的（用来限制最长等待时间）。
  DateTime? startedAt;

  /// 已经核对过、不再重复处理的订单，避免回到前台时反复请求。
  final Set<String> _settled = <String>{};

  void begin(String order, String byProvider) {
    orderNo = order;
    provider = byProvider;
    startedAt = DateTime.now();
    _settled.remove(order);
  }

  void clear() {
    orderNo = null;
    provider = null;
    startedAt = null;
  }

  bool get isSettled {
    final o = orderNo;
    return o == null || _settled.contains(o);
  }

  void markSettled(String order) {
    _settled.add(order);
    if (orderNo == order) clear();
  }

  /// 超过 15 分钟还没结果就放弃，避免无限轮询。
  bool get isStale {
    final t = startedAt;
    if (t == null) return false;
    return DateTime.now().difference(t).inMinutes > 15;
  }
}

/// 挂到任何一个长期存在的 Widget（订单详情页）上，
/// 把它和 App 生命周期连起来。
class PaymentReturnWatcher with WidgetsBindingObserver {
  PaymentReturnWatcher({required this.onReturn, required this.onCheck});

  /// App 回到前台时调用，用来显示「正在确认支付结果…」
  final VoidCallback onReturn;

  /// 真正去核对订单状态；返回 true 表示已经付款成功
  final Future<bool> Function() onCheck;

  bool _checking = false;

  void attach() => WidgetsBinding.instance.addObserver(this);
  void detach() => WidgetsBinding.instance.removeObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (PendingPayment.instance.orderNo == null) return;
    if (PendingPayment.instance.isSettled) return;
    if (PendingPayment.instance.isStale) {
      PendingPayment.instance.clear();
      return;
    }
    if (_checking) return;

    _checking = true;
    onReturn();
    // 给后端几秒钟把支付宝的异步通知处理完，再问第一次
    _poll();
  }

  Future<void> _poll() async {
    // 退避重试：2s, 4s, 6s, 8s —— 一共约 20 秒
    for (var attempt = 0; attempt < 4; attempt++) {
      await Future<void>.delayed(Duration(seconds: 2 + attempt * 2));
      if (PendingPayment.instance.orderNo == null) break;
      try {
        final done = await onCheck();
        if (done) break;
      } catch (_) {
        // 网络抖动不重要，下一轮再试
      }
    }
    _checking = false;
  }
}
