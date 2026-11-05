import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../store.dart';
import '../theme.dart';
import '../widgets.dart';

/// Invite-a-friend: a shareable poster carrying the account's invite code.
///
/// The poster is rendered inside a RepaintBoundary so "保存海报" can capture
/// exactly what the user sees instead of rebuilding a second layout in a
/// custom paint (which drifts from the on-screen version).
class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key});

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  final _posterKey = GlobalKey();
  Map<String, dynamic>? _data;
  Map<String, dynamic>? _voucher;
  String? _err;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _err = null);
    try {
      final app = context.read<AppState>();
      final d = await app.api.referralMe();
      Map<String, dynamic>? v;
      try {
        v = await app.api.myVoucher();
      } catch (_) {
        v = null;
      }
      if (!mounted) return;
      setState(() {
        _data = d;
        _voucher = v;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _err = '$e');
    }
  }

  Future<void> _copyCode() async {
    final code = _data?['code'] as String? ?? '';
    if (code.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(context.read<AppState>().t.copyInviteCode),
      backgroundColor: AppColors.success,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _savePoster() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ctx = _posterKey.currentContext;
      if (ctx == null) throw 'poster not ready';
      final boundary = ctx.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw 'encode failed';
      final data = bytes.buffer.asUint8List();

      // 真正写进系统相册（Android 10+ 无需额外权限；
      // Android 9 及以下需要 WRITE_EXTERNAL_STORAGE，已在清单里声明）。
      await Gal.putImageBytes(data, name: 'onlylink_invite_${_data?['code'] ?? ''}');

      // 顺带把邀请文案放进剪贴板，方便直接粘贴到聊天窗口。
      await Clipboard.setData(ClipboardData(text: _shareText()));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(context.read<AppState>().t.saved),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$e'),
        backgroundColor: AppColors.danger,
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _shareText() {
    final code = _data?['code'] ?? '';
    final path = _data?['invite_path'] ?? '';
    return 'OnlyLinkCard 5% off\nCode: $code\n$path';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.watch<AppState>().t;
    final poster = (_data?['poster'] as Map?)?.cast<String, dynamic>() ?? {};
    final code = _data?['code'] as String? ?? '';
    final stats = (_data?['stats'] as Map?)?.cast<String, dynamic>() ?? {};

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text(t.inviteFriends)),
      body: _err != null
          ? errorBox(_err!)
          : _data == null
              ? loadingBox()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: [
                    // ---------------- poster ----------------
                    RepaintBoundary(
                      key: _posterKey,
                      // 画布严格保持海报原始比例（1080x1620）。之前用 BoxFit.cover
                      // 会被屏幕比例裁切，导致叠在图上的二维码/邀请码整体偏移。
                      child: AspectRatio(
                        aspectRatio: 1080 / 1620,
                        child: LayoutBuilder(builder: (context, canvas) {
                          final cw = canvas.maxWidth;
                          final ch = canvas.maxHeight;
                          // 二维码按「印刷框」尺寸放大到 96%，保持正方形居中
                          // 印刷 QR 框：259x190 px（1080x1620 海报）
                          final qrBoxW = cw * 0.2398;
                          final qrBoxH = ch * 0.1173;
                          // 框是扁的，正方形二维码受高度限制，取 99% 尽量放大
                          final qrSide = (qrBoxW < qrBoxH ? qrBoxW : qrBoxH) * 0.99;
                          final qrLeft = cw * 0.6889 + (qrBoxW - qrSide) / 2;
                          final qrTop = ch * 0.7426 + (qrBoxH - qrSide) / 2;

                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.asset("assets/invite_poster.jpg",
                                  fit: BoxFit.fill),
                              // 海报「Your Invitation Code」虚线框
                              // 实测边界（1080x1620 海报坐标）：
                              //   x 96..544  y 1268..1347
                              // 上一版用的是 x 422..646（整块右半面板），所以文字看起来
                              // 偏右、没落在虚线框里。这里按虚线框真实边界居中。
                              Positioned(
                                left: cw * (96 / 1080),
                                top: ch * (1268 / 1620),
                                width: cw * ((544 - 96) / 1080),
                                height: ch * ((1347 - 1268) / 1620),
                                child: Center(
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      code,
                                      style: const TextStyle(
                                        color: Color(0xFF1F3F7A),
                                        fontSize: 30,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 1.5,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              // 海报留好的 QR 框
                              Positioned(
                                left: qrLeft,
                                top: qrTop,
                                width: qrSide,
                                height: qrSide,
                                child: Container(
                                  color: Colors.white,
                                  child: QrImageView(
                                    data: (poster['qr_text'] ?? code).toString(),
                                    backgroundColor: Colors.white,
                                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                                  ),
                                ),
                              ),
                            ],
                          );
                        }),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ---------------- cash voucher ----------------
                    if (_voucher != null)
                      AppCard(
                        child: Row(children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: AppColors.success.withValues(alpha: .12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.redeem_rounded,
                                size: 21, color: AppColors.success),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(t.cashVoucher,
                                    style: const TextStyle(
                                        fontSize: 13, fontWeight: FontWeight.w700)),
                                const SizedBox(height: 2),
                                Text(t.voucherNote,
                                    style: const TextStyle(
                                        fontSize: 11, color: AppColors.muted)),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '¥${(_voucher!['balance'] as num? ?? 0).toStringAsFixed(2)}',
                                style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.success),
                              ),
                              Text(t.voucherBalance,
                                  style: const TextStyle(
                                      fontSize: 10.5, color: AppColors.muted)),
                            ],
                          ),
                        ]),
                      ),
                    const SizedBox(height: 12),

                    // ---------------- stats ----------------
                    Row(children: [
                      Expanded(child: _statCard(t.invitedFriends, '${stats['invited'] ?? 0}')),
                      const SizedBox(width: 10),
                      Expanded(child: _statCard(t.qualifiedFriends, '${stats['qualified'] ?? 0}')),
                    ]),
                    const SizedBox(height: 16),

                    // ---------------- rules ----------------
                    AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(t.inviteSubtitle,
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                          const SizedBox(height: 10),
                          for (final r in (poster['rules'] as List?) ?? const [])
                            Padding(
                              padding: const EdgeInsets.only(bottom: 7),
                              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                const Icon(Icons.check_circle_rounded,
                                    size: 15, color: AppColors.success),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text('$r',
                                      style: const TextStyle(
                                          fontSize: 12.5, height: 1.45, color: AppColors.textSub)),
                                ),
                              ]),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),

                    // ---------------- actions ----------------
                    Row(children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _copyCode,
                          icon: const Icon(Icons.copy_rounded, size: 17),
                          label: Text(t.copyInviteCode),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _busy ? null : _savePoster,
                          icon: _busy
                              ? const SizedBox(
                                  width: 15,
                                  height: 15,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.ios_share_rounded, size: 17),
                          label: Text(t.savePoster),
                        ),
                      ),
                    ]),
                  ],
                ),
    );
  }

  Widget _statCard(String label, String value) => AppCard(
        child: Column(
          children: [
            Text(value,
                style: const TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.primary)),
            const SizedBox(height: 3),
            Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.muted)),
          ],
        ),
      );
}
