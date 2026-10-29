/// Dart side of the vendor LPA stack (`droidlib-v1.2.0.aar`).
///
/// This is the *vendor* path: `EuiccBleDevice` + `LPAdClient` in Java, exposed
/// through `MethodChannel('com.esimshop.esim/lpad')`. esim_ble remains the
/// reverse-engineered path and is still what the UI uses today; this file
/// exists so a screen can opt into the certified stack without touching the
/// Dart protocol code.
///
/// Threading: every call here is expensive (BLE + card I/O, a download runs for
/// minutes). The native side runs them on a worker thread and refuses a second
/// concurrent call with `BUSY` rather than queueing it -- two overlapping
/// sessions on one GATT link would interleave frames.
///
/// Compared with [esim_ble]'s `Lpa`, this exposes what the vendor SDK has and
/// the Dart port does not yet:
///
///   * getMetadata  -- carrier name before downloading (the "is this right?"
///                     step in the vendor demo)
///   * SM-DP+ / SM-DS address get/set
///   * vendor device info (imei / sn / vendor / bleMac)
library;

import 'package:flutter/services.dart';

import 'lpad_errors.dart';

/// Failure carrying the native error code, so callers branch on a stable
/// string instead of matching message text.
///
/// Codes currently emitted by the native bridge:
///
///   NOT_SUPPORTED      no Bluetooth adapter / BLE unsupported
///   NOT_ENABLED        Bluetooth off
///   INVALID_PARAM      empty address or missing argument
///   OPEN_FAILED        GATT connect failed (device off, out of range, paired
///                      to someone else)
///   NO_IMEI            connected but not an eSIM card
///   CLIENT_FAILED      `LPAdClient.createLPAdClient` threw
///   PASSWORD_REQUIRED  no password given and none stored for this card
///   NOT_CONNECTED      an operation was issued before connect()
///   CARD_ERROR         the card rejected a request
///   DOWNLOAD_FAILED    download refused or aborted
///   NEED_CONFIRMATION_CODE  operator requires a confirmation code
///   BUSY               another operation is still running
///   INTERNAL           unexpected native exception
class LpadError implements Exception {
  final String code;
  final String message;
  final Map<dynamic, dynamic>? extras;

  const LpadError(this.code, this.message, [this.extras]);

  bool get isBusy => code == 'BUSY';
  bool get needsConfirmationCode => code == 'NEED_CONFIRMATION_CODE';

  /// True when retrying after asking the user something would help.
  bool get isRetryable =>
      code == 'BUSY' || code == 'OPEN_FAILED' || code == 'INTERNAL';

  /// The packed platform detailed code, when the failure came from the card
  /// stack (download / metadata). Null for transport-level errors.
  ///
  /// Decode it with [messages]; do not match on [message], which is a short
  /// technical string intended for logs.
  int? get detailedCode {
    final v = extras?['detailedCode'];
    return v is num ? v.toInt() : null;
  }

  /// User-facing text for this failure, following the vendor demo's rules.
  ///
  /// [carrierName] improves the message when known (the metadata step usually
  /// supplies it before a download is attempted).
  ErrorMessages messages({String? carrierName}) {
    final d = detailedCode;
    if (d != null) {
      return DetailedErrorMessages(carrierName: carrierName).forCode(d);
    }
    return ErrorMessages(
      title: _transportTitle(code),
      bodyText: message,
      technical: '$code: $message',
    );
  }

  static String _transportTitle(String code) {
    switch (code) {
      case 'NOT_ENABLED':
        return '蓝牙未开启';
      case 'PASSWORD_REQUIRED':
        return '需要卡密码';
      case 'OPEN_FAILED':
        return '连不上读卡器';
      case 'NO_IMEI':
        return '设备不是 eSIM 卡';
      case 'NOT_CONNECTED':
        return '读卡器已断开';
      case 'BUSY':
        return '上一个操作还在进行';
      case 'CLIENT_FAILED':
        return '协议栈初始化失败';
      case 'NEED_CONFIRMATION_CODE':
        return '需要确认码';
      case 'DOWNLOAD_FAILED':
        return '下载失败';
      case 'CANCELLED':
        return '已取消';
      default:
        return '操作失败';
    }
  }

