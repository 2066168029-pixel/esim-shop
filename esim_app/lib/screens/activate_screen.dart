import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../esim_installer.dart';
import '../native_lpa.dart';
import '../store.dart';
import '../theme.dart';
import '../topbar.dart';
import '../widgets.dart';
import 'card_portal_screen.dart';
import 'card_writer_screen_v3.dart';
import 'native_lpa_screen.dart';
import 'scan_screen.dart';
import '../main.dart' show showSnack;
import 'login_screen.dart';

class ActivateScreen extends StatefulWidget {
  const ActivateScreen({super.key});
  @override
  State<ActivateScreen> createState() => _ActivateScreenState();
}

class _ActivateScreenState extends State<ActivateScreen> {
  final _code = TextEditingController();
  bool _scanning = false;

  /// null while the capability probe is still running.
  ESimCapability? _cap;
  bool _installing = false;

  @override
  void initState() {
    super.initState();
    ESimInstaller.capability().then((c) {
      if (mounted) setState(() => _cap = c);
    });
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _confirm() {
    _openPortal(_code.text.trim());
  }

  /// Install the scanned/pasted activation code directly on this phone.
  ///
  /// Android only -- the platform LPA handles it. On iOS (or a phone without
  /// an eUICC) we steer the customer to the QR flow instead of failing silently.
  Future<void> _installHere() async {
    if (_installing) return;
    final raw = _code.text.trim();
    final code = ActivationCode.parse(raw);

    if (code == null) {
      showSnack(context, 'That does not look like an eSIM activation code. '
          'Scan the QR code or paste the code starting with LPA:1');
      return;
    }

    final cap = await ESimInstaller.capability();
    if (!mounted) return;
    if (!cap.supported) {
      setState(() => _cap = cap);
      showSnack(context, cap.message);
      return;
    }

    setState(() => _installing = true);
    try {
      final out = await ESimInstaller.install(code);
      if (!mounted) return;
      showSnack(context, out.message);
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  /// 用原生页面查询这张卡的套餐并充值。
  ///
  /// 以前这里跳的是上游的 WebView 门户（api.zkm4m.cn/kyhl-weixin-1.0），
  /// 现在改走我们自己的 /api/card 接口，体验和配色都统一了。
  void _openPortal(String iccid) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CardPortalScreen(iccid: iccid),
      ),
    );
  }

