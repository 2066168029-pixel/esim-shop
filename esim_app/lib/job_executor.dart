/// Executes a card-writer job rendered by the backend.
///
/// The server owns *what* to do (which activation code, which ICCID, which
/// read-backs); the phone owns *how*, because ES10x is a multi-round-trip
/// protocol that needs the card in hand. This class is the join point:
///
///   claim  ->  SimJob (payload with steps + activation code)
///   run    ->  card I/O, replay the steps
///   report ->  {ok, message, detail{iccid,...}} back to the server
///
/// Deliberate design choices:
///
///  * A job is **claimed before any card I/O**. The server flips `queued` to
///    `sent` and only then releases the activation code, so a phone cannot
///    consume a code the operator has not released.
///  * The result is always reported, including on failure. A job left `sent`
///    forever is worse than a failed job -- the operator can react to the
///    latter but not to a stuck queue.
///  * Card I/O goes through the **vendor SDK** (`LpadBle`), not the in-tree
///    Dart stack. The deployed readers need the vendor secure-channel
///    handshake, which takes a card password; the Dart transport
///    (`openAnyTransport` -> `LinksfieldTransport`) has no password entry, so
///    it sends one chunk and the card never answers ("卡一个字节都没回").
///    The write screen already drives `LpadBle`, so both paths now agree.
library;

import 'api.dart';
import 'lpad_ble.dart' as vendor;

/// Called as the job moves through its steps. [detail] is user-facing.
typedef JobProgress = void Function(String stage, String detail);

/// What the executor did, ready to post to `/api/sim/jobs/{no}/result`.
class JobOutcome {
  final bool ok;
  final String message;
  final Map<String, dynamic> detail;

  const JobOutcome({required this.ok, this.message = '', this.detail = const {}});

  static JobOutcome failure(String message, {Map<String, dynamic> detail = const {}}) =>
      JobOutcome(ok: false, message: message, detail: detail);
}

class JobExecutor {
  /// MAC of the already-connected reader.
  ///
  /// The card link must be established by the caller (`LpadBle.connect` with
  /// the password), exactly like the write screen does before it reads
  /// profiles. This class only issues card operations on that live link.
  final String mac;

  JobExecutor(this.mac);

  /// Run [job] (already claimed -- it carries its own payload).
  Future<JobOutcome> run(SimJob job, {JobProgress? onProgress}) async {
    switch (job.action) {
      case 'write':
        return _runWrite(job, onProgress);
      case 'read_info':
        return _runReadInfo(job, onProgress);
      case 'revoke':
        return _runRevoke(job, onProgress);
      case 'switch':
        return _runSwitch(job, onProgress);
      default:
        return JobOutcome.failure('不支持的作业类型：${job.action}',
            detail: {'job_no': job.jobNo});
    }
  }

  /// `LpadBle.download` blocks on the native side for the whole write.
  Future<JobOutcome> _runWrite(SimJob job, JobProgress? onProgress) async {
    final code = job.activationCode;
    if (code.isEmpty) {
      return JobOutcome.failure('作业缺少激活码（LPA:1\$...），无法写卡',
          detail: {'job_no': job.jobNo});
    }

    try {
      onProgress?.call('write', '正在下载并写入 profile…');
      final result = await vendor.LpadBle.download(code);

      if (result.resultCode != 0) {
        return JobOutcome.failure(
          '写卡失败（resultCode=${result.resultCode}）',
          detail: {
            'job_no': job.jobNo,
            'iccid': result.iccid,
            'result_code': result.resultCode,
          },
        );
      }

      // The server refuses a write whose read-back does not match the ICCID it
      // rendered, so report what actually landed rather than what was intended.
      final expected = job.expectedIccid;
      if (expected.isNotEmpty && result.iccid.isNotEmpty && expected != result.iccid) {
        return JobOutcome.failure(
          '写卡 ICCID 不匹配：期望 $expected，实际 ${result.iccid}',
          detail: {
            'job_no': job.jobNo,
            'iccid': result.iccid,
            'expected_iccid': expected,
          },
        );
      }

      onProgress?.call('refresh', '正在刷新卡片状态…');
      try {
        await vendor.LpadBle.resetDevice();
      } catch (_) {}

      return JobOutcome(
        ok: true,
        message: '已写入 profile ${result.iccid}',
        detail: {
          'job_no': job.jobNo,
          'iccid': result.iccid,
          'result_code': result.resultCode,
        },
      );
    } catch (e) {
      return JobOutcome.failure('写卡失败：$e', detail: {'job_no': job.jobNo});
    }
  }