  @override
  String toString() => '$code: $message';
}

/// One profile on the card.
class LpadProfile {
  final String iccid;
  final String nickname;
  final String profileName;

  /// UE-side label from `EuiccProfileInfo.mServiceProviderName` (API 3.3.2).
  final String serviceProvider;

  /// Card-reported state: 1 = enabled, 0 = disabled.
  final int state;

  const LpadProfile({
    required this.iccid,
    this.nickname = '',
    this.profileName = '',
    this.serviceProvider = '',
    this.state = 0,
  });

  bool get isEnabled => state == 1;

  factory LpadProfile.fromMap(Map<dynamic, dynamic> m) => LpadProfile(
        iccid: (m['iccid'] ?? '').toString(),
        nickname: (m['nickname'] ?? '').toString(),
        profileName: (m['profileName'] ?? '').toString(),
        serviceProvider: (m['serviceProvider'] ?? '').toString(),
        state: (m['state'] as num?)?.toInt() ?? 0,
      );

  @override
  String toString() => 'LpadProfile($iccid, enabled=$isEnabled)';
}

/// Result of a completed download.
class LpadDownloadResult {
  final String iccid;
  final int resultCode;

  const LpadDownloadResult({required this.iccid, required this.resultCode});

  bool get hasIccid => iccid.isNotEmpty;
}

class LpadBle {
  static const MethodChannel _ch = MethodChannel('com.esimshop.esim/lpad');