  /// Opens the card writer, preferring the vendor-native LPA SDK on iOS.
  ///
  /// The Linksfield xcframework handles BLE + LPA on device, so on iOS we use
  /// it when present. Simulator builds and every other platform fall back to
  /// the pure-Dart transport in `card_writer_screen_v3.dart`.
  Future<void> _openCardWriter() async {
    var useNative = false;
    if (Platform.isIOS) {
      useNative = await NativeLpa.isAvailable;
    }
    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            useNative ? const NativeLpaScreen() : const CardWriterScreenV2(),
      ),
    );
  }

  /// Scan a QR / barcode (incl. the ICCID 1D barcode on SIM packaging).
  /// The decoded code is written back into the ICCID input box so the customer
  /// can review it before tapping 确认/开始激活. (Previously we navigated away
  /// immediately, which made it look like nothing was filled in.)
  Future<void> _scan() async {
    if (_scanning) return;
    _scanning = true;
    // Captured once for the whole flow: this method has no `t` in scope and
    // the language cannot change while the scanner is open.
    final t = context.read<AppState>().t;
    try {
      final code = await Navigator.push<String>(
        context,
        MaterialPageRoute(builder: (_) => const ScanScreen()),
      );
      if (!mounted || code == null || code.trim().isEmpty) return;
      final v = code.trim();
      setState(() => _code.text = v);
      // move the caret to the end so the value is visibly "just filled in"
      _code.selection = TextSelection.collapsed(offset: v.length);
      FocusScope.of(context).unfocus();
      showSnack(context, t.iccidDetected(v));
    } catch (e) {
      // The camera could not be started (no permission / no camera / plugin
      // error). Tell the customer instead of leaving them on a dead card.
      if (mounted) {
        showSnack(context, t.cameraOpenFailed('$e'), error: true);
      }
    } finally {
      _scanning = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final t = app.t;

    // 激活的一切功能都要账号（写卡记录、绑定关系、后续查询都挂在账号上），
    // 未登录直接挡在这里，而不是让用户填完激活码才失败。
    if (!app.isLoggedIn) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: Container(
          decoration: const BoxDecoration(gradient: AppColors.skyBackground),
          child: SafeArea(
            child: Column(
              children: [
                const TopBar(),
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 84,
                            height: 84,
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.10),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.sim_card_outlined,
                                size: 40, color: AppColors.primary),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            t.signInToActivate,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            t.signInRequired,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 12.5, color: AppColors.muted, height: 1.6),
                          ),
                          const SizedBox(height: 24),
                          SizedBox(
                            width: double.infinity,
                            height: 46,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                              onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const LoginScreen()),
                              ),
                              child: Text(t.logIn,
                                  style: const TextStyle(
                                      fontSize: 15, fontWeight: FontWeight.w700)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.skyBackground),
        child: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              const TopBar(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                child: Text(t.activateEsim, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.8)),
              ),

              // Blue QR scan card — tap to open the camera scanner
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: GestureDetector(
                  onTap: _scan,
                  child: Container(
                    height: 240,
                    decoration: BoxDecoration(
                      gradient: AppColors.navyCard,
                      borderRadius: BorderRadius.circular(AppRadii.big),
                      boxShadow: const [BoxShadow(color: Color(0x330A66FF), blurRadius: 22, offset: Offset(0, 10))],
                    ),
                    child: Stack(
                      children: [
                        // scan frame corners
                        Positioned.fill(child: CustomPaint(painter: _ScanFramePainter())),
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.qr_code_scanner, color: Colors.white, size: 64),
                              const SizedBox(height: 14),
                              Text(t.scanYourQr, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                              const SizedBox(height: 6),
                              Text(t.cameraRequired, style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),

              // Bluetooth card writer: install the profile onto a physical
              // eUICC card instead of this phone's built-in eSIM.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: GestureDetector(
                  onTap: () => _openCardWriter(),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppRadii.big),
                      border: Border.all(color: const Color(0xFFE3E8EF)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: const Color(0xFFEAF3FF),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.bluetooth_connected,
                              color: AppColors.primary),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(t.btWrite,
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700)),
                              SizedBox(height: 3),
                              Text(t.btWriteDesc,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: AppColors.muted)),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right, color: AppColors.muted),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),

              // Manual code entry
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.enterCode, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _code,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(hintText: t.typeCode, prefixIcon: const Icon(Icons.sim_card_outlined, color: AppColors.muted)),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(onPressed: _confirm, child: Text(t.confirmBtn)),
                      ),
                      // Only offer the native install when the device can do it.
                      if (_cap?.supported == true) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _installing ? null : _installHere,
                            icon: _installing
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.sim_card_rounded, size: 18),
                            label: Text(_installing ? 'Installing…' : 'Install to this phone'),
                          ),
                        ),
                      ] else if (_cap != null && !_cap!.supported) ...[
                        const SizedBox(height: 8),
                        Text(
                          _cap!.message,
                          style: const TextStyle(fontSize: 11.5, color: AppColors.muted, height: 1.4),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),

              // 3 steps
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    _step(1, Icons.qr_code_scanner, t.stepScan),
                    _stepLine(),
                    _step(2, Icons.verified_outlined, t.stepConfirm),
                    _stepLine(),
                    _step(3, Icons.wifi, t.stepConnect),
                  ],
                ),
              ),
              const SizedBox(height: 22),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: ElevatedButton.icon(
                  onPressed: _confirm,
                  icon: const Icon(Icons.rocket_launch, size: 18),
                  label: Text(t.startActivation),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(t.support247, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _step(int n, IconData icon, String label) => Expanded(
        child: Column(
          children: [
            Container(
              width: 54, height: 54,
              decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: const [BoxShadow(color: Color(0x0F1E3A8A), blurRadius: 12)]),
              child: Stack(
                children: [
                  Center(child: Icon(icon, color: AppColors.primary, size: 24)),
                  Positioned(
                    right: 0, top: 0,
                    child: Container(
                      width: 18, height: 18,
                      decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: Text('$n', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
          ],
        ),
      );

  Widget _stepLine() => Expanded(child: Container(height: 2, margin: const EdgeInsets.only(bottom: 26), color: AppColors.border));
}

class _ScanFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    const m = 26.0, len = 26.0;
    // four corner brackets
    final pts = [
      [Offset(m, m), Offset(m + len, m)],
      [Offset(m, m), Offset(m, m + len)],
      [Offset(size.width - m, m), Offset(size.width - m - len, m)],
      [Offset(size.width - m, m), Offset(size.width - m, m + len)],
      [Offset(m, size.height - m), Offset(m + len, size.height - m)],
      [Offset(m, size.height - m), Offset(m, size.height - m - len)],
      [Offset(size.width - m, size.height - m), Offset(size.width - m - len, size.height - m)],
      [Offset(size.width - m, size.height - m), Offset(size.width - m, size.height - m - len)],
    ];
    for (final seg in pts) {
      canvas.drawLine(seg[0], seg[1], p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
