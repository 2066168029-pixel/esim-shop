/// Opens Alipay's H5 cashier in a WebView and reports when the order settles.
///
/// ## Why H5 instead of the native SDK
///
/// The native route needs the Alipay SDK on the device plus URL-scheme
/// hand-back (`payV2` -> `alipays://` result callback). On iOS that means
/// embedding `AlipaySDK-iOS`, declaring a scheme in Info.plist and testing on a
/// signed build before anything can be verified. The H5 cashier is the same
/// merchant page Alipay renders in a mobile browser: no native dependency, no
/// URL scheme, identical behaviour on Android and iOS.
///
/// Payment is always confirmed by polling the backend, never by trusting the
/// page: the WebView can be closed halfway, but Alipay's async notification
/// still lands on our server and settles the order there.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Result of one H5 checkout attempt.
enum AlipayH5Result {
  /// Backend reported paid/fulfilled.
  paid,

  /// User closed the page before paying; the order stays pending.
  cancelled,
}

/// Builds the page that auto-posts the signed order string to the gateway.
///
/// The signed `order_string` is a query string; posting it as hidden form
/// fields avoids query-string loss on cross-host redirects inside WebViews.
String alipayH5Html(String chargeUrl, String orderString) {
  final fields = Uri.splitQueryString(orderString);
  final inputs = fields.entries
      .map((e) =>
          '<input type="hidden" name="${_esc(e.key)}" value="${_esc(e.value)}">')
      .join();
  return '''
<!DOCTYPE html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
 html,body{height:100%;margin:0;background:#f5f7fb;
   font-family:-apple-system,"PingFang SC","Microsoft YaHei",sans-serif}
 .box{height:100%;display:flex;flex-direction:column;align-items:center;
   justify-content:center;gap:14px;color:#5A6478;font-size:14px}
 .spin{width:34px;height:34px;border:3px solid #d9e6fb;border-top-color:#1A73E8;
   border-radius:50%;animation:s 1s linear infinite}
 @keyframes s{to{transform:rotate(360deg)}}
</style></head>
<body>
 <div class="box">
   <div class="spin"></div>
   <div>正在前往支付宝…</div>
 </div>
 <form id="f" method="post" action="${_esc(chargeUrl)}">$inputs</form>
 <script>document.getElementById('f').submit();</script>
</body></html>
''';
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

/// Full-screen Alipay H5 cashier.
///
/// Pops with:
///   - [AlipayH5Result.paid]      order settled (verified server-side)
///   - [AlipayH5Result.cancelled] user backed out before paying
class AlipayH5PayPage extends StatefulWidget {
  /// Gateway endpoint, e.g. `https://openapi.alipay.com/gateway.do`.
  ///
  /// Ignored when [hostedUrl] is set (Alipay Global / Antom returns a ready
  /// cashier URL instead of a signed form body).
  final String chargeUrl;

  /// Signed order string from `/api/payments/alipay/create`.
  final String orderString;

  /// Ready-made cashier URL (Antom `normal_url`). When present the page simply
  /// loads it instead of auto-posting the signed form.
  final String hostedUrl;

  /// Window title, so the same screen serves domestic and global Alipay.
  final String title;

  /// Polls `/api/payments/alipay/status`; returns the order status.
  final Future<String> Function() checkStatus;

  final Duration pollInterval;

  const AlipayH5PayPage({
    super.key,
    this.chargeUrl = "",
    this.orderString = "",
    this.hostedUrl = "",
    this.title = "支付宝付款",
    required this.checkStatus,
    this.pollInterval = const Duration(seconds: 3),
  });

  @override
  State<AlipayH5PayPage> createState() => _AlipayH5PayPageState();
}

class _AlipayH5PayPageState extends State<AlipayH5PayPage> {
  late final WebViewController _controller;
  Timer? _timer;
  bool _settled = false;
  bool _hintShown = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFF5F7FB))
      // `alipays://` / `alipayqr://` / `taobao://` inside the cashier: let the
      // OS route them, otherwise the WebView shows a bare error page.
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (req) {
          final url = req.url;
          if (url.startsWith('http://') || url.startsWith('https://')) {
            return NavigationDecision.navigate;
          }
          if (url.startsWith('alipays://') || url.startsWith('alipayqr://')) {
            // Handing off to the Alipay app works; the result still arrives by
            // polling, so there is nothing to capture here.
            _tryExternal(url);
          }
          return NavigationDecision.prevent;
        },
      ))
      ..loadRequest(
        widget.hostedUrl.isNotEmpty
            ? Uri.parse(widget.hostedUrl)
            : Uri.dataFromString(
                alipayH5Html(widget.chargeUrl, widget.orderString),
                mimeType: 'text/html',
                encoding: Encoding.getByName('utf-8'),
              ),
      );
    _timer = Timer.periodic(widget.pollInterval, (_) => _poll());
  }

  Future<void> _tryExternal(String url) async {
    // The H5 cashier at mclient.alipay.com is only a launcher page: its body is
    // just "加载中" and all the real work happens after it hands off to the
    // Alipay app via an alipays:// scheme. Swallowing that hand-off is exactly
    // what leaves the WebView stuck on a blank page, so hand it to the OS.
    // Settlement is still confirmed by polling, never by this callback.
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      debugPrint('alipay h5: hand-off $url -> $ok');
      if (!ok && mounted) {
        _showHandoffHint();
      }
    } catch (e) {
      debugPrint('alipay h5: hand-off failed $e');
      if (mounted) _showHandoffHint();
    }
  }

  /// No Alipay app installed: say so instead of leaving a blank screen.
  void _showHandoffHint() {
    if (_hintShown) return;
    _hintShown = true;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('未能打开支付宝，请确认已安装支付宝 App；也可返回后重新发起支付'),
        duration: Duration(seconds: 6),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_settled) return;
    try {
      final status = await widget.checkStatus();
      if (status == 'paid' || status == 'fulfilled') {
        _finish(AlipayH5Result.paid);
      }
    } catch (_) {
      // Network hiccup: keep polling; settlement happens server-side.
    }
  }

  void _finish(AlipayH5Result r) {
    if (_settled) return;
    _settled = true;
    _timer?.cancel();
    if (!mounted) return;
    Navigator.of(context).pop(r);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Leaving the cashier is an explicit cancel, so the caller can tell the
      // user the order is still pending instead of silently dropping it.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish(AlipayH5Result.cancelled);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => _finish(AlipayH5Result.cancelled),
          ),
        ),
        body: WebViewWidget(controller: _controller),
      ),
    );
  }
}
