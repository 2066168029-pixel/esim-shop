/// Native LPA bridge (iOS only).
///
/// On iOS the Linksfield `eSIMManagerSDK` xcframework does the LPA work in
/// Objective-C/Swift. This wrapper exposes it to Dart over a MethodChannel.
///
/// Why this exists: `esim_ble` re-implements the vendor BLE protocol in pure
/// Dart. That works on Android, but on iOS the vendor ships a maintained binary
/// SDK that already speaks the protocol (including the v1.4+ encrypted BLE
/// channel) and gets updated by them. Preferring it on iOS removes a whole class
/// of "our guess drifted from the firmware" bugs.
///
/// Availability
/// ------------
/// The vendored xcframework only has an arm64 *device* slice, so:
///   * physical iPhone  -> available
///   * iOS simulator    -> NOT available (bridge compiled out)
///   * Android/desktop  -> NOT available
/// Always check [NativeLpa.isAvailable] before use and fall back to
/// `esim_ble`'s Dart implementation.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Connection state, mirroring `DeviceConnectionState` in the SDK.
enum NativeLpaConnectionState { disconnected, connecting, connected, connectFail }

/// A discovered BLE card.
class NativeLpaDevice {
  final String id;
  final String name;
  final int rssi;
  final String mac;

  const NativeLpaDevice({
    required this.id,
    required this.name,
    required this.rssi,
    required this.mac,
  });

  @override
  String toString() => 'NativeLpaDevice($name, $id, rssi=$rssi)';
}

/// An eSIM profile as reported by the card.
class NativeLpaProfile {
  final String iccid;
  final String nickname;
  final String serviceProviderName;
  final String profileName;
  final int state;
  final int policyRules;

  const NativeLpaProfile({
    required this.iccid,
    required this.nickname,
    required this.serviceProviderName,
    required this.profileName,
    required this.state,
    required this.policyRules,
  });

  bool get isEnabled => state == 1;

  factory NativeLpaProfile.fromMap(Map<dynamic, dynamic> m) => NativeLpaProfile(
        iccid: m['iccid'] as String? ?? '',
        nickname: m['nickname'] as String? ?? '',
        serviceProviderName: m['serviceProviderName'] as String? ?? '',
        profileName: m['profileName'] as String? ?? '',
        state: (m['state'] as num?)?.toInt() ?? 0,
        policyRules: (m['policyRules'] as num?)?.toInt() ?? 0,
      );
}

class NativeLpaException implements Exception {
  final String code;
  final String? message;
  NativeLpaException(this.code, [this.message]);
  @override
  String toString() => 'NativeLpaException($code${message == null ? '' : ': $message'})';
}

/// Result of an LPA operation. [result] is the raw vendor code; 0 means OK.
class NativeLpaResult {
  final int result;
  final bool needConfirm;

  const NativeLpaResult(this.result, {this.needConfirm = false});

  bool get ok => result == 0;
}

/// Thin wrapper around the native channel.
class NativeLpa {
  static const _method = MethodChannel('app.esim/native_lpa');
  static const _events = EventChannel('app.esim/native_lpa/events');

  static bool? _available;

  /// True when the native SDK bridge is present and usable.
  ///
  /// On iOS this is true only for device builds: the vendored xcframework has
  /// no simulator slice, so the bridge is compiled out of simulator binaries.
  static Future<bool> get isAvailable async {
    if (_available != null) return _available!;
    if (!Platform.isIOS) {
      _available = false;
      return false;
    }
    try {
      // A cheap round-trip; throws MissingPluginException if the bridge is
      // absent (simulator / bridge not compiled in).
      await _method.invokeMethod<void>('stopScan');
      _available = true;
    } on MissingPluginException {
      _available = false;
    } on PlatformException {
      // Channel exists but something went wrong; treat as available.
      _available = true;
    }
    return _available!;
  }

  /// Raw event stream: scan hits, connection changes, device notifications.
  static Stream<Map<String, dynamic>> get rawEvents => _events
      .receiveBroadcastStream()
      .map((e) => Map<String, dynamic>.from(e as Map));

  /// Discovered cards.
  static Stream<NativeLpaDevice> scan({
    Duration timeout = const Duration(seconds: 15),
  }) {
    final controller = StreamController<NativeLpaDevice>();
    StreamSubscription? sub;
    Timer? timer;

    controller.onListen = () async {
      sub = rawEvents.listen((e) {
        if (e['type'] != 'scan') return;
        controller.add(NativeLpaDevice(
          id: e['id'] as String? ?? '',
          name: e['name'] as String? ?? '',
          rssi: (e['rssi'] as num?)?.toInt() ?? 0,
          mac: e['mac'] as String? ?? '',
        ));
      });
      await _method.invokeMethod<void>('startScan');
      timer = Timer(timeout, () {
        _method.invokeMethod<void>('stopScan').catchError((_) {});
        if (!controller.isClosed) controller.close();
      });
    };

    controller.onCancel = () async {
      timer?.cancel();
      await sub?.cancel();
      try {
        await _method.invokeMethod<void>('stopScan');
      } catch (_) {}
    };

    return controller.stream;
  }

  /// Connection state changes.
  static Stream<NativeLpaConnectionState> get connectionStates =>
      rawEvents.where((e) => e['type'] == 'connect').map((e) {
        final v = (e['state'] as num?)?.toInt() ?? 0;
        return NativeLpaConnectionState.values[
            v.clamp(0, NativeLpaConnectionState.values.length - 1)];
      });

