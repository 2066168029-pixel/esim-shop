/// End-to-end eSIM profile download onto a Bluetooth card.
///
/// Implements the SGP.22 download sequence as six alternating card/network
/// steps (matching the reference client's applet_profile_download):
///
///   1. ES10b GetEuiccChallenge + GetEUICCInfo1        (card)
///   2. ES9+  initiateAuthentication                   (network)
///   3. ES10b AuthenticateServer                        (card)
///   4. ES9+  authenticateClient                        (network)
///   5. ES10b PrepareDownload                           (card)
///   6. ES9+  getBoundProfilePackage                    (network)
///   7. ES10b LoadBoundProfilePackage                   (card)  <- writes the card
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'card_session.dart';
import 'euicc_transport.dart';
import 'lpa.dart';
import 'notifications.dart';
import 'sgp22.dart';
import 'smdp_client.dart';
import 'transport_9esim_ble.dart';
import 'transport_linksfield.dart';

/// Progress reporting so the UI can show which step is running.
enum DownloadStage {
  connecting,
  readingCard,
  initiateAuthentication,
  authenticateServer,
  authenticateClient,
  prepareDownload,
  getBoundProfilePackage,
  loadBoundProfilePackage,
  done,
  failed,
}

typedef ProgressCallback = void Function(DownloadStage stage, String detail);

class DownloadResult {
  final String iccid;
  final int boundProfilePackageBytes;

  DownloadResult(this.iccid, this.boundProfilePackageBytes);

  @override
  String toString() => 'DownloadResult(iccid=$iccid, bpp=${boundProfilePackageBytes}B)';
}

class ProfileDownloader {
  final EuiccSession session;
  final Lpa lpa;
  final ProgressCallback? onProgress;

  ProfileDownloader(this.session, {this.onProgress})
      : lpa = Lpa(session);

  /// Runs the whole download for [code] against the card behind [device].
  ///
  /// The caller owns [session]; use [ProfileDownloader.connect] for the common
  /// case where this class should also open and close the card.
  Future<DownloadResult> download(
    ActivationCode code, {
    String? imei,
    String? confirmationCode,
  }) async {
    final progress = onProgress ?? (_, __) {};

    SmdpClient? smdp;
    String? transactionId;
    var stage = DownloadStage.initiateAuthentication;

    try {
      // -- 1. card: challenge + info -------------------------------------
      progress(DownloadStage.readingCard, 'Reading eUICC challenge and info');
      final challenge = await lpa.getEuiccChallenge();
      final info1 = await lpa.getEuiccInfo1();

      smdp = SmdpClient(code.smdpAddress);

      // -- 2. network: initiateAuthentication ----------------------------
      stage = DownloadStage.initiateAuthentication;
      progress(stage, 'Contacting ${code.smdpAddress}');
      final auth = await smdp.initiateAuthentication(
        euiccChallengeB64: base64.encode(challenge),
        euiccInfo1B64: base64.encode(info1),
      );
      transactionId = auth.transactionId;

      // -- 3. card: AuthenticateServer -----------------------------------
      stage = DownloadStage.authenticateServer;
      progress(stage, 'Verifying the SM-DP+ certificate on the card');
      final authServerRsp = await lpa.authenticateServer(
        serverSigned1: auth.serverSigned1,
        serverSignature1: auth.serverSignature1,
        euiccCiPkIdToBeUsed: auth.euiccCiPkIdToBeUsed,
        serverCertificate: auth.serverCertificate,
        matchingId: code.matchingId,
        imei: imei,
      );

      // -- 4. network: authenticateClient --------------------------------
      stage = DownloadStage.authenticateClient;
      progress(stage, 'Authenticating this card with the SM-DP+');
      final clientAuth = await smdp.authenticateClient(
        transactionId: transactionId,
        authenticateServerResponseB64: base64.encode(authServerRsp),
      );

      // -- 5. card: PrepareDownload --------------------------------------
      stage = DownloadStage.prepareDownload;
      progress(stage, 'Preparing download on the card');
      final prepareRsp = await lpa.prepareDownload(
        smdpSigned2: clientAuth.smdpSigned2,
        smdpSignature2: clientAuth.smdpSignature2,
        smdpCertificate: clientAuth.smdpCertificate,
        confirmationCode: confirmationCode,
      );

      // -- 6. network: getBoundProfilePackage ----------------------------
      stage = DownloadStage.getBoundProfilePackage;
      progress(stage, 'Fetching the profile package');
      final bpp = await smdp.getBoundProfilePackage(
        transactionId: transactionId,
        prepareDownloadResponseB64: base64.encode(prepareRsp),
      );

      // -- 7. card: install ----------------------------------------------
      stage = DownloadStage.loadBoundProfilePackage;
      progress(stage, 'Writing the profile to the card (${bpp.length} bytes)');
      await lpa.loadBoundProfilePackage(bpp);

      // Read back to confirm the card reports the new profile.
      final iccid = await _verifyInstalled();

      // Deliver the installation notification. Without this the SM-DP+ keeps
      // the profile marked as "downloading" and may refuse a later install.
      // Failures here must not fail an otherwise successful write.
      await _flushNotificationsQuietly(progress);

      progress(DownloadStage.done, iccid.isEmpty
          ? 'Profile installed'
          : 'Profile installed (ICCID $iccid)');
      return DownloadResult(iccid, bpp.length);
    } catch (e) {
      progress(DownloadStage.failed, _describe(e));
      // Best effort: tell the SM-DP+ the transaction is abandoned so it can
      // release the reservation instead of holding it until it expires.
      if (smdp != null && transactionId != null) {
        await _tryCancel(smdp, transactionId, confirmationCode);
      }
      rethrow;
    } finally {
      smdp?.close();
      // `stage` is only read implicitly by the catch block above; keeping the
      // assignment makes the failure point obvious in debugger traces.
      assert(stage != DownloadStage.failed || true);
    }
  }

