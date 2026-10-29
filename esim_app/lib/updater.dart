import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'theme.dart';

/// Checks the backend for a newer APK and offers to download + install it.
/// Works on Android; on other platforms it no-ops.
class AppUpdater {
  /// Fetch version info from the backend. Returns null on any failure.
  static Future<Map<String, dynamic>?> check() async {
    if (!Platform.isAndroid) return null;
    try {
      final info = await PackageInfo.fromPlatform();
      final build = int.tryParse(info.buildNumber) ?? 0;
      final j = await ApiClient(() => null).get('/api/app/version',
          q: {'client_version': info.version, 'client_build': build});
      return j as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Show the update dialog if an update exists. Safe to call at startup.
  static Future<void> maybePrompt(BuildContext context) async {
    final res = await check();
    if (res == null || res['has_update'] != true) return;
    final latest = (res['latest'] ?? {}) as Map;
    final rawUrl = (latest['url'] ?? '').toString();
    final url = ApiConfig.resolve(rawUrl);
    if (url.isEmpty) return;
    if (!context.mounted) return;
    final force = latest['force'] == true;
    final notes = (latest['notes'] ?? '').toString();
    final ver = latest['version'] ?? '';

    await showDialog(
      context: context,
      barrierDismissible: !force,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(children: const [
          Icon(Icons.system_update_alt_rounded, color: AppColors.primary),
          SizedBox(width: 8),
          Text('发现新版本', style: TextStyle(fontWeight: FontWeight.w800)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('最新版本：$ver', style: const TextStyle(fontWeight: FontWeight.w700)),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(notes, style: const TextStyle(fontSize: 13, height: 1.5, color: AppColors.textSub)),
            ],
          ],
        ),
        actions: [
          if (!force)
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('稍后')),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              downloadAndInstall(context, url);
            },
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
  }

  /// Download the APK then open the system installer.
  static Future<void> downloadAndInstall(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(const SnackBar(content: Text('正在下载更新…'), duration: Duration(seconds: 30)));
    try {
      final dir = await getTemporaryDirectory();
      final savePath = '${dir.path}/onlylink-update.apk';
      await Dio().download(url, savePath, onReceiveProgress: (r, t) {});
      messenger?.hideCurrentSnackBar();
      final res = await OpenFilex.open(savePath, type: 'application/vnd.android.package-archive');
      if (res.type != ResultType.done) {
        messenger?.showSnackBar(SnackBar(content: Text('无法打开安装包：${res.message}'), backgroundColor: AppColors.danger));
      }
    } catch (e) {
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(SnackBar(content: Text('下载失败：$e'), backgroundColor: AppColors.danger));
    }
  }

  /// Record the current build so we only nag once per version (soft updates).
  static Future<void> markPrompted(String version) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('last_update_prompt', version);
  }
}
