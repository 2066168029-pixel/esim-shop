import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Result of an eSIM install attempt.
enum ESimResult { ok, unsupported, badCode, cancelled, failed }

/// Outcome of asking the platform whether it can install an eSIM.
class ESimCapability {
  final bool supported;
  final String? reason;
  final int? apiLevel;

  const ESimCapability({required this.supported, this.reason, this.apiLevel});

  const ESimCapability.unsupported(String r)
      : supported = false,
        reason = r,
        apiLevel = null;

  /// Customer-facing explanation, not a stack trace.
  String get message {
    switch (reason) {
      case 'android_too_old':
        return 'This phone runs an Android version without eSIM support (needs Android 9+).';
      case 'no_euicc_service':
        return 'This phone has no eSIM hardware. Use the QR code on another device.';
      case 'euicc_disabled':
        return 'eSIM is disabled on this phone. Enable it in system settings first.';
      case 'ios':
        return 'Use the QR code below, or open Settings > Cellular > Add eSIM.';
      default:
        return 'eSIM install is not available on this device.';
    }
  }
}

/// Bridge to the native platform eSIM stack.
///
/// On Android this calls the system LPA through `EuiccManager` -- we do not
/// implement SGP.22 ourselves. On iOS the platform refuses third-party installs,
/// so we report unsupported and the UI falls back to the QR code.
class ESimInstaller {
  static const _ch = MethodChannel('com.esimshop.esim/eui');

  /// Cached capability so the activate screen does not re-query on every build.
  static ESimCapability? _cached;

  static Future<ESimCapability> capability({bool refresh = false}) async {
    if (!refresh && _cached != null) return _cached!;

    if (!Platform.isAndroid) {
      _cached = const ESimCapability.unsupported('ios');
      return _cached!;
    }
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('getCapability');
      _cached = ESimCapability(
        supported: r?['supported'] == true,
        reason: r?['reason'] as String?,
        apiLevel: r?['apiLevel'] as int?,
      );
    } on PlatformException catch (e) {
      _cached = ESimCapability.unsupported(e.code);
    } on MissingPluginException {
      // Running on a build that predates the native channel.
      _cached = const ESimCapability.unsupported('no_channel');
    }
    return _cached!;
  }

  /// True when this device can install an eSIM by itself.
  static Future<bool> get isSupported async => (await capability()).supported;

  /// Download the profile identified by [activationCode] onto this device.
  ///
  /// [activationCode] is the standard `LPA:1$<smdp>$<matchingId>` string the
  /// store already issues. Returns a typed result; never throws for expected
  /// failure modes so the UI can show a sensible message.
  static Future<ESimOutcome> install(String activationCode) async {
    final code = activationCode.trim();
    if (code.isEmpty) {
      return const ESimOutcome(ESimResult.badCode, 'No activation code.');
    }

    final cap = await capability();
    if (!cap.supported) {
      return ESimOutcome(ESimResult.unsupported, cap.message);
    }

    final requestId =
        '${DateTime.now().millisecondsSinceEpoch}-${code.hashCode.abs()}';
    try {
      await _ch.invokeMethod('download', {
        'activationCode': code,
        'requestId': requestId,
      });
      return const ESimOutcome(
        ESimResult.ok,
        'eSIM installed. Turn it on under Settings > Cellular.',
      );
    } on PlatformException catch (e) {
      debugPrint('eSIM install failed: ${e.code} ${e.message}');
      switch (e.code) {
        case 'BAD_CODE':
          return ESimOutcome(
            ESimResult.badCode,
            e.message ?? 'This activation code is not valid.',
          );
        case 'NOT_SUPPORTED':
        case 'NO_EUICC':
          return ESimOutcome(ESimResult.unsupported, cap.message);
        case 'RESOLUTION_REQUIRED':
          // The system showed (or wants to show) its own confirmation dialog.
          // Not a failure from the customer's point of view.
          return const ESimOutcome(
            ESimResult.ok,
            'Confirm the eSIM installation in the system dialog.',
          );
        case 'ALREADY_IN_PROGRESS':
          return const ESimOutcome(
            ESimResult.cancelled,
            'An installation is already running. Please wait.',
          );
        default:
          return ESimOutcome(
            ESimResult.failed,
            e.message ?? 'Installation failed. Try the QR code instead.',
          );
      }
    } on MissingPluginException {
      return ESimOutcome(ESimResult.unsupported, cap.message);
    }
  }
}

/// Typed result of an install attempt.
class ESimOutcome {
  final ESimResult result;
  final String message;

  const ESimOutcome(this.result, this.message);

  bool get isOk => result == ESimResult.ok;
}

/// Recognises a GSMA activation code in scanned QR / pasted text.
///
/// Customers scan the wrong thing constantly (shipping barcode, order id), so
/// this is used to tell "you scanned the wrong code" from "we can't install".
class ActivationCode {
  /// Extracts a usable code from raw scanner output, or null.
  static String? parse(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final upper = s.toUpperCase();

    // Standard: LPA:1$smdp$matchingId[:extra]
    if (upper.startsWith('LPA:1')) {
      final parts = s.split(r'$');
      if (parts.length >= 3 && parts[1].isNotEmpty && parts[2].isNotEmpty) {
        return s;
      }
      return null;
    }
    // Bare matching id (carrier default server flows).
    if (s.length >= 8 && !s.contains('://') && !RegExp(r'^\d+$').hasMatch(s)) {
      return s;
    }
    return null;
  }

  /// True when the string looks like an activation code (for UI hints).
  static bool looksValid(String raw) => parse(raw) != null;
}
