import 'dart:async';

import 'package:esim_ble/esim_ble.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../alipay_h5.dart';
import '../i18n.dart';
import '../job_executor.dart';
import '../lpad_ble.dart' as vendor;
import '../lpad_errors.dart';
import '../store.dart';
import 'order_detail_screen.dart';

/// Stable identity for a profile operation on the vendor-SDK path.
///
/// This must never be the translated label: comparing on `t.cwDelete` ("删除")
/// against `'cwDelete'` silently never matched and made 删除 a no-op.
enum VendorProfileOp { enable, disable, delete, rename }

/// 写卡 App —— 三步流。
///
/// 排版照独立的写卡工具来：选读卡器 → 激活码 → 写卡，一屏之内能看完。
class CardWriterScreenV2 extends StatefulWidget {
  const CardWriterScreenV2({super.key, this.onWrite});

  /// Called after a profile is written so the caller can refresh orders.
  final VoidCallback? onWrite;

  @override
  State<CardWriterScreenV2> createState() => _CardWriterScreenV2State();
}

class _CardWriterScreenV2State extends State<CardWriterScreenV2> {
  final _scanner = CardScanner();
  StreamSubscription<CardDevice>? _scanSub;

  final List<CardDevice> _cards = [];
  bool _scanning = false;
  String? _error;

  CardDevice? _selected;

  EuiccSession? _session;
  Lpa? _lpa;
  bool _connecting = false;
  String? _connectStage;

  /// Card password for the secure-channel handshake, as entered by the user.
  /// Empty means "use the firmware default" (only works on an unprovisioned
  /// card). Kept for the session so a retry does not have to re-ask.
  String _cardPassword = '';

  /// Sentinel return value from [_askCardPassword] meaning "user cancelled".
  static const String _passwordCancelled = '\u0000cancelled';

  String? _eid;
  List<ProfileSummary> _profiles = [];

  /// Nickname for the in-flight 改名 call on the vendor-SDK path, which has no
  /// other channel to carry it into [_vendorProfileAction].
  String? _pendingNickname;

  /// True once the vendor SDK has a live link to the card.  ///
  /// Kept separate from `_session` (the Dart stack's handle) so that "connected"
  /// is not silently false whenever the SDK is the active transport.
  bool _vendorConnected = false;

  /// Job currently executing, and whether the silent worker is running.
  String? _runningJob;
  bool _jobWorkerOn = false;

  /// Watches app resume so an external PayPal approval refreshes the quota.
  AppLifecycleListener? _lifecycle;

  /// Card reads are cheap (a few APDUs), so one minute keeps the dashboard
  /// close to live without keeping the radio busy.
  static const Duration _jobPollInterval = Duration(minutes: 1);

  /// Server-side write allowance for the connected card.
  ///
  /// Null means the check could not be performed (offline, backend down), which
  /// is different from a denial: the write is then allowed but the user is told
  /// the limit went unverified.
  CardQuota? _quota;

  bool _loadingProfiles = false;
  int _pendingNotifications = 0;

  final _codeController = TextEditingController();  final _confirmController = TextEditingController();
  bool _writing = false;
  String? _progress;
  DownloadStage? _stage;

  /// Which stack writes the card.
  ///
  ///   false (default) -- esim_ble, the reverse-engineered Dart port. Every
  ///                      field failure so far was debugged against it, and its
  ///                      diagnostics are far richer (hex dumps, handshake
  ///                      transcripts).
  ///   true            -- the vendor SDK (droidlib-v1.2.0): EuiccBleDevice +
  ///                      LPAdClient over the same GATT link.
  ///
  /// Both stay available on purpose. When one path reports a failure the other
  /// is the fastest way to tell a card problem from a protocol-parsing problem.
  /// Write path is fixed to the vendor SDK; kept as a named constant so the
  /// dispatch sites read the same as before rather than being inlined.
  static const bool _useVendorSdk = true;

  /// Current UI language, refreshed on every rebuild.
  ///
  /// This screen was written in hard-coded Chinese while the rest of the app
  /// followed the language picker. Every label now goes through this.
  L get t => context.watch<AppState>().t;

  /// Native channel present on this build/platform (Android release only).
  bool _vendorAvailable = false;

  /// Structured failure from the vendor path (title / body / codes), mirroring
  /// the SDK demo's error screen. Kept separate from [_error], which is the
  /// free-form string used by the Dart protocol path.
  ErrorMessages? _errorCard;

  /// Last carrier name the operator reported, so a failure after the confirm
  /// dialog can still name the operator.
  String? _lastCarrierName;


  /// Advanced sections stay collapsed until asked for.
  bool _showMore = false;

  /// One line per protocol-probe attempt, kept so a failure is explainable.
  final _scanLog = <String>[];

  @override
  void initState() {
    super.initState();
    // Probe the native bridge once. Absent on iOS/desktop and on builds where
    // the vendor AAR was not compiled in; the switch is then hidden rather than
    // offering a path that can only fail.
    vendor.LpadBle.available().then((ok) {
      if (!mounted) return;
      setState(() => _vendorAvailable = ok);
    });
    // PayPal approval happens in an external browser, so the app is
    // backgrounded and resumed with no callback. Re-read the allowance on
    // resume so a completed quota purchase shows up without a manual refresh.
    _lifecycle = AppLifecycleListener(onResume: () {
      if (mounted && _vendorConnected) unawaited(_refreshQuota());
    });
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _lifecycle?.dispose();
    _scanner.stop();
    _disposeSession();
    vendor.LpadBle.disconnect().catchError((_) {});
    _codeController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _disposeSession() async {
    try {
      await _session?.close();
    } catch (_) {}
    _session = null;
    _lpa = null;
  }

  /// Surface a one-line failure to the user.
  ///
  /// This used to append to a scrolling log banner. The log is gone, but
  /// enable/disable/delete still need somewhere to report a rejected result
  /// code, so it lands in the error banner instead.
  void _appendInfo(String line) {
    if (!mounted) return;
    setState(() => _error = line);
  }

  // ------------------------------------------------------------------ scan

  Future<void> _toggleScan() async {
    if (_scanning) {
      await _stopScan();
      return;
    }
    setState(() {
      _cards.clear();
      _scanning = true;
      _error = null;
    });

    try {
      final state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
        setState(() {
          _scanning = false;
          _error = t.cwBluetoothOff;
        });
        return;
      }
    } catch (_) {}

    _scanSub = _scanner.scan().listen(
      (card) {
        if (!mounted) return;
        setState(() {
          if (!_cards.any((c) => c.id == card.id)) _cards.add(card);
        });
      },
      onError: (Object e) => setState(() {
        _error = t.cwScanFailed('$e');
        _scanning = false;
      }),
      onDone: () => setState(() => _scanning = false),
    );
  }

