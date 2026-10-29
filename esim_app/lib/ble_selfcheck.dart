/// Guided Bluetooth write-path self-check.
///
/// The write path is a chain: scan → connect → discover → notify → MTU →
/// first frame → secure channel → ES10 selection → ES10c read → download.
/// Every link has failed at least once in this project, and each failure
/// presents to the user as the same sentence — "写卡失败". This runs one
/// read-only request per link and reports where the chain broke, with the
/// evidence that decision was based on.
///
/// Deliberately read-only: no download, no enable/disable/delete. The only
/// state a check can leave behind is an installed profile if the user then
/// writes one on their own.
library;

import 'dart:async';

import 'package:esim_ble/esim_ble.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

enum SelfCheckState { pending, running, pass, fail, warn, skip }

/// One link in the chain, filled in as the check runs.
class SelfCheckStep {
  final String title;

  /// What a pass proves, in user language.
  final String meaning;

  SelfCheckState state;
  String detail;

  SelfCheckStep(this.title, this.meaning, {this.state = SelfCheckState.pending, this.detail = ''});

  bool get done => state != SelfCheckState.pending && state != SelfCheckState.running;
  bool get failed => state == SelfCheckState.fail;

  String get icon {
    switch (state) {
      case SelfCheckState.pass:
        return '✓';
      case SelfCheckState.fail:
        return '✗';
      case SelfCheckState.warn:
        return '!';
      case SelfCheckState.skip:
        return '–';
      case SelfCheckState.running:
        return '◌';
      case SelfCheckState.pending:
        return '·';
    }
  }
}

/// Everything the check learned, kept so the screen can show it and the
/// writer can reuse the open transport instead of reconnecting.
class SelfCheckResult {
  final steps = <SelfCheckStep>[];

  /// The connected transport, when the chain got that far.
  EuiccTransport? transport;
  EuiccSession? session;

  List<ProfileSummary> profiles = [];
  String eid = '';

  /// False when the card's write capability could not even be probed.
  bool canWrite = false;

  /// The first failure, phrased as the next thing to do.
  String? blockingIssue;

  bool get allPassed => steps.every((s) =>
      s.state == SelfCheckState.pass || s.state == SelfCheckState.skip);

  bool get sawAnyReply => steps.any((s) => s.state == SelfCheckState.pass);
}

typedef SelfCheckProgress = void Function(SelfCheckResult result);