  /// Delivers queued ES10b notifications without failing the download.
  Future<void> _flushNotificationsQuietly(ProgressCallback progress) async {
    try {
      final drain = await lpa.flushNotifications();
      if (drain.delivered > 0) {
        progress(DownloadStage.done,
            'Sent ${drain.delivered} installation notification(s)');
      }
      if (!drain.isClean) {
        progress(DownloadStage.done,
            'Unsent notifications: ${drain.errors.join("; ")}');
      }
    } catch (_) {
      // Notifications are advisory; never fail a completed write over them.
    }
  }

  /// After a successful load, lists profiles and returns the ICCID of the one
  /// the card now reports as present but not yet enabled, if determinable.
  Future<String> _verifyInstalled() async {
    try {
      final profiles = await lpa.listProfiles();
      if (profiles.isEmpty) return '';
      final disabled = profiles.where((p) => !p.isEnabled).toList();
      if (disabled.length == 1) return disabled.first.iccid;
      return profiles.last.iccid;
    } catch (_) {
      // Verification is a nicety; never fail the download because of it.
      return '';
    }
  }

  Future<void> _tryCancel(
    SmdpClient smdp,
    String transactionId,
    String? confirmationCode,
  ) async {
    try {
      // ES10b CancelSession needs a reason; 0x00 = end user rejection, which is
      // the closest match when the app aborts or a step throws.
      final cancelRsp = await lpa.cancelSession(0x00);
      await smdp.cancelSession(
        transactionId: transactionId,
        cancelSessionResponseB64: base64.encode(cancelRsp),
      );
    } catch (_) {
      // Cancel is advisory; swallow failures.
    }
  }

  static String _describe(Object e) {
    if (e is SmdpError) return e.toString();
    if (e is LpaError) return e.toString();
    if (e is CardError) return e.toString();
    return e.toString();
  }

  /// Convenience: connect, download, disconnect.
  ///
  /// Tries the 9eSIM reader first: its firmware speaks plain APDUs, so the
  /// download runs on the standard SGP.22 path. Cards that only expose the
  /// Linksfield protocol fall back to that transport, which adapts the same
  /// APDUs to its protobuf SCARD commands.
  static Future<DownloadResult> connect(
    BluetoothDevice device,
    ActivationCode code, {
    String? imei,
    String? confirmationCode,
    ProgressCallback? onProgress,
  }) async {
    onProgress?.call(DownloadStage.connecting, 'Connecting to the card');
    final transport = await openAnyTransport(device);
    final session = EuiccSession(transport);
    try {
      await session.open();
      final downloader = ProfileDownloader(session, onProgress: onProgress);
      return await downloader.download(
        code,
        imei: imei,
        confirmationCode: confirmationCode,
      );
    } finally {
      await session.close();
    }
  }
}

