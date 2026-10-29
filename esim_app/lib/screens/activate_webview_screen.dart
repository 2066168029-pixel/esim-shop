import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;
import 'package:webview_flutter/webview_flutter.dart';

import '../theme.dart';

/// In-app WebView that opens the upstream activation portal's DEVICE page.
///
/// Flow: the portal's device page (`index.html`) needs a server session that is
/// created by `card/login.do?iccidMark=<ICCID>`. So when an ICCID is provided we
/// silently load that login endpoint first (it sets the session cookie), then
/// load the device page. The user never sees the intermediate login screen.
class ActivateWebViewScreen extends StatefulWidget {
  static const portalBase =
      'https://api.zkm4m.cn/kyhl-weixin-1.0';

  /// ICCID / card number the customer typed or scanned. May be empty (then we
  /// just open the portal login page so they can log in manually).
  final String iccid;
  final String title;

  const ActivateWebViewScreen({super.key, this.iccid = '', this.title = '激活'});

  @override
  State<ActivateWebViewScreen> createState() => _ActivateWebViewScreenState();
}

class _ActivateWebViewScreenState extends State<ActivateWebViewScreen> {
  late final WebViewController _controller;
  int _progress = 0;
  bool _failed = false;
  bool _silentLoginDone = false;
  String? _lastError;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) => setState(() => _progress = p),
          onPageStarted: (_) => setState(() => _failed = false),
          onPageFinished: (url) {
            setState(() => _progress = 100);
            // After the silent login completes, jump straight to the device page.
            final iccid = widget.iccid.trim();
            if (iccid.isNotEmpty &&
                !_silentLoginDone &&
                url.contains('/card/login.do')) {
              _silentLoginDone = true;
              _loadDevicePage();
            }
          },
          onWebResourceError: (e) {
            if (e.isForMainFrame ?? true) {
              setState(() {
                _failed = true;
                _lastError =
                    '${e.errorCode}${e.description.isNotEmpty ? ' · ${e.description}' : ''}';
              });
            }
          },
        ),
      );
    _boot();
  }

  void _boot() {
    final iccid = widget.iccid.trim();
    if (iccid.isEmpty) {
      // No card number: show the portal directly (user logs in there).
      _controller.loadRequest(Uri.parse(
          '${ActivateWebViewScreen.portalBase}/pages/login.html'));
      return;
    }
    // 1) silently establish the session, 2) onPageFinished -> device page.
    _controller.loadRequest(Uri.parse(
        '${ActivateWebViewScreen.portalBase}/card/login.do?iccidMark=${Uri.encodeComponent(iccid)}'));
  }

  void _loadDevicePage() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    _controller.loadRequest(Uri.parse(
        '${ActivateWebViewScreen.portalBase}/pages/index.html?__v=$ts'));
  }

  @override
  Widget build(BuildContext context) {
    final navigator = Navigator.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _controller.canGoBack()) {
          _controller.goBack();
        } else {
          navigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          title: Text(widget.title),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              if (await _controller.canGoBack()) {
                _controller.goBack();
              } else {
                navigator.pop();
              }
            },
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                _silentLoginDone = false;
                _boot();
              },
            ),
          ],
          bottom: _progress < 100
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(
                    value: _progress / 100,
                    minHeight: 2,
                    backgroundColor: Colors.transparent,
                    valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                  ),
                )
              : null,
        ),
        body: _failed ? _errorView() : WebViewWidget(controller: _controller),
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded, size: 54, color: AppColors.muted),
            const SizedBox(height: 14),
            const Text('激活页面无法加载',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text('请检查手机网络后点击“重试”。\n如果一直失败，请确认：\n• 手机已联网（可切换 WiFi / 流量试试）\n• 未开启会拦截第三方页面的 VPN / 广告拦截',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppColors.textSub, height: 1.6)),
            if (_lastError != null) ...[
              const SizedBox(height: 8),
              Text('错误：$_lastError',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11, color: AppColors.muted)),
            ],
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: () => _openInBrowser(),
                  child: const Text('用浏览器打开'),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _failed = false;
                      _silentLoginDone = false;
                    });
                    _boot();
                  },
                  child: const Text('重试'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Open the activation portal in the system browser — a fallback when the
  /// in-app WebView can't reach the third-party portal (blocked network,
  /// expired TLS, VPN, etc.).
  void _openInBrowser() {
    final iccid = widget.iccid.trim();
    final url = iccid.isEmpty
        ? '${ActivateWebViewScreen.portalBase}/pages/login.html'
        : '${ActivateWebViewScreen.portalBase}/card/login.do?iccidMark=${Uri.encodeComponent(iccid)}';
    try {
      url_launcher.launchUrl(Uri.parse(url),
          mode: url_launcher.LaunchMode.externalApplication);
    } catch (_) {}
  }
}