  /// `notifyDevice` callbacks: download/enable/disable progress from the card.
  static Stream<Map<String, dynamic>> get deviceNotifications =>
      rawEvents.where((e) => e['type'] == 'notify');

  /// Pass `false` to silence the vendor SDK's own logging.
  static Future<void> setLogEnabled(bool enabled) async {
    // Exposed for completeness; the bridge currently hardcodes it off.
  }

  static Future<void> stopScan() => _method.invokeMethod<void>('stopScan');

  /// Connects and creates the LPAd client. Returns true when the card is ready
  /// for LPA operations.
  static Future<bool> connect(String deviceId) async {
    final r = await _method.invokeMethod<Map>('connect', {'deviceId': deviceId});
    return r?['connected'] as bool? ?? false;
  }

  /// 原生层的诊断日志（EventChannel 里 type == 'log'）。
  ///
  /// App 内直接可见，不需要连 Mac 看 Xcode 控制台。
  static Stream<String> get logs => rawEvents
      .where((e) => e['type'] == 'log')
      .map((e) => (e['message'] as String?) ?? '');

  /// 切换加密/明文建链模式。默认加密（覆盖面更广）。
  static Future<void> setSecureMode(bool secure) async {
    await _method.invokeMethod<void>('setSecureMode', {'secure': secure});
  }

  /// 存入卡密码（PSK）。加密卡首次连接必须提供，之后会自动复用。
  /// 传空串表示清除。
  static Future<void> setCardPassword(String password) async {
    await _method.invokeMethod<void>('setCardPassword', {'password': password});
  }

  /// 是否已经存过卡密码。
  static Future<bool> get hasCardPassword async {
    try {
      final r = await _method.invokeMethod<Map>('hasCardPassword');
      return (r?['has'] as bool?) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> disconnect() => _method.invokeMethod<void>('disconnect');

  static Future<String?> getEid() async {
    final r = await _method.invokeMethod<Map>('getEid');
    return r?['eid'] as String?;
  }

  static Future<String?> getEuiccInfo() async {
    final r = await _method.invokeMethod<Map>('getEuiccInfo');
    return r?['info'] as String?;
  }

  /// All profiles on the card, plus the EID.
  static Future<({int result, String? eid, List<NativeLpaProfile> profiles})>
      getProfiles() async {
    final r = await _method.invokeMethod<Map>('getProfiles');
    final list = (r?['profiles'] as List?) ?? const [];
    return (
      result: (r?['result'] as num?)?.toInt() ?? -1,
      eid: r?['eid'] as String?,
      profiles: list
          .map((e) => NativeLpaProfile.fromMap(e as Map))
          .toList(growable: false),
    );
  }

  /// Installs a profile. If [needConfirm] comes back true, prompt the user for
  /// the code and call again with [confirmationCode].
  static Future<NativeLpaResult> download(
    String activationCode, {
    String confirmationCode = '',
  }) async {
    final r = await _method.invokeMethod<Map>('download', {
      'activationCode': activationCode,
      'confirmationCode': confirmationCode,
    });
    return NativeLpaResult(
      (r?['result'] as num?)?.toInt() ?? -1,
      needConfirm: r?['needConfirm'] as bool? ?? false,
    );
  }

  static Future<({int result, String? metadata})> getMetadata(
      String activationCode) async {
    final r = await _method.invokeMethod<Map>(
        'getMetadata', {'activationCode': activationCode});
    return (
      result: (r?['result'] as num?)?.toInt() ?? -1,
      metadata: r?['metadata'] as String?,
    );
  }

  static Future<NativeLpaResult> enable(String iccid) async {
    final r = await _method.invokeMethod<Map>('enable', {'iccid': iccid});
    return NativeLpaResult((r?['result'] as num?)?.toInt() ?? -1);
  }

  static Future<NativeLpaResult> disable(String iccid) async {
    final r = await _method.invokeMethod<Map>('disable', {'iccid': iccid});
    return NativeLpaResult((r?['result'] as num?)?.toInt() ?? -1);
  }

  static Future<NativeLpaResult> delete(String iccid) async {
    final r = await _method.invokeMethod<Map>('delete', {'iccid': iccid});
    return NativeLpaResult((r?['result'] as num?)?.toInt() ?? -1);
  }

  static Future<NativeLpaResult> eraseAll() async {
    final r = await _method.invokeMethod<Map>('eraseAll');
    return NativeLpaResult((r?['result'] as num?)?.toInt() ?? -1);
  }

  static Future<NativeLpaResult> setNickname(String iccid, String nickname) async {
    final r = await _method.invokeMethod<Map>(
        'setNickname', {'iccid': iccid, 'nickname': nickname});
    return NativeLpaResult((r?['result'] as num?)?.toInt() ?? -1);
  }

  static Future<String?> getDefaultSmdp() async {
    final r = await _method.invokeMethod<Map>('getDefaultSmdp');
    return r?['address'] as String?;
  }

  static Future<NativeLpaResult> setDefaultSmdp(String address) async {
    final r = await _method.invokeMethod<Map>('setDefaultSmdp', {'address': address});
    return NativeLpaResult((r?['result'] as num?)?.toInt() ?? -1);
  }
}