  Future<void> _stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    await _scanner.stop();
    if (mounted) setState(() => _scanning = false);
  }

  // --------------------------------------------------------------- connect

  /// Connects the selected reader.
  ///
  /// Only the vendor SDK path remains: `LpadBle.connect()`, i.e. EuiccBleDevice
  /// + LPAdClient in Java, with no flutter_blue_plus involvement and no Dart
  /// protocol code. The Dart stack was removed from this screen because a
  /// provisioning tool cannot support two divergent failure modes.
  Future<void> _connect(CardDevice card) => _connectVendor(card);

  Future<void> _connectVendor(CardDevice card) async {
    await _stopScan();
    await _disposeSession();

    setState(() {
      _selected = card;
      _connecting = true;
      _error = null;
      _errorCard = null;
      _eid = null;
      _profiles = [];
      _scanLog.clear();
      _connectStage = t.cwStatusConnectVendor();
    });

    void note(String line) {
      if (!mounted) return;
      setState(() => _scanLog.add(line));
    }

    final mac = card.device.remoteId.str;
    try {
      var psw = _cardPassword;
      if (psw.isEmpty) {
        final resolved =
            await _resolveCardPassword(card, mac, note: note);
        if (resolved == null) {
          setState(() {
            _connecting = false;
            _connectStage = null;
          });
          return;
        }
        psw = resolved;
      }

      if (mounted) setState(() => _connectStage = t.cwStatusBleSession());
      final info = await vendor.LpadBle.connect(mac, password: psw);
      note(t.cwSdkConnected());
      note('vendor=${info['vendor']} device=${info['deviceName']}');
      note('imei=${info['imei']} sn=${info['sn']}');

      if (mounted) setState(() => _connectStage = t.cwStatusReadingCard());
      String? eid;
      List<vendor.LpadProfile> profiles = [];
      try {
        eid = await vendor.LpadBle.eid();
        profiles = await vendor.LpadBle.listProfiles();
      } catch (e) {
        note(t.cwReadFailedWith('$e'));
      }

      // Ask the server how many slots this card has left before allowing any
      // write. Keyed by EID (fixed for the chip), not by ICCID (one per
      // profile, so it changes as profiles come and go).
      //
      // A failure to reach the server is not treated as a denial: the quota
      // check is an operator control, and blocking the whole screen on a
      // flaky network would turn a billing rule into an outage. It is
      // surfaced so the user knows the limit was not verified.
      CardQuota? quota;
      if (eid != null && eid.isNotEmpty) {
        // Push the real on-card profile list up first. The quota check below
        // compares against the server's 'used' count, and that count is only
        // right once the server knows about profiles it never wrote itself.
        if (profiles.isNotEmpty) {
          try {
            await context.read<AppState>().api.syncProfiles(
              eid,
              profiles
                  .map((p) => {
                        'iccid': p.iccid,
                        'state': p.state,
                        'nickname': p.nickname,
                        'profile_name': p.profileName,
                        'service_provider': p.serviceProvider,
                      })
                  .toList(),
            );
          } catch (e) {
            note(t.cwQuotaCheckFailed('$e'));
          }
        }

        if (mounted) setState(() => _connectStage = t.cwStatusCheckQuota());
        try {
          quota = await context.read<AppState>().api.bindCard(eid);
          note(t.cwQuotaLine(quota.boundCount, quota.capacity));
          if (!quota.allowed) note(quota.reasonText);
        } catch (e) {
          note(t.cwQuotaCheckFailed('$e'));
        }
      }

      if (!mounted) return;
      setState(() {
        _connecting = false;
        _connectStage = null;
        _eid = eid;
        _quota = quota;
        // Map onto the shared view model so the rest of the page (counts, the
        // "connected" gate) keeps working unchanged.
        _profiles = profiles
            .map((p) => ProfileSummary(
                  iccid: p.iccid,
                  // The SDK's profile list (API 3.3.2) does not expose these
                  // three; left empty rather than invented.
                  isdpAid: '',
                  nickname: p.nickname,
                  serviceProvider: p.serviceProvider,
                  profileName: p.profileName,
                  state: p.state,
                  profileClass: '',
                ))
            .toList();
        // Reveal what was just read; the section lives behind a collapsed
        // "more" toggle, so without this the SDK results stayed invisible.
        _vendorConnected = true;
        if (_profiles.isNotEmpty || (eid != null && eid.isNotEmpty)) {
          _showMore = true;
        }
      });
      // Start the silent job worker. It polls the server, claims any queued
      // read_info, reads the card and reports back -- with no UI involvement.
      unawaited(_startJobWorker());
    } on vendor.LpadError catch (e) {
      if (!mounted) return;
      setState(() {
        _vendorConnected = false;
        _connecting = false;
        _connectStage = null;
        _profiles = [];
        _eid = null;
        _errorCard = e.messages();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _vendorConnected = false;
        _connecting = false;
        _connectStage = null;
        _error = t.cwConnectFailedWith('$e');
      });
    }
  }

  Future<void> _refreshAll() async {
    await _refreshProfiles();
    await _refreshNotifications();
  }

  Future<void> _refreshProfiles() async {
    // The refresh button in the profile header must work on both stacks; it
    // used to bail out silently whenever `_lpa` was null.
    if (_useVendorSdk) {
      await _refreshVendorProfiles();
      return;
    }
    final lpa = _lpa;
    if (lpa == null) return;
    setState(() => _loadingProfiles = true);
    try {
      final list = await lpa.listProfiles();
      if (!mounted) return;
      setState(() => _profiles = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = t.cwReadFailedWith('$e'));
    } finally {
      if (mounted) setState(() => _loadingProfiles = false);
    }
  }

  Future<void> _refreshNotifications() async {
    final lpa = _lpa;
    if (lpa == null) return;
    try {
      final seqs = await lpa.listNotifications();
      if (!mounted) return;
      setState(() => _pendingNotifications = seqs.length);
    } catch (_) {
      // Notifications are advisory; a failure here must not surface as an error.
    }
  }

  Future<void> _drainNotifications() async {
    final lpa = _lpa;
    if (lpa == null) return;
    setState(() => _progress = t.cwStatusSyncNotif());
    try {
      final result = await lpa.flushNotifications();
      await _refreshNotifications();
      _appendInfo(t.cwNotifDelivered(result.delivered) + 
          (result.errors.isEmpty ? '' : t.cwFailCount(result.errors.length)));
    } catch (e) {
      _appendInfo(t.cwNotifSyncFailed('$e'));
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  // ------------------------------------------------------- profile actions

  Future<void> _profileAction(
    VendorProfileOp op,
    String label,
    String iccid,
    Future<void> Function(Lpa lpa) action,
  ) async {
    final lpa = _lpa;
    // On the vendor-SDK path `_lpa` is always null, and this used to return
    // silently -- the 启用/停用/删除 chips did nothing at all, with no error
    // and no log line. Dispatch to the SDK instead.
    if (_useVendorSdk) {
      await _vendorProfileAction(op, label, iccid);
      return;
    }
    if (lpa == null) {
      _appendInfo(t.cwOpNotConnected(label));
      return;
    }
    setState(() => _progress = '$label $iccid …');
    try {
      await action(lpa);
      _appendInfo(t.cwOpSucceeded(label, iccid));
      await _refreshProfiles();
    } catch (e) {
      _appendInfo(t.cwOpFailed(label, '$e'));
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  /// 启用 / 停用 / 删除 against the vendor SDK.
  ///
  /// The SDK answers a raw result code rather than throwing, so a non-zero
  /// code has to be surfaced here or the chip looks like it did nothing.
  ///
  /// [op] is a stable operation key, **not** a translated label. This used to
  /// switch on the i18n string (`'cwDelete'` etc.) while the call sites passed
  /// `t.cwDelete` -- i.e. the localized text "删除". Nothing ever matched, every
  /// tap fell through to `default: code = 0`, and the UI reported success
  /// without touching the card.
  Future<void> _vendorProfileAction(VendorProfileOp op, String label, String iccid) async {
    setState(() => _progress = '$label $iccid …');
    try {
      final int code;
      switch (op) {
        case VendorProfileOp.enable:
          code = await vendor.LpadBle.enable(iccid);
        case VendorProfileOp.disable:
          code = await vendor.LpadBle.disable(iccid);
        case VendorProfileOp.delete:
          code = await _vendorDeleteProfile(iccid);
        case VendorProfileOp.rename:
          code = await vendor.LpadBle.setNickname(iccid, _pendingNickname ?? '');
      }
      if (code != 0) {
        _appendInfo(t.cwOpResultCode(label, code));
        if (mounted) {
          final msg = const DetailedErrorMessages().forCode(code);
          setState(() {
            _errorCard = msg;
          });
        }
        // A failed enable/disable can leave the reader's logical channel in a
        // state where every later APDU answers SIM_ERR. Re-establish the link
        // so the next attempt starts clean instead of failing forever.
        await _recoverVendorLink();
        return;
      }
      // The card needs a re-query before the new state shows up.
      await vendor.LpadBle.resetDevice();
      await _refreshVendorProfiles();
      // Only claim success once the card itself agrees. A result code of 0 is
      // not proof: the profile can still be there (e.g. a delete the eUICC
      // silently ignored).
      if (!_verifyVendorOp(op, iccid)) return;
      _appendInfo(t.cwOpSucceeded(label, iccid));
    } on vendor.LpadError catch (e) {
      _appendInfo(t.cwOpFailed(label, e.message));
      if (mounted) setState(() => _errorCard = e.messages());
    } catch (e) {
      _appendInfo(t.cwOpFailed(label, '$e'));
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  /// Deletes a profile, disabling it first when needed.
  ///
  /// An enabled profile is refused by the eUICC (result 0x02 / ProfileOperation
  /// not allowed), which reads to the user as "delete does nothing". Disable,
  /// re-query, then delete.
  Future<int> _vendorDeleteProfile(String iccid) async {
    final before = _profiles.where((p) => p.iccid == iccid).toList();
    if (before.isNotEmpty && before.first.isEnabled) {
      final disableCode = await vendor.LpadBle.disable(iccid);
      if (disableCode != 0) return disableCode;
      await vendor.LpadBle.resetDevice();
      await _refreshVendorProfiles();
    }
    return vendor.LpadBle.delete(iccid);
  }

  /// Confirms the card actually reflects [op] after a successful result code.
  ///
  /// Returns false (and shows an error card) when the profile is still present
  /// after a delete. [_refreshVendorProfiles] has already re-read the card, so
  /// this only inspects local state.
  bool _verifyVendorOp(VendorProfileOp op, String iccid) {
    if (op != VendorProfileOp.delete) return true;
    final still = _profiles.any((p) => p.iccid == iccid);
    if (still) {
      _appendInfo(t.cwOpFailed(t.cwDelete, 'profile still present on card'));
      if (mounted) {
        setState(() => _errorCard = ErrorMessages(
              title: '删除未生效',
              bodyText: '卡上仍然存在该 eSIM。读写器返回成功，但卡片没有真的删掉这一条。',
              errorDetails: '请确认这张卡没有被锁定，然后重试；仍失败请换一张卡测试。',
              technical: 'verify: iccid=$iccid still in listProfiles',
            ));
      }
      return false;
    }
    return true;
  }

  /// Rebuild the vendor SDK link after a failed card operation.
  ///
  /// The reader keeps one logical channel per session; a rejected APDU can
  /// leave it unusable (Channel -1 / SIM_ERR) and every subsequent call fails
  /// no matter how valid it is. Reconnecting is the only recovery the SDK
  /// offers, so do it eagerly and let the next tap succeed.
  Future<void> _recoverVendorLink() async {
    final card = _selected;
    if (card == null || !_vendorConnected) return;
    final mac = card.device.remoteId.str;
    try {
      await vendor.LpadBle.disconnect();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _vendorConnected = false);

    final psw = await _resolveCardPassword(card, mac);
    if (psw == null) return;
    try {
      await vendor.LpadBle.connect(mac, password: psw);
      if (!mounted) return;
      setState(() => _vendorConnected = true);
      await _refreshVendorProfiles();
    } catch (e) {
      if (mounted) setState(() => _vendorConnected = false);
    }
  }

  Future<void> _refreshVendorProfiles() async {
    if (mounted) setState(() => _loadingProfiles = true);
    try {
      final list = await vendor.LpadBle.listProfiles();
      if (!mounted) return;
      setState(() {
        _profiles = list
            .map((p) => ProfileSummary(
                  iccid: p.iccid,
                  isdpAid: '',
                  nickname: p.nickname,
                  serviceProvider: p.serviceProvider,
                  profileName: p.profileName,
                  state: p.state,
                  profileClass: '',
                ))
            .toList();
      });
    } catch (e) {
      _appendInfo(t.cwRefreshFailed(t.cwCardMgmt, '$e'));
    } finally {
      if (mounted) setState(() => _loadingProfiles = false);
    }
  }

  /// Asks for the card password used by the secure-channel handshake.
  ///
  /// Returns the entered string, an empty string when the user chooses to use
  /// the firmware default, or [_passwordCancelled] when they back out of the
  /// whole connect flow.
  ///
  /// This is deliberately separate from the Bluetooth PIN: on this hardware the
  /// PIN bonds the link, while the password keys the AES-CCM session. Cards
  /// that have had a password set reject the default PSK — and the only
  /// symptom is a fresh challenge instead of UPDATE, which looks like a
  /// protocol bug rather than a wrong password.
  /// Asks for the card password. Required — there is no fallback.
  ///
  /// This used to accept an empty answer and fall back to the firmware default
  /// (`Linksfield@Esim#2025`, read out of the vendor APK). That default only
  /// works on an unprovisioned card, and when it is wrong the card answers with
  /// a fresh challenge instead of UPDATE — indistinguishable from a protocol
  /// bug. Since the deployed cards are provisioned, guessing is worse than
  /// asking: every wrong guess looks like a broken reader.
  /// Resolve the PSK for [mac], asking the user only when nothing usable is
  /// remembered. Returns null when the user cancelled.
  ///
  /// Centralised because the same logic used to be written twice, and both
  /// copies shared the same defect: when a password *was* remembered they left
  /// the local variable empty and connected with `""`, which the native side
  /// rejects as missing -- so the dialog reappeared every attempt.
  Future<String?> _resolveCardPassword(
    CardDevice card,
    String mac, {
    void Function(String)? note,
  }) async {
    if (_cardPassword.isNotEmpty) return _cardPassword;

    final remembered = await vendor.LpadBle.hasRememberedPassword(mac);
    if (remembered) {
      final cached = await vendor.LpadBle.rememberedPassword(mac);
      if (cached != null && cached.isNotEmpty) {
        _cardPassword = cached;
        note?.call(t.cwPasswordSaved);
        return cached;
      }
      // Stored but unreadable (Keystore reset, entry wiped): drop it so the
      // dialog is reached instead of sending an empty string.
      await vendor.LpadBle.forgetPassword(mac);
    }

    if (!mounted) return null;
    final entered = await _askCardPassword(card);
    if (entered == _passwordCancelled || entered.isEmpty) return null;
    _cardPassword = entered;
    return entered;
  }

  Future<String> _askCardPassword(CardDevice card) async {
    final controller = TextEditingController(text: _cardPassword);
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (c) => StatefulBuilder(
        builder: (c, setDialogState) => AlertDialog(
          title: Text(t.cwEnterPassword),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // One instruction only: where the password comes from. The
              // device-name line and the long note about Bluetooth PINs were
              // noise on a dialog whose only action is typing one value.
              Text(
                t.cwPasswordNote,
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: t.cwCardPassword,
                  hintText: t.cwPasswordRequired,
                  border: const OutlineInputBorder(),
                  suffixIcon: controller.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            controller.clear();
                            setDialogState(() {});
                          },
                        ),
                ),
                onChanged: (_) => setDialogState(() {}),
                onSubmitted: (v) {
                  if (v.trim().isNotEmpty) Navigator.pop(c, v.trim());
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text(t.cwCancel),
            ),
            FilledButton(
              // Disabled until something is typed: the only way to proceed with
              // an empty field would be a guess, which is what this replaces.
              onPressed: controller.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(c, controller.text.trim()),
              child: Text(t.cwConnect),
            ),
          ],
        ),
      ),
    );
    // Null (barrier tap / back) is treated as cancel: silently falling back to
    // the default would repeat the failure the dialog exists to avoid.
    return result ?? _passwordCancelled;
  }

  Future<void> _confirmThen(    String title,
    String body,
    Future<void> Function() run,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(t.cwCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(t.cwOk, style: TextStyle(color: Color(0xFFCF1322))),
          ),
        ],
      ),
    );
    if (ok == true) await run();
  }

  Future<void> _rename(ProfileSummary p) async {
    final controller = TextEditingController(text: p.nickname);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t.cwRenameTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: t.cwNewName),
          onSubmitted: (v) => Navigator.pop(c, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(t.cwCancel)),
          TextButton(
            onPressed: () => Navigator.pop(c, controller.text.trim()),
            child: Text(t.cwSave),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    if (!_useVendorSdk) {
      // No vendor link on this path; the caller goes through _profileAction.
      return;
    }
    _pendingNickname = name;
    await _vendorProfileAction(VendorProfileOp.rename, t.cwRename, p.iccid);
    return;
  }

  // --------------------------------------------------------------- download

  Future<void> _writeProfile() async {
    final card = _selected;
    final code = ActivationCode.tryParse(_codeController.text);
    if (card == null || code == null) {
      setState(() => _error = t.cwActivationInvalid);
      return;
    }

    // Hard stop when the server said this card has no slots left. This is the
    // only enforcement point for capacity: the count lives in the backend, and
    // checking here is what makes the operator's limit real rather than a
    // number on an admin screen.
    final quota = _quota;
    if (quota != null && !quota.allowed) {
      setState(() => _error = quota.reasonText);
      return;
    }

    if (_useVendorSdk) {
      await _writeProfileWithVendorSdk(card, code);
      return;
    }

    setState(() {
      _writing = true;
      _error = null;
      _progress = t.cwStatusPrepareDownload();
      _stage = DownloadStage.connecting;
    });

    try {
      await _disposeSession();

      final result = await ProfileDownloader.connect(
        card.device,
        code,
        confirmationCode: _confirmController.text.trim().isEmpty
            ? null
            : _confirmController.text.trim(),
        onProgress: (stage, detail) {
          if (!mounted) return;
          setState(() {
            _stage = stage;
            _progress = detail;
          });
        },
      );

      if (!mounted) return;
      setState(() {
        _writing = false;
        _progress = result.iccid.isEmpty
            ? t.cwWriteDone
            : t.cwWriteDoneIccid(result.iccid);
      });
      _codeController.clear();
      widget.onWrite?.call();

      await _connect(card);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _writing = false;
        _error = t.cwWriteFailedWith('$e');
        _progress = null;
      });
    }
  }

  // -------------------------------------------------------- code scanning

  /// Same write, driven by the vendor SDK instead of esim_ble.
  ///
  /// Deliberately mirrors the vendor demo's order rather than inventing one:
  ///
  ///   metadata -> show carrier -> download -> report ICCID
  ///
  /// The metadata step is the point of this path. It asks the operator which
  /// carrier the activation code belongs to *before* anything is written, so a
  /// miscoded QR or a wrong region is caught while it is still free to abort.
  /// esim_ble can only discover that after the download has started.
  Future<void> _writeProfileWithVendorSdk(
      CardDevice card, ActivationCode code) async {
    final confirm = _confirmController.text.trim();

    setState(() {
      _writing = true;
      _error = null;
      _progress = t.cwStatusConnectSdk();
      _stage = DownloadStage.connecting;
    });

    // The native side owns the GATT link; a Dart-side EuiccSession on the same
    // physical device would fight it for notifications.
    await _disposeSession();

    var stage = t.cwConnect;
    void progress(String s, String p) {
      stage = s;
      if (!mounted) return;
      setState(() {
        _progress = '$s：$p';
        _stage = _vendorStageFrom(s);
      });
    }

    try {
      final mac = card.device.remoteId.str;

      // Password is mandatory on this path. Only skip asking when a previous
      // connect with this exact card already succeeded and the value is in
      // Keystore-backed storage.
      final psw = await _resolveCardPassword(card, mac, note: (s) => progress(t.cwConnect, s));
      if (psw == null) {
        setState(() {
          _writing = false;
          _stage = null;
          _progress = null;
        });
        return;
      }

      progress(t.cwConnect, t.cwStatusBleSession());
      await vendor.LpadBle.connect(mac, password: psw);

      progress(t.cwStatusReadCardInfo, t.cwStatusConfirmCarrier());
      final meta = await vendor.LpadBle.metadata(code.toString());
      if (meta['ok'] != true) {
        // resultCode is the packed detailed code; hand it to the same decoder
        // the download path uses so a bad QR reports "无效的激活码", not a
        // generic "operator rejected it".
        final rc = (meta['resultCode'] as num?)?.toInt() ?? -1;
        throw vendor.LpadError(
          'METADATA_FAILED',
          'Activation code metadata failed',
          {'detailedCode': rc},
        );
      }

      final carrier = (meta['carrierName'] ?? '').toString();
      _lastCarrierName = carrier.isEmpty ? null : carrier;
      if (!mounted) return;

      // Same gate the vendor demo puts in front of the download.
      final accepted = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(t.cwConfirmCarrier),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(carrier.isEmpty ? t.cwCarrierUnknown : carrier,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text(t.cwWriteAutoEnable(),
                  style: TextStyle(fontSize: 12, color: Color(0xFF8C8C8C))),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: Text(t.cwCancel)),
            FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: Text(t.cwWriteStartShort())),
          ],
        ),
      );
      if (accepted != true) {
        throw vendor.LpadError('CANCELLED', t.cwWriteCancelled());
      }

      progress(t.cwStepWrite, t.cwWritingProgress);
      final result = await vendor.LpadBle.download(
        code.toString(),
        confirmationCode: confirm.isEmpty ? null : confirm,
      );

      // API 3.2.2: the card must re-query and re-register on the network after a
      // profile lands, otherwise the new eSIM has no service until something
      // else triggers it. The vendor demo calls resetDevice() right after the
      // download returns, before refreshing the list.
      progress(t.cwStatusRenotifyShort, t.cwStatusRenotify());
      try {
        await vendor.LpadBle.resetDevice();
      } catch (e) {
        // A failed re-register does not undo a successful write. Surface it in
        // the progress line rather than as an error card, so the user sees the
        // ICCID and knows the profile is on the card.
        progress(t.cwStatusRenotifyShort, t.cwRenoitfyFailed('$e'));
      }

      if (!mounted) return;
      setState(() {
        _writing = false;
        _progress = result.hasIccid
            ? t.cwWriteDoneIccid(result.iccid)
            : t.cwWriteDone;
        _stage = DownloadStage.done;
      });
      _codeController.clear();
      widget.onWrite?.call();

      await _connect(card);
    } on vendor.LpadError catch (e) {
      if (!mounted) return;
      if (e.code == 'CANCELLED') {
        setState(() {
          _writing = false;
          _stage = null;
          _progress = null;
        });
        return;
      }
      setState(() {
        _writing = false;
        _stage = null;
        _progress = null;
        // Same three-part shape the SDK demo shows: what failed, what it means
        // in user terms, and the codes support will ask for.
        _errorCard = e.messages(carrierName: _lastCarrierName);
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _writing = false;
        _stage = null;
        _progress = null;
        _errorCard = ErrorMessages(
          title: t.cwWriteFailed,
          bodyText: '$e',
          technical: 'stage=$stage',
        );
        _error = null;
      });
    }
  }

  /// Maps the vendor stage labels onto the progress bar's existing scale.
  DownloadStage _vendorStageFrom(String stage) {
    switch (stage) {
      case 'cwConnect':
        return DownloadStage.connecting;
      case 'cwReadCard':
        return DownloadStage.readingCard;
      case 'cwWrite':
        return DownloadStage.loadBoundProfilePackage;
      default:
        return DownloadStage.connecting;
    }
  }

  // -------------------------------------------------------- code scanning

  Future<void> _scanCode() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _QrScanPage()),
    );
    if (raw == null || raw.isEmpty) return;
    _codeController.text = raw.trim();
    if (mounted) setState(() => _error = null);
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    // Two stacks, one notion of "connected". Keying this on `_session` alone
    // made the write button permanently grey on the vendor-SDK path, where no
    // CardSession exists -- the same mistake that hid the profile list.
    final connected = _session != null || _vendorConnected;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: Text(t.cwTitle),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        actions: [
          if (connected)
            IconButton(
              tooltip: t.cwRefresh,
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: _refreshAll,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_errorCard != null) _errorCardWidget(_errorCard!),
          if (_error != null)
            _banner(_error!, const Color(0xFFFFF1F0), const Color(0xFFCF1322),
                copy: true),

          // ---- step 1 ----------------------------------------------------
          _panel(
            step: 1,
            title: t.cwStepPickReader,
            subtitle: connected
                ? t.cwConnected
                : (_connecting
                    ? (_connectStage ?? t.cwConnecting)
                    : t.cwReaderHint),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!connected && !_connecting)
                  FilledButton.icon(
                    onPressed: _toggleScan,
                    icon: Icon(
                        _scanning ? Icons.stop : Icons.bluetooth_searching,
                        size: 18),
                    label: Text(_scanning ? t.cwStopScan : t.cwScanReader),
                  ),
                if (_scanning)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                if (_connecting)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (!connected)
                  for (final c in _cards)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: const Icon(Icons.memory,
                          size: 20, color: Color(0xFF1677FF)),
                      title: Text(c.name, style: const TextStyle(fontSize: 13)),
                      subtitle: Text('${c.id} · ${c.rssi} dBm',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey[500])),
                      trailing: Text(t.cwConnect,
                          style: TextStyle(fontSize: 12)),
                      onTap: () => _connect(c),
                    ),
                if (connected) _connectedSummary(),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ---- step 2 ----------------------------------------------------
          _panel(
            step: 2,
            title: t.cwStepActivation,
            subtitle: t.cwActivationHint,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _codeController,
                  enabled: !_writing,
                  maxLines: 2,
                  minLines: 1,
                  style: const TextStyle(
                      fontSize: 12, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    hintText: t.cwActivationPlaceholder,
                    hintStyle: TextStyle(fontSize: 12),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _writing ? null : _scanCode,
                        icon: const Icon(Icons.qr_code_scanner, size: 16),
                        label: Text(t.cwScanQr),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _confirmController,
                        enabled: !_writing,
                        style: const TextStyle(
                            fontSize: 12, fontFamily: 'monospace'),
                        decoration: InputDecoration(
                          hintText: t.cwConfirmCodeOptional,
                          hintStyle: TextStyle(fontSize: 11),
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ---- step 3 ----------------------------------------------------
          _panel(
            step: 3,
            title: t.cwStepWrite,
            subtitle: connected ? t.cwWriteReady : t.cwWriteNeedsReader,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton(
                  onPressed: (_writing || !connected) ? null : _writeProfile,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                  ),
                  child: Text(_writing ? t.cwRunning : t.cwStartWrite),
                ),
                if (_vendorAvailable) ...[
                  const SizedBox(height: 8),
                // The vendor SDK is the only stack this screen drives now.
                // The Dart port is kept in the tree for its hex diagnostics,
                // but exposing a switch to it on a provisioning tool invited
                // users into a path that fails differently and cannot be
                // supported from here.

                ],
                if (_stage != null || _progress != null) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: _stage == null ? null : _stageFraction(_stage!),
                    minHeight: 3,
                  ),
                  const SizedBox(height: 6),
                  Text(_progress ?? _stage?.name ?? '',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey[700])),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ---- everything else, collapsed --------------------------------
          _morePanel(),
        ],
      ),
    );
  }

  Widget _connectedSummary() {
    final p = _selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.check_circle,
                color: Color(0xFF52C41A), size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                p?.name ?? t.cwConnected,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: () async {
                await _disposeSession();
                if (_vendorConnected) {
                  // The SDK owns its own GATT link; closing the Dart session
                  // does not tear it down.
                  try {
                    await vendor.LpadBle.disconnect();
                  } catch (_) {}
                }
                if (!mounted) return;
                setState(() {
                  _vendorConnected = false;
                  _selected = null;
                  _profiles = [];
                  _eid = null;
                  _pendingNotifications = 0;
                });
              },
              child: Text(t.cwDisconnect, style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        if (_eid != null && _eid!.isNotEmpty)
          _kv('EID', _eid!),
        _kv(t.cwProfileCount, t.cwCardCount(_profiles.length) +
            (_profiles.any((x) => x.isEnabled) ? t.cwEnabledSuffix : '')),
        // Server-side allowance. Shown here so the operator sees the same
        // number the backend enforces, next to what the app itself counted.
        if (_quota != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 76,
                  child: Text(t.cwQuotaTitle,
                      style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                ),
                Expanded(
                  child: Text(
                    _quota!.known
                        ? '${_quota!.boundCount} / ${_quota!.capacity}'
                        : _quota!.reasonText,
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: _quota!.allowed
                          ? const Color(0xFF389E0D)
                          : const Color(0xFFCF1322),
                    ),
                  ),
                ),
                if (_quota!.known)
                  TextButton(
                    onPressed: _buyQuota,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: const Text('扩容', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ),
        if (_pendingNotifications > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                Text(t.cwNotifPending(_pendingNotifications),
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _drainNotifications,
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                  child: Text(t.cwStatusSync(), style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _morePanel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          ListTile(
            title: Text(t.cwMore,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: Text(
              _vendorConnected || _session != null
                  ? t.cwCardMgmt
                  : t.cwNeedConnect,
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
            trailing: Icon(
              _showMore ? Icons.expand_less : Icons.expand_more,
              size: 20,
            ),
            onTap: () => setState(() => _showMore = !_showMore),
          ),
          if (_showMore)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              child: Column(
                children: [
                  // Gated on "connected", not on `_session`: the vendor SDK
                  // path keeps no CardSession, so keying off it hid every
                  // profile the SDK had just read.
                  if (_session != null || _profiles.isNotEmpty ||
                      (_eid != null && _eid!.isNotEmpty))
                    _profilesSection(),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _profilesSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(t.cwCardMgmt,
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              if (_loadingProfiles)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  tooltip: t.cwStatusRefreshingProfiles(),
                  onPressed: _refreshProfiles,
                  icon: const Icon(Icons.refresh),
                ),
            ],
          ),
          if (_profiles.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(t.cwNoProfiles,
                  style: TextStyle(fontSize: 12, color: Colors.grey[500])),
            )
          else
            ..._profiles.map(_profileTile),
          const Divider(height: 20),
        ],
      );

 // ---------------------------------------------------------- server jobs

  /// Buy extra profile slots for the connected card.
  ///
  /// Quota is a software limit the backend enforces (`_fulfill_quota` raises
  /// `capacity`), but the eUICC still runs out of physical room, so the server
  /// refuses a purchase that will not fit. That refusal surfaces here as the
  /// checkout error instead of a silent no-op.
  Future<void> _buyQuota() async {
    final card = _selected;
    final quota = _quota;
    if (card == null || quota == null) return;

    List<Plan> products;
    try {
      final app = context.read<AppState>();
      products = await app.api.plans(kind: "quota", lang: app.lang.code);
    } catch (e) {
      _appendInfo('获取扩容商品失败：$e');
      return;
    }
    if (!mounted) return;
    if (products.isEmpty) {
      _appendInfo('暂无可购买的扩容商品');
      return;
    }

    final chosen = await showModalBottomSheet<Plan>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('扩容套餐位',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  Text('当前 ${quota.boundCount}/${quota.capacity}',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey[600])),
                ],
              ),
            ),
            for (final p in products)
              ListTile(
                title: Text(p.title, style: const TextStyle(fontSize: 14)),
                subtitle: Text('增加 ${p.quotaSlots} 个位置',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                trailing: Text('${p.price.toStringAsFixed(2)} ${p.currency}',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                onTap: () => Navigator.pop(c, p),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;

    final state = context.read<AppState>();
    final email = state.user?.email ?? '';
    if (email.isEmpty) {
      _appendInfo('请先登录再购买扩容');
      return;
    }

    // Ask the server which channels are actually enabled. The store runs in
    // `gateway` mode, so hardcoding `mock` here fails every checkout.
    List<PaymentGateway> gateways;
    try {
      gateways = await state.api.paymentGateways();
    } catch (e) {
      _appendInfo('获取支付方式失败：$e');
      return;
    }
    if (!mounted) return;
    if (gateways.isEmpty) {
      _appendInfo('暂无可用支付方式，请联系客服');
      return;
    }

    final gateway = await showModalBottomSheet<PaymentGateway>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('选择支付方式',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
            for (final g in gateways)
              ListTile(
                leading: const Icon(Icons.account_balance_wallet_outlined),
                title: Text(g.label, style: const TextStyle(fontSize: 14)),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => Navigator.pop(c, g),
                subtitle: g.instructions.isNotEmpty
                    ? Text(g.instructions,
                        style:
                            TextStyle(fontSize: 11, color: Colors.grey[600]))
                    : null,
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (gateway == null || !mounted) return;

    setState(() => _progress = '正在下单…');
    try {
      final order = await state.api.checkout(
        items: [
          {"plan_id": chosen.id, "quantity": 1}
        ],
        email: email,
        paymentProvider: gateway.provider,
      );
      _appendInfo('扩容订单 ${order.orderNo} 已创建（${order.status}）');
      if (order.status == 'paid' || order.status == 'fulfilled') {
        await _refreshQuota();
      } else if (gateway.provider == 'alipay') {
        // Alipay goes through the H5 cashier: no native SDK, works on iOS.
        final res = await state.api.alipayCreate(order.orderNo);
        final orderString = res['order_string'] as String? ?? '';
        final chargeUrl = res['charge_url'] as String? ?? '';
        if (orderString.isEmpty || chargeUrl.isEmpty) {
          _appendInfo('支付宝下单失败，请稍后在「我的订单」重试');
          return;
        }
        if (!mounted) return;
        final r = await Navigator.push<AlipayH5Result>(
          context,
          MaterialPageRoute(
            builder: (_) => AlipayH5PayPage(
              chargeUrl: chargeUrl,
              orderString: orderString,
              checkStatus: () async => state.api.alipayStatus(order.orderNo),
            ),
          ),
        );
        if (r == AlipayH5Result.paid) {
          _appendInfo('支付成功，配额已更新');
          await _refreshQuota();
        } else {
          _appendInfo('支付未完成，可在「我的订单」继续支付');
        }
      } else if (gateway.provider == 'paypal') {
        // PayPal is a single external redirect, so it can be started straight
        // from here without leaving the card writer.
        final res = await state.api.paypalCreate(order.orderNo);
        final url = res['approve_url'] as String? ?? '';
        if (url.isEmpty) {
          _appendInfo('PayPal 下单失败，请稍后在「我的订单」重试');
          return;
        }
        final uri = Uri.tryParse(url);
        if (uri != null) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
        _appendInfo('请在 PayPal 完成付款，返回后在下拉刷新配额');
      } else {
        // Alipay / Stripe / Antom each need a different hand-off (native SDK,
        // hosted checkout, app scheme). OrderDetailScreen already implements
        // all of them, so route there instead of dead-ending with a toast --
        // the previous version only printed a line and left the order
        // unpaid until it was auto-cancelled after 15 minutes.
        _appendInfo('请完成支付，付款后额度自动增加');
        if (!mounted) return;
        final paid = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => OrderDetailScreen(
              orderNo: order.orderNo,
              popOnPaid: true,
            ),
          ),
        );
        if (!mounted) return;
        if (paid == true) await _refreshQuota();
      }
    } catch (e) {
      _appendInfo('扩容下单失败：$e');
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  /// Re-read the server's slot allowance after a quota change.
  Future<void> _refreshQuota() async {
    final eid = _eid;
    if (eid == null || eid.isEmpty) return;
    try {
      final q = await context.read<AppState>().api.bindCard(eid);
      if (!mounted) return;
      setState(() => _quota = q);
      _appendInfo(t.cwQuotaLine(q.boundCount, q.capacity));
    } catch (e) {
      _appendInfo(t.cwQuotaCheckFailed('$e'));
    }
  }

  /// Silent worker: while the reader is connected, drain the server's queue.
  ///
  /// There is deliberately **no UI** for this. The server (`sim_poller`) keeps
  /// one `read_info` queued per active card every minute; the app's only job is
  /// to notice it, claim it, read the card and report back. Showing a job list
  /// turned an automatic sync into something an operator had to babysit.
  ///
  /// Polling stops when the link drops and resumes on reconnect, so this costs
  /// one cheap request per interval while a reader is attached.
  Future<void> _startJobWorker() async {
    if (_jobWorkerOn) return;
    _jobWorkerOn = true;
    while (mounted && _vendorConnected) {
      try {
        final api = context.read<AppState>().api;
        final list = await api.myCardJobs();
        if (!mounted || !_vendorConnected) break;
        if (list.isNotEmpty && _runningJob == null) {
          await _runJob(list.first);
        }
      } catch (_) {
        // A flaky network must not kill the worker; the next tick retries.
      }
      await Future.delayed(_jobPollInterval);
    }
    _jobWorkerOn = false;
  }

  /// Claim -> execute -> report, in that order.
  ///
  /// `/send` flips `queued` to `sent` and is what releases the executable
  /// payload; going straight to the card would work locally but leaves the
  /// server's queue permanently stale. The result is reported even on failure,
  /// because a job stuck in `sent` is invisible to the operator.
  Future<void> _runJob(SimJob queued) async {
    final card = _selected;
    if (card == null || !_vendorConnected) {
      _appendInfo('\u672a\u8fde\u63a5\u8bfb\u5361\u5668\uff0c\u65e0\u6cd5\u6267\u884c\u4efb\u52a1');
      return;
    }
    // The card link is already live: LpadBle.connect() ran with the password
    // when the reader was selected, so the executor only issues card ops.
    final mac = card.device.remoteId.str;
    final service = context.read<AppState>().api;
    if (mounted) setState(() => _runningJob = queued.jobNo);

    SimJob job;
    try {
      job = await service.claimJob(queued.jobNo);
    } catch (e) {
      if (mounted) setState(() => _runningJob = null);
      _appendInfo('\u8ba4\u9886\u5931\u8d25 ${queued.jobNo}\uff1a$e');
      return;
    }

    JobOutcome outcome;
    try {
      final executor = JobExecutor(mac);
      // No onProgress: the job log is silent by design. The progress ladder is
      // only useful while debugging a specific card, and it used to flood the
      // panel once a minute with lines nobody was reading.
      outcome = await executor.run(job);
    } catch (e) {
      outcome = JobOutcome.failure('\u6267\u884c\u5f02\u5e38\uff1a$e',
          detail: {'job_no': job.jobNo});
    } finally {
      // The executor owns its own transport; never leave it half-open.
    }

    try {
      await service.reportJob(
        job.jobNo,
        ok: outcome.ok,
        message: outcome.message,
        detail: outcome.detail,
      );
      // Successful background reads are silent: they run every minute and the
      // result is already on the server. Only failures are worth a log line.
      if (!outcome.ok) {
        _appendInfo('\u4efb\u52a1\u5931\u8d25\u5df2\u4e0a\u62a5 ${job.jobNo}\uff1a${outcome.message}');
      }
    } catch (e) {
      _appendInfo('\u7ed3\u679c\u4e0a\u62a5\u5931\u8d25 ${job.jobNo}\uff1a$e');
    }

    if (mounted) setState(() => _runningJob = null);
  }

  Widget _profileTile(ProfileSummary p) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: p.isEnabled
                        ? const Color(0xFFE6F7E6)
                        : const Color(0xFFF0F0F0),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    p.isEnabled ? t.cwEnabled : t.cwDisabled,
                    style: TextStyle(
                      fontSize: 10,
                      color: p.isEnabled
                          ? const Color(0xFF389E0D)
                          : Colors.grey[600],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    p.profileName.isNotEmpty ? p.profileName : p.nickname,
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text('ICCID ${p.iccid}',
                style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey[500],
                    fontFamily: 'monospace')),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              children: [
                if (!p.isEnabled)
                  _chip(t.cwEnable,
                      () => _profileAction(VendorProfileOp.enable, t.cwEnable, p.iccid,
                          (l) => l.enableProfile(p.iccid))),
                if (p.isEnabled)
                  _chip(t.cwDisable,
                      () => _profileAction(VendorProfileOp.disable, t.cwDisable, p.iccid,
                          (l) => l.disableProfile(p.iccid))),
                _chip(t.cwRename, () => _rename(p)),
                _chip(t.cwDelete, () {
                  _confirmThen(
                    t.cwDelete,
                    t.cwDeleteConfirmIccid(p.iccid),
                    () => _profileAction(VendorProfileOp.delete, t.cwDelete, p.iccid,
                        (l) => l.deleteProfile(p.iccid)),
                  );
                }),
              ],
            ),
          ],
        ),
      );

  // --------------------------------------------------------------- pieces

  /// Numbered step panel: the whole page reads top-to-bottom in three moves.
  Widget _panel({
    required int step,
    required String title,
    required String subtitle,
    required Widget child,
  }) =>
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: Color(0xFF1677FF),
                    shape: BoxShape.circle,
                  ),
                  child: Text('$step',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.only(left: 30),
              child: Text(subtitle,
                  style: TextStyle(fontSize: 11, color: Colors.grey[600])),
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      );

  /// A banner that can be copied out.
  ///
  /// Every failure the user has reported so far arrived as a screenshot of one
  /// line, which is why diagnosis took rounds. Copying puts the full text --
  /// including the protocol-probe evidence -- one paste away.
  /// Structured failure, laid out like the SDK demo's error screen: a clear
  /// headline, a sentence saying what it means, and the codes an operator will
  /// ask for -- with copy buttons, because support requests are pasted, not
  /// retyped from a photo of the screen.
  Widget _errorCardWidget(ErrorMessages m) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF1F0),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFFFCCC7)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2, right: 8),
                  child: Icon(Icons.error_outline,
                      size: 18, color: Color(0xFFCF1322)),
                ),
                Expanded(
                  child: Text(
                    m.title,
                    style: const TextStyle(
                      color: Color(0xFFCF1322),
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              m.bodyText,
              style: const TextStyle(
                  color: Color(0xFF5C1B15), fontSize: 12.5, height: 1.5),
            ),
            if (m.errorDetails != null && m.errorDetails!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  m.errorDetails!,
                  style: const TextStyle(
                    color: Color(0xFF7A2E27),
                    fontSize: 11.5,
                    height: 1.55,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (m.errorDetails != null && m.errorDetails!.isNotEmpty)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: const Color(0xFFCF1322),
                    ),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(
                        text: '${m.title}\n${m.bodyText}\n${m.errorDetails}',
                      ));
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(t.cwCopied)));
                    },
                    icon: const Icon(Icons.copy_all, size: 14),
                    label: Text(t.cwCopyError,
                        style: TextStyle(fontSize: 11)),
                  ),
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: const Color(0xFF8C8C8C),
                  ),
                  onPressed: () => setState(() => _errorCard = null),
                  child: Text(t.cwClose, style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _banner(String text, Color bg, Color fg, {bool copy = false}) =>      Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(10, 10, 6, 6),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text,
                style: TextStyle(color: fg, fontSize: 12, height: 1.45)),
            if (copy)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: fg,
                  ),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: text));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(t.cwCopiedForSupport)));
                  },
                  icon: const Icon(Icons.copy_all, size: 14),
                  label: Text(t.cwCopy, style: TextStyle(fontSize: 11)),
                ),
              ),
          ],
        ),
      );

  Widget _chip(String label, VoidCallback onTap) => InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFDDDDDD)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(label, style: const TextStyle(fontSize: 11)),
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 74,
              child: Text(k,
                  style: TextStyle(fontSize: 11, color: Colors.grey[500])),
            ),
            Expanded(
                child: Text(v,
                    style: const TextStyle(
                        fontSize: 11, fontFamily: 'monospace'))),
          ],
        ),
      );

  double _stageFraction(DownloadStage stage) {
    switch (stage) {
      case DownloadStage.connecting:
        return 0.05;
      case DownloadStage.readingCard:
        return 0.15;
      case DownloadStage.initiateAuthentication:
        return 0.3;
      case DownloadStage.authenticateServer:
        return 0.4;
      case DownloadStage.authenticateClient:
        return 0.5;
      case DownloadStage.prepareDownload:
        return 0.6;
      case DownloadStage.getBoundProfilePackage:
        return 0.7;
      case DownloadStage.loadBoundProfilePackage:
        return 0.85;
      case DownloadStage.done:
        return 1;
      case DownloadStage.failed:
        return 0;
    }
  }
}

/// Activation-code QR scanner, kept local to this page.
class _QrScanPage extends StatefulWidget {
  const _QrScanPage();

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  /// Local accessor: this State is a separate widget, so the outer screen's
  /// `t` is not in scope here.
  L get t => context.read<AppState>().t;

  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t.cwScanQrTitle)),
      body: MobileScanner(
        controller: _controller,
        onDetect: (capture) {
          if (_done) return;
          for (final b in capture.barcodes) {
            final raw = b.rawValue;
            if (raw != null && raw.isNotEmpty) {
              _done = true;
              Navigator.of(context).pop(raw);
              return;
            }
          }
        },
      ),
    );
  }
}