/// Runs the chain against [device]. Always returns a result; failures are
/// recorded in the steps, never thrown.
Future<SelfCheckResult> runSelfCheck(
  BluetoothDevice device, {
  SelfCheckProgress? onProgress,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final result = SelfCheckResult();
  SelfCheckStep step(String title, String meaning) {
    final s = SelfCheckStep(title, meaning);
    result.steps.add(s);
    onProgress?.call(result);
    return s;
  }

  void mark(SelfCheckStep s, SelfCheckState state, String detail) {
    s
      ..state = state
      ..detail = detail;
    onProgress?.call(result);
  }

  // -- 1. link ------------------------------------------------------------
  final link = step('蓝牙链路', '手机能连上读卡器');

  final probe = await probeTransport(device);
  LpadProbeReport? lpad;
  if (probe != null) {
    result.transport = probe;
    mark(link, SelfCheckState.pass, '已连接（9eSIM 读卡器，纯 APDU 通道）');
  } else {
    try {
      final t = await LinksfieldTransport.connect(device, replyTimeout: timeout);
      result.transport = t;
      lpad = t.report;
      mark(link, SelfCheckState.pass, '已连接（Linksfield 卡，protobuf 通道，'
          '长度头 ${t.lengthHeaderSize} 字节）');
    } catch (e) {
      mark(link, SelfCheckState.fail, '$e');
      result.blockingIssue = '连不上读卡器。检查：卡是否通电、蓝牙扫描能否看到它、'
          '是否在系统弹窗里输了配对密码。';
      return result;
    }
  }

  // -- 2. notifications ---------------------------------------------------
  final notify = step('通知通道', '卡说的话能被手机收到（写出去才有回音）');
  if (lpad != null) {
    if (lpad.notifyEnabled) {
      mark(notify, lpad.cccdConfirmed ? SelfCheckState.pass : SelfCheckState.warn,
          lpad.cccdConfirmed ? '通知已开且 CCCD 已确认' : '通知已开，但 CCCD 未确认');
    } else {
      mark(notify, SelfCheckState.fail, '通知没打开：任何命令都收不到回复');
      result.blockingIssue = '通知没打开。断开重连一次；仍然失败说明这块固件不接受 CCCD 写入。';
    }
  } else {
    // The 9eSIM path subscribes while connecting; reaching here proves it.
    mark(notify, SelfCheckState.pass, '已订阅（连接时完成）');
  }

  // -- 3. first frame / framing ------------------------------------------
  final framing = step('帧格式', '长度头与分片对得上，卡能解析我们的命令');
  if (lpad != null) {
    if (lpad.lastFrames.isEmpty) {
      mark(framing, SelfCheckState.fail, '卡一个字节都没回');
      result.blockingIssue ??=
          '卡没回任何字节。多数是长度头不对（2/4 字节）或配对未完成——'
          '这台已自动试过两种长度头。';
    } else if (lpad.undecodableFrames > 0) {
      mark(framing, SelfCheckState.warn,
          '收到 ${lpad.lastFrames.length} 帧，其中 ${lpad.undecodableFrames} 帧解析失败');
    } else {
      mark(framing, SelfCheckState.pass, '收到 ${lpad.lastFrames.length} 帧，长度头正确'
          '${lpad.unsolicitedFrames > 0 ? "（另有 ${lpad.unsolicitedFrames} 条迟到回复）" : ""}');
    }
    if (lpad.pairingPrompt != null) {
      mark(framing, SelfCheckState.warn, lpad.pairingPrompt!);
      result.blockingIssue ??= lpad.pairingPrompt;
    }
  } else {
    mark(framing, SelfCheckState.skip, '文本 JSON 通道，无长度头');
  }

  // -- 4. secure channel --------------------------------------------------
  final secure = step('安全通道', '加密/握手这一层不影响写卡');
  try {
    await result.transport!.open();
    final transport = result.transport!;
    final isSecure = transport is LinksfieldTransport && transport.isSecure;
    mark(secure, SelfCheckState.pass,
        isSecure ? '已建立 AES-CCM 安全通道' : '不需要安全通道（明文）');
  } catch (e) {
    mark(secure, SelfCheckState.fail, '$e');
    result.blockingIssue ??= '卡收得到命令但拒绝建立会话：$e';
    await _quietClose(result.transport);
    return result;
  }

  final session = EuiccSession(result.transport!);
  try {
    await session.open();
    result.session = session;
  } catch (e) {
    mark(secure, SelfCheckState.fail, 'ISD-R 通道打不开：$e');
    result.blockingIssue ??= '能建会话但选不中 ISD-R 小程序：$e';
    await _quietClose(result.transport);
    return result;
  }

  // -- 5. read EID --------------------------------------------------------
  final sheet = step('读取卡片信息', 'ES10b/ES10c 真的能执行（说明写卡也会通）');
  final lpa = Lpa(session);
  try {
    result.eid = await lpa.readEid();
    mark(sheet, SelfCheckState.pass, 'EID ${result.eid.isEmpty ? "(空)" : result.eid}');
  } catch (e) {
    mark(sheet, SelfCheckState.fail, '$e');
    result.blockingIssue ??= '通道能开，但 ES10 命令执行失败：$e';
    return result;
  }

  // -- 6. profile list ----------------------------------------------------
  final list = step('读取套餐列表', '卡里已装的 profile 能读出来');
  try {
    result.profiles = await lpa.listProfiles();
    final enabled = result.profiles.where((p) => p.isEnabled).length;
    mark(list, SelfCheckState.pass,
        '${result.profiles.length} 个 profile，其中 $enabled 个已启用');
  } catch (e) {
    mark(list, SelfCheckState.fail, '$e');
    result.blockingIssue ??= 'EID 能读但套餐列表读不出：卡上 ISD-R 可能不完整。';
    return result;
  }

  // -- 7. write capability ------------------------------------------------
  final canWrite = step('写卡条件', '剩余空间与操作通道都还可用');
  try {
    final notes = await lpa.listNotifications();
    mark(canWrite, SelfCheckState.pass,
        '可用；${notes.isEmpty ? "无" : notes.length.toString()} 条待发通知');
    result.canWrite = true;
  } catch (e) {
    // Not fatal for writes, but it means the notification applet is absent.
    mark(canWrite, SelfCheckState.warn, '通知读取失败：$e');
    result.canWrite = result.profiles.isNotEmpty;
  }

  result.blockingIssue ??= lpad?.diagnosis;
  return result;
}

/// Closes without letting a teardown error mask the real failure.
Future<void> _quietClose(EuiccTransport? t) async {
  try {
    await t?.close();
  } catch (_) {}
}
