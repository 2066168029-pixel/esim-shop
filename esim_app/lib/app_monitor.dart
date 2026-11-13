// App 监控心跳：启动时上报一次，之后每 60 秒一次。
//
// 供运营后台的「数据大屏」实时展示 App 在线数、平台分布、版本分布、
// 全球设备分布等。后端接口：
//   POST /api/v1/app/heartbeat   （无需登录）
//
// 只上报匿名设备信息，不包含任何账号、订单或用户身份数据。

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

class AppMonitor {
  AppMonitor._();

  static final AppMonitor instance = AppMonitor._();

  static const _kDeviceId = 'monitor_device_id';
  static const _interval = Duration(seconds: 60);

  Timer? _timer;
  String? _deviceId;
  String _platform = 'unknown';
  String _osVersion = '';
  String _model = '';
  String _appVersion = '';
  String _buildNo = '';

  /// 当前页面路径（由导航处更新，便于后台看活跃位置）
  String currentPath = '/';

  bool _started = false;

  /// 启动心跳。可重复调用，只会真正启动一次。
  Future<void> start() async {
    if (_started) return;
    _started = true;

    await _collectDeviceInfo();
    await _send();

    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => _send());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _started = false;
  }

  /// 页面切换时调用，下一次心跳会带上新路径。
  void updatePath(String path) {
    currentPath = path;
  }

  /// 生成/读取稳定的设备 ID。
  Future<String> _ensureDeviceId() async {
    if (_deviceId != null) return _deviceId!;

    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_kDeviceId);
    if (id == null || id.isEmpty) {
      id = _randomUuid();
      await prefs.setString(_kDeviceId, id);
    }
    _deviceId = id;
    return id;
  }

  static String _randomUuid() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    // RFC4122 v4
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    final s = bytes.map(hex).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-'
        '${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }

  Future<void> _collectDeviceInfo() async {
    try {
      final pkg = await PackageInfo.fromPlatform();
      _appVersion = pkg.version;
      _buildNo = pkg.buildNumber;
    } catch (_) {
      // 拿不到版本号不阻塞上报
    }

    try {
      final di = DeviceInfoPlugin();

      if (Platform.isIOS) {
        _platform = 'ios';
        final ios = await di.iosInfo;
        _osVersion = ios.systemVersion;
        // utsname.machine 是 "iPhone15,2" 这类内部代号，
        // name 才是 "iPhone 15 Pro" 这种人读名称
        _model = ios.utsname.machine;
      } else if (Platform.isAndroid) {
        _platform = 'android';
        final and = await di.androidInfo;
        _osVersion = 'Android ${and.version.release}';
        _model = '${and.manufacturer} ${and.model}';
      } else {
        _platform = Platform.operatingSystem;
      }
    } catch (_) {
      // 设备信息获取失败时，至少保证 platform 可用
      try {
        _platform = Platform.operatingSystem;
      } catch (_) {
        _platform = 'unknown';
      }
    }
  }

  Future<void> _send() async {
    try {
      final id = await _ensureDeviceId();
      final uri = Uri.parse('${ApiConfig.baseUrl}/api/v1/app/heartbeat');

      final payload = jsonEncode({
        'device_id': id,
        'platform': _platform,
        'app_version': _appVersion,
        'build_no': _buildNo,
        'os_version': _osVersion,
        'model': _model,
        'path': currentPath,
      });

      await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json; charset=utf-8'},
            body: payload,
          )
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      // 心跳失败静默处理，绝不打扰用户
    }
  }
}