  /// Whether the native channel is wired up. False on platforms without the
  /// bridge (iOS, desktop) or if registration failed at engine startup.
  static Future<bool> available() async {
    try {
      final state = await _ch.invokeMethod<Map<dynamic, dynamic>>('state');
      return state != null;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Whether a card is currently connected and the gRPC channel is up.
  static Future<Map<String, dynamic>> state() async {
    final m = await _ch.invokeMethod<Map<dynamic, dynamic>>('state');
    return {
      'connected': m?['connected'] == true,
      'device': m?['device']?.toString(),
    };
  }

  /// Connect, authenticate and build the LPAdClient.
  ///
  /// [password] is the card's own PSK and is required. Passing null only works
  /// if this card connected successfully before (the value is then remembered
  /// in Keystore-backed storage); otherwise the native side answers
  /// `PASSWORD_REQUIRED` rather than guessing the firmware default.
  static Future<Map<String, dynamic>> connect(String mac, {String? password}) async {
    final r = await _call('connect', {'mac': mac, 'password': password});
    return Map<String, dynamic>.from(r as Map);
  }

  /// Whether a password is already remembered for [mac], so the UI knows
  /// whether it can skip asking.
  static Future<bool> hasRememberedPassword(String mac) async {
    try {
      await _call('probePassword', {'mac': mac});
      return true;
    } on LpadError catch (e) {
      if (e.code == 'PASSWORD_REQUIRED') return false;
      rethrow;
    }
  }

  static Future<void> disconnect() async {
    await _call('disconnect', {});
  }

  /// The PSK remembered for [mac], or null when nothing is stored.
  ///
  /// Needed because [connect] cannot be handed an empty string to mean "use
  /// the saved one": the native side treats empty as missing and answers
  /// `PASSWORD_REQUIRED`, which is what produced the repeated password dialog.
  static Future<String?> rememberedPassword(String mac) async =>
      await _call('rememberedPassword', {'mac': mac}) as String?;

  /// Discard the stored PSK so the next connect asks the user again.
  static Future<void> forgetPassword(String mac) async {
    await _call('forgetPassword', {'mac': mac});
  }

  /// Vendor/device identity, as reported by the card's own firmware.
  static Future<Map<String, dynamic>> deviceInfo() async {
    final r = await _call('deviceInfo', {});
    return Map<String, dynamic>.from(r as Map);
  }

  static Future<String?> eid() async => await _call('getEid', {}) as String?;

  /// ES10b GetEuiccInfo2, read-only card capability info.
  ///
  /// Returns ordered `{label, value}` pairs. Empty when the card declined or
  /// the payload did not parse -- the caller renders an empty state rather than
  /// inventing values.
  static Future<List<Map<String, String>>> euiccInfo() async {
    final raw = await _call('getEuiccInfo', {}) as List?;
    return (raw ?? const [])
        .map((e) => {
              'label': (e['label'] ?? '').toString(),
              'value': (e['value'] ?? '').toString(),
            })
        .toList(growable: false);
  }

  static Future<List<LpadProfile>> listProfiles() async {
    final raw = await _call('listProfiles', {}) as List?;
    return (raw ?? const [])
        .map((e) => LpadProfile.fromMap(e as Map))
        .toList(growable: false);
  }

  /// Ask the operator about an activation code without downloading anything.
  ///
  /// Returns `{ok, resultCode, carrierName}`. This is the vendor demo's
  /// confirmation step: show the carrier name, let the user accept, then
  /// call [download].
  static Future<Map<String, dynamic>> metadata(String activationCode) async {
    final r = await _call('getMetadata', {'activationCode': activationCode});
    return Map<String, dynamic>.from(r as Map);
  }

  /// Write a profile. Blocking on the native side for the whole download.
  ///
  /// [switchAfter] enables the profile as soon as it lands, matching the
  /// vendor demo's `switchAfterDownload = true`.
  static Future<LpadDownloadResult> download(
    String activationCode, {
    String? confirmationCode,
    bool switchAfter = true,
  }) async {
    final r = await _call('download', {
      'activationCode': activationCode,
      'confirmationCode': confirmationCode,
      'switchAfter': switchAfter,
    }) as Map;
    return LpadDownloadResult(
      iccid: (r['iccid'] ?? '').toString(),
      resultCode: (r['resultCode'] as num?)?.toInt() ?? 0,
    );
  }

  static Future<int> enable(String iccid) async =>
      (await _call('enable', {'iccid': iccid}) as num).toInt();

  static Future<int> disable(String iccid) async =>
      (await _call('disable', {'iccid': iccid}) as num).toInt();

  static Future<int> delete(String iccid) async =>
      (await _call('delete', {'iccid': iccid}) as num).toInt();

  static Future<int> setNickname(String iccid, String nickname) async =>
      (await _call('setNickname', {'iccid': iccid, 'nickname': nickname}) as num).toInt();

  static Future<String?> smdpAddress() async =>
      await _call('getSmdpAddress', {}) as String?;

  static Future<int> setSmdpAddress(String address) async =>
      (await _call('setSmdpAddress', {'address': address}) as num).toInt();

  static Future<String?> smdsAddress() async => await _call('getSmdsAddress', {}) as String?;

  /// SM-DS discovery list (API 3.3.9).
  ///
  /// Returns `{ok, resultCode, subscriptions: [{activationCode,
  /// confirmationCode, carrierName}]}`. Each entry already carries its own
  /// activation code, so the UI can go straight to [download].
  static Future<Map<String, dynamic>> dsList() async {
    final r = await _call('getDsList', {}) as Map;
    return Map<String, dynamic>.from(r);
  }

  /// Re-query the card and re-register on the network (API 3.2.2).
  /// Call after download / enable / disable, as the vendor demo does.
  static Future<void> resetDevice() async {
    await _call('resetDevice', {});
  }

  /// Drop and rebuild the GATT link (API 3.2.4).
  static Future<bool> reopen() async => (await _call('reopen', {})) == true;

  /// Override the GATT identifiers (API 3.2.6).
  ///
  /// Only takes effect if called **before** [connect]; the SDK applies the value
  /// while building the device object.
  static Future<void> setServiceUuids({
    required String service,
    required String rx,
    required String tx,
  }) async {
    await _call('setServiceUuids', {'service': service, 'rx': rx, 'tx': tx});
  }

  static Future<dynamic> _call(String method, Map<String, dynamic> args) async {
    try {
      return await _ch.invokeMethod<dynamic>(method, args);
    } on PlatformException catch (e) {
      throw LpadError(
        e.code,
        e.message ?? 'native error',
        e.details is Map ? e.details as Map : null,
      );
    } on MissingPluginException {
      throw const LpadError(
        'NOT_SUPPORTED',
        'The vendor LPA bridge is not available on this build/platform.',
      );
    }
  }
}