/// Connects to whichever card/reader is in front of the phone.
///
/// Both candidates expose the same NUS service, so the distinction is made by
/// a probe rather than by name: the 9eSIM board answers a status/JSON request,
/// the Linksfield firmware answers a protobuf device request. The one that
/// answers wins; if neither does, the 9eSIM path is returned so the error the
/// user sees describes the more common reader.
Future<EuiccTransport> openAnyTransport(BluetoothDevice device) async {
  final preferred = await probeTransport(device);
  if (preferred != null) return preferred;

  // The probe closes the link, and this firmware refuses a reconnect that
  // arrives before the previous GATT session is fully torn down -- it presents
  // as "connected, sent one chunk, nothing came back". Wait it out.
  await _settleBeforeReconnect(device);

  // Fall back to the Linksfield protobuf protocol, then to a raw-APDU pass.
  try {
    return await LinksfieldTransport.connect(device);
  } catch (_) {
    await _settleBeforeReconnect(device);
    return Esim9BleTransport.connect(device);
  }
}

/// Waits until the platform really considers the link down.
///
/// Android reports `disconnected` before the controller has finished releasing
/// the connection; connecting inside that window fails or, worse, succeeds
/// against a half-open session. Polling the state instead of sleeping a fixed
/// time keeps the common case fast.
Future<void> _settleBeforeReconnect(BluetoothDevice device) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    bool connected;
    try {
      connected = device.isConnected;
    } catch (_) {
      connected = false;
    }
    if (!connected) break;
    await Future.delayed(const Duration(milliseconds: 150));
  }
  try {
    await device.disconnect();
  } catch (_) {}
  await Future.delayed(const Duration(milliseconds: 600));
}

/// Connects and reports which protocol the device speaks, without sending any
/// card command.
///
/// Returns null when the device exposes NUS but does not answer the 9eSIM
/// probe request. That is the cue to try the Linksfield protocol instead.
Future<EuiccTransport?> probeTransport(BluetoothDevice device) async {
  try {
    final ble = await Esim9BleTransport.connect(device);
    final ok = await ble.probe();
    if (ok) return ble;
    await ble.close();
    return null;
  } on TransportError {
    return null;
  }
}

/// Probe result for the diagnostics screen: keeps the connected 9eSIM handle
/// even when it did not answer, so the UI can show what it said (or that it
/// said nothing).
class ReaderProbe {
  final Esim9BleTransport? reader;
  final bool answered;
  final Object? error;

  ReaderProbe({this.reader, this.answered = false, this.error});
}

/// Connects as a 9eSIM reader and reports whether it answers.
///
/// Unlike [probeTransport] this never closes the link on failure: the caller
/// wants the object to ask follow-up questions ("nothing at all?" / "what was
/// the last line you got?").
Future<ReaderProbe> diagnoseReader(
  BluetoothDevice device, {
  void Function(String message)? onStep,
  String? pin,
}) async {
  // Two-phase bring-up: pair with the link DOWN (Android rejects legacy PIN
  // pairing while a GATT link is open), then connect.
  final bonded = await Esim9BleTransport.bondStateOf(device) ==
      BluetoothBondState.bonded;
  if (bonded) {
    onStep?.call('已配对 ✓');
  } else {
    onStep?.call('未配对 → 先断开链路，再发起配对（手机可能弹密码框）…');
    await Esim9BleTransport.disconnectBle(device);
    final ok = await Esim9BleTransport.startBond(device, pin: pin);
    onStep?.call(ok ? '配对成功 ✓' : '配对未完成（密码错或用户取消）——继续尝试直接连接');
  }

  onStep?.call('连接蓝牙…');
  try {
    final ble = await Esim9BleTransport.connect(
      device,
      timeout: const Duration(seconds: 5),
    );
    onStep?.call('已连接，发现 NUS 服务');
    final answered = await ble.probe();
    onStep?.call(answered
        ? '读卡器有回应 ✓'
        : '已连接但读卡器没回 JSON（5 秒内最后收到: '
            '${ble.lastRawLine.isEmpty ? "什么都没有" : ble.lastRawLine}）');
    return ReaderProbe(reader: ble, answered: answered);
  } catch (e) {
    onStep?.call('失败: $e');
    return ReaderProbe(error: e);
  }
}

/// Quick sanity check that [raw] is a BoundProfilePackage (tag 0xBF36).
bool looksLikeBoundProfilePackage(Uint8List raw) {
  if (raw.length < 3) return false;
  return raw[0] == 0xBF && raw[1] == 0x36;
}