  Future<JobOutcome> _runReadInfo(SimJob job, JobProgress? onProgress) async {
    try {
      onProgress?.call('eid', '正在读取 EID…');
      final eid = await vendor.LpadBle.eid() ?? '';

      onProgress?.call(
          'profiles', 'EID ${eid.isEmpty ? "未知" : eid}，正在读 profile 列表…');
      final profiles = await vendor.LpadBle.listProfiles();

      // ES10b GetEuiccInfo2 carries the card's remaining non-volatile memory.
      // Reported alongside the profiles so the dashboard can show real storage
      // headroom instead of guessing a slot count.
      Map<String, String> cardInfo = const {};
      try {
        final pairs = await vendor.LpadBle.euiccInfo();
        cardInfo = {
          for (final p in pairs)
            if ((p['label'] ?? '').isNotEmpty) p['label']!: p['value'] ?? '',
        };
      } catch (_) {
        // Info is optional; a card that declines it must not fail the read.
      }

      return JobOutcome(
        ok: true,
        message: '读取到 ${profiles.length} 个 profile',
        detail: {
          'eid': eid,
          'card_info': cardInfo,
          'profiles': [
            for (final p in profiles)
              {
                'iccid': p.iccid,
                'nickname': p.nickname,
                'profile_name': p.profileName,
                'service_provider': p.serviceProvider,
                'state': p.state,
              }
          ],
          'job_no': job.jobNo,
        },
      );
    } catch (e) {
      return JobOutcome.failure('读取卡信息失败：$e', detail: {'job_no': job.jobNo});
    }
  }

  Future<JobOutcome> _runRevoke(SimJob job, JobProgress? onProgress) async {
    final iccid = (job.meta['iccid'] ?? '').toString();
    if (iccid.isEmpty) {
      return JobOutcome.failure('作业缺少 ICCID，无法删除 profile',
          detail: {'job_no': job.jobNo});
    }

    try {
      // An enabled profile is refused by the eUICC; the delete then fails with
      // a result code that reads like "the card ignored me". Disable first.
      final profiles = await vendor.LpadBle.listProfiles();
      final match = profiles.where((p) => p.iccid == iccid).toList();
      if (match.isNotEmpty && match.first.isEnabled) {
        onProgress?.call('disable', '正在停用 $iccid…');
        final disableCode = await vendor.LpadBle.disable(iccid);
        if (disableCode != 0) {
          return JobOutcome.failure('停用失败（resultCode=$disableCode）',
              detail: {'iccid': iccid, 'job_no': job.jobNo});
        }
        try {
          await vendor.LpadBle.resetDevice();
        } catch (_) {}
      }

      onProgress?.call('revoke', '正在删除 profile $iccid…');
      final code = await vendor.LpadBle.delete(iccid);
      if (code != 0) {
        return JobOutcome.failure('删除失败（resultCode=$code）',
            detail: {'iccid': iccid, 'job_no': job.jobNo});
      }

      // Confirm the card agrees; a 0 result is not proof.
      try {
        await vendor.LpadBle.resetDevice();
      } catch (_) {}
      final after = await vendor.LpadBle.listProfiles();
      if (after.any((p) => p.iccid == iccid)) {
        return JobOutcome.failure('删除未生效：卡上仍然存在该 profile',
            detail: {'iccid': iccid, 'job_no': job.jobNo});
      }

      return JobOutcome(
        ok: true,
        message: '已删除 profile $iccid',
        detail: {'iccid': iccid, 'job_no': job.jobNo},
      );
    } catch (e) {
      return JobOutcome.failure('删除失败：$e',
          detail: {'iccid': iccid, 'job_no': job.jobNo});
    }
  }

  Future<JobOutcome> _runSwitch(SimJob job, JobProgress? onProgress) async {
    final iccid = (job.meta['iccid'] ?? '').toString();
    if (iccid.isEmpty) {
      return JobOutcome.failure('作业缺少 ICCID，无法切换 profile',
          detail: {'job_no': job.jobNo});
    }

    try {
      onProgress?.call('switch', '正在启用 profile $iccid…');
      final code = await vendor.LpadBle.enable(iccid);
      if (code != 0) {
        return JobOutcome.failure('启用失败（resultCode=$code）',
            detail: {'iccid': iccid, 'job_no': job.jobNo});
      }

      try {
        await vendor.LpadBle.resetDevice();
      } catch (_) {}

      return JobOutcome(
        ok: true,
        message: '已启用 profile $iccid',
        detail: {'iccid': iccid, 'job_no': job.jobNo},
      );
    } catch (e) {
      return JobOutcome.failure('切换失败：$e',
          detail: {'iccid': iccid, 'job_no': job.jobNo});
    }
  }
}
