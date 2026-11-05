import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import '../store.dart';

/// Full-screen QR / barcode scanner built on **flutter_zxing** (ZXing native,
/// not Google MLKit). ZXing decodes both 2D (QR / DataMatrix / PDF417) and 1D
/// barcodes (Code128 / Code39 / EAN / UPC / ITF) — the last is what an ICCID
/// printed as a barcode uses.
///
/// The previous implementation used `mobile_scanner`, whose MLKit camera stack
/// failed to start on the target device ("无法启动相机"). This page uses ZXing's
/// own camera handling via [ReaderWidget] instead.
///
/// Pops with the decoded (normalised) code, or null if the user cancels.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _handled = false;

  /// Pull an ICCID / card number out of the scanned text. The portal device page
  /// is opened by ICCID (card/login.do?iccidMark=ICCID), so for plain numbers
  /// we return the ICCID digits themselves.
  static String _digits(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

  static String _extract(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return '';

    // 0) LPA 激活码必须最先判断，原样返回。
    //
    // 之前 URL 解析排在这一步前面：LPA 串里带 ?code=xxx 时
    // （部分运营商的激活码确实带参数），Uri.tryParse 会把它当查询参数，
    // 结果 _extract 只返回 "xxx"，LPA 串被截断 —— 写卡必然失败。
    if (t.toUpperCase().startsWith('LPA:')) return t;

    // 1) URL with query params (QR pointing at an activation link)
    final uri = Uri.tryParse(t);
    if (uri != null && uri.hasScheme && uri.queryParameters.isNotEmpty) {
      for (final k in const [
        'cardId',
        'iccidMark',
        'iccid',
        'iccidcode',
        'cardid',
        'code',
      ]) {
        final v = uri.queryParameters[k];
        if (v != null && v.trim().isNotEmpty) {
          // 参数值本身可能就是一条 LPA 串，别二次加工
          return v.trim();
        }
      }
    }
    // 3) Labelled ICCID: `ICCID:8985...`
    final m = RegExp(r'ICCID[:\s]*([0-9]{15,22})', caseSensitive: false).firstMatch(t);
    if (m != null) return m.group(1)!;
    // 3) Plain 15-22 digit number (common for a 1D ICCID barcode)
    final digits = _digits(t);
    if (digits.length >= 15 && digits.length <= 22) return digits;
    // 4) Fall back to raw text (serial / matching id)
    return t;
  }

  void _onScan(Code code) {
    if (_handled) return;
    final raw = code.text;
    debugPrint('[Scan] decoded raw = $raw (format=${code.format})');
    if (raw == null || raw.trim().isNotEmpty == false) {
      debugPrint('[Scan] empty payload, ignoring');
      return;
    }
    _handled = true;
    final out = _extract(raw);
    debugPrint('[Scan] extracted   = $out');
    Navigator.of(context).pop(out);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.read<AppState>().t;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(t.snTitle),
      ),
      body: ReaderWidget(
        // Any format: QR + Code128/39/93 + EAN/UPC + ITF + DataMatrix/PDF417.
        codeFormat: Format.any,
        tryHarder: true,
        // ICCID barcodes are often long/narrow — search both orientations.
        tryRotate: true,
        tryInverted: true,
        showScannerOverlay: true,
        showFlashlight: true,
        showToggleCamera: true,
        showGallery: true,
        scanDelay: const Duration(milliseconds: 400),
        resolution: ResolutionPreset.high,
        onScan: _onScan,
        onScanFailure: (Object e) {
          // 每一帧解不出来都会回调，正常情况下大量触发，只在调试时打日志，
          // 不能弹提示（会刷屏）。
          debugPrint('[Scan] frame not decoded: $e');
        },
      ),
    );
  }
}
