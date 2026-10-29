// Port of the vendor SDK demo's error decoding
// (ui/download/CodeUtils.kt + EuiccCode.kt + DetailedErrorMessageUtils.kt).
//
// The reason this file exists
// ---------------------------
// `LPAdClient.onDownloadSubscription` does NOT return a small enum. It returns
// the platform's *detailed code*, a packed integer:
//
//     bits 31..24  operationCode   (1..12)
//     bits 23..0   errorCode       (10000..10017)  -- unless op == 10 below
//
// and when operationCode == 10 (SMDX_SUBJECT_REASON_CODE) those low 24 bits are
// not an error code at all but six 4-bit nibbles: two 12-bit GSMA codes, read as
// subjectCode and reasonCode.
//
// Reading it as "1 = invalid code, 2 = not found ..." -- which is what the first
// version of the bridge did -- maps every real failure to the wrong message.
// E.g. a full card is 0x03002714, whose low bits are 10004; treating it as a
// small enum reports "profile install error" instead of "not enough space".
//
// Codes are kept identical to the vendor's so a support engineer can match our
// output against the SDK demo line for line.

/// What kind of operation produced the failure. Mirrors `OperationCode`.
enum OperationCode {
  system(1),
  simSlot(2),
  euiccCard(3),
  switchProfile(4),
  download(5),
  metadata(6),
  euiccGsma(7),
  apdu(8),
  smdx(9),

  /// Low 24 bits are a subject/reason pair, not an error code.
  smdxSubjectReason(10),
  http(11),
  notification(12);

  const OperationCode(this.value);
  final int value;

  static OperationCode? fromValue(int v) {
    for (final o in OperationCode.values) {
      if (o.value == v) return o;
    }
    return null;
  }
}

/// Mirrors `ErrorCode`. Not exhaustive on purpose -- the vendor handles the same
/// subset plus a fallback, and inventing meanings for the rest would be worse
/// than saying "report this to the operator".
abstract final class EuiccErrorCode {
  static const int carrierLocked = 10000;
  static const int invalidActivationCode = 10001;
  static const int invalidConfirmationCode = 10002;
  static const int incompatibleCarrier = 10003;
  static const int euiccInsufficientMemory = 10004;
  static const int timeout = 10005;
  static const int euiccMissing = 10006;
  static const int unsupportedVersion = 10007;
  static const int simMissing = 10008;
  static const int installProfile = 10009;
  static const int disallowedByPpr = 10010;
  static const int addressMissing = 10011;
  static const int certificateError = 10012;
  static const int noProfilesAvailable = 10013;
  static const int connectionError = 10014;
  static const int invalidResponse = 10015;
  static const int operationBusy = 10016;
  static const int invalidPort = 10017;
}

/// One decoded detailed code.
class DetailedCode {
  final int raw;
  final OperationCode? operation;
  final int errorCode;

  /// Set only when [operation] is [OperationCode.smdxSubjectReason].
  final String? subjectCode;
  final String? reasonCode;

  const DetailedCode({
    required this.raw,
    required this.operation,
    required this.errorCode,
    this.subjectCode,
    this.reasonCode,
  });

  /// Splits the packed integer. Mirrors `extractErrorCode`.
  factory DetailedCode.parse(int detailedCode) {
    final op = OperationCode.fromValue((detailedCode >> 24) & 0xFF);
    if (op == OperationCode.smdxSubjectReason) {
      final pair = _decodeSmdxSubjectAndReason(detailedCode);
      return DetailedCode(
        raw: detailedCode,
        operation: op,
        errorCode: 0,
        subjectCode: pair.$1,
        reasonCode: pair.$2,
      );
    }
    return DetailedCode(
      raw: detailedCode,
      operation: op,
      errorCode: detailedCode & 0xFFFFFF,
    );
  }

  /// Raw nibbles -> "8.2.7" / "6.4". Mirrors `decodeSmdxSubjectAndReasonCode`.
  ///
  /// Six 4-bit sections are read back-to-front; the first three form the subject
  /// and the last three the reason. Leading "0." groups are stripped so 0.0.3
  /// prints as "3".
  static (String, String) _decodeSmdxSubjectAndReason(int resultCode) {
    var code = resultCode;
    final sections = <int>[];
    for (var i = 0; i < 6; i++) {
      sections.insert(0, code & 0xF);
      code >>= 4;
    }
    var subject = '${sections[0]}.${sections[1]}.${sections[2]}';
    var reason = '${sections[3]}.${sections[4]}.${sections[5]}';
    subject = subject.replaceFirst(RegExp(r'^(0\.)*'), '');
    reason = reason.replaceFirst(RegExp(r'^(0\.)*'), '');
    return (subject, reason);
  }

  @override
  String toString() => operation == OperationCode.smdxSubjectReason
      ? 'DetailedCode(0x${raw.toRadixString(16)}, subject=$subjectCode reason=$reasonCode)'
      : 'DetailedCode(0x${raw.toRadixString(16)}, op=${operation?.name} '
          'error=$errorCode)';
}

/// What the user should see. Matches `ErrorMessages` in the vendor demo.
class ErrorMessages {
  final String title;
  final String bodyText;
  final String? errorDetails;

  /// Technical line for support, shown only when [_isTechnical] is on.
  final String? technical;

  const ErrorMessages({
    required this.title,
    required this.bodyText,
    this.errorDetails,
    this.technical,
  });

  /// One block of text for places that only render a string.
  String get fullText => [
        title,
        bodyText,
        if (errorDetails != null && errorDetails!.isNotEmpty) errorDetails,
      ].join('\n\n');
}

/// Mirrors `DetailedErrorMessageUtils`. Same branches, same order, so behaviour
/// does not silently diverge from the vendor demo.
class DetailedErrorMessages {
  final String? carrierName;
  final String? csTel;

  const DetailedErrorMessages({this.carrierName, this.csTel});

  /// @param detailedCode the value returned by onDownloadSubscription /
  ///        onGetDownloadableSubscriptionMetadata.
  ErrorMessages forCode(int detailedCode) {
    final d = DetailedCode.parse(detailedCode);

    if (d.operation == OperationCode.smdxSubjectReason) {
      return _smdx(d);
    }
    // HTTP 100-999 is "the network was unreachable", handled before the enum
    // checks, exactly as the vendor does.
    if (d.operation == OperationCode.http &&
        d.errorCode >= 100 &&
        d.errorCode <= 999) {
      return _noConnection(d);
    }
    return _general(d);
  }

  // --------------------------------------------------------------- branches

  ErrorMessages _noConnection(DetailedCode d) => ErrorMessages(
        title: '未连接网络',
        bodyText: '下载 eSIM 需要 Wi-Fi 或移动网络连接。',
        errorDetails: '连接网络后请重试。',
        technical: d.toString(),
      );

  ErrorMessages _general(DetailedCode d) {
    final op = d.operation;
    final err = d.errorCode;

    // Device is carrier-locked -- both switch and download land here.
    if ((op == OperationCode.switchProfile || op == OperationCode.download) &&
        err == EuiccErrorCode.carrierLocked) {
      return ErrorMessages(
        title: _carrierTitle,
        bodyText: carrierName == null || carrierName!.isEmpty
            ? '设备已被运营商锁定。'
            : '你的设备被 $carrierName 锁定。',
        errorDetails: _unlockDetails,
        technical: d.toString(),
      );
    }

    // Card is full.
    if (op == OperationCode.euiccGsma &&
        err == EuiccErrorCode.euiccInsufficientMemory) {
      return ErrorMessages(
        title: _carrierTitle,
        bodyText: '卡上空间不足，无法下载这个 eSIM。',
        errorDetails: '请先在卡上删除一个不用的套餐，然后重试。',
        technical: d.toString(),
      );
    }

    // Profile landed but failed to install.
    if (op == OperationCode.euiccGsma && err == EuiccErrorCode.installProfile) {
      return ErrorMessages(
        title: _carrierTitle,
        bodyText: _issueBody,
        errorDetails: _provideInfo(d.operation?.value ?? 0, err),
        technical: d.toString(),
      );
    }

    // Any other raw GSMA failure: op<<16|result, per SGP.22.
    if (op == OperationCode.euiccGsma && (err < 10000 || err > 10017)) {
      final operateCode = (err & 0xFF0000) >> 16;
      final euiccResult = err & 0xFFFF;
      return ErrorMessages(
        title: _carrierTitle,
        bodyText: _issueBody,
        errorDetails: '你可以把这些信息提供给运营商：\n'
            'operateCode: $operateCode\n'
            'euiccResult: $euiccResult',
        technical: d.toString(),
      );
    }

    if (op == OperationCode.notification) {
      return ErrorMessages(
        title: '扫描失败',
        bodyText: _issueBody,
        technical: d.toString(),
      );
    }

    // SM-DX returned one of the well-known failures.
    if (op == OperationCode.smdx &&
        const [
          EuiccErrorCode.noProfilesAvailable,
          EuiccErrorCode.connectionError,
          EuiccErrorCode.certificateError,
          EuiccErrorCode.invalidResponse,
          EuiccErrorCode.invalidConfirmationCode,
        ].contains(err)) {
      return ErrorMessages(
        title: _carrierTitle,
        bodyText: _issueBody,
        errorDetails: _provideInfo(d.operation?.value ?? 0, err),
        technical: d.toString(),
      );
    }

    // The QR itself was wrong -- by far the most common real-world case.
    if (op == OperationCode.metadata &&
        err == EuiccErrorCode.invalidActivationCode) {
      return ErrorMessages(
        title: '二维码无效',
        bodyText: '请确认扫描的是正确的 eSIM 二维码。可以返回重新扫描。',
        errorDetails: '如需帮助，请联系你的运营商。',
        technical: d.toString(),
      );
    }

    if (op == OperationCode.metadata && err == EuiccErrorCode.invalidPort) {
      return ErrorMessages(
        title: '需要连接 Wi-Fi',
        bodyText: '下载 eSIM 需要一个可用的网络连接。',
        errorDetails: '连接网络后请重试。',
        technical: d.toString(),
      );
    }

    return _fallback(d);
  }

  ErrorMessages _smdx(DetailedCode d) {
    final s = d.subjectCode;
    final r = d.reasonCode;

    if (s == '8.1' && r == '4.8') {
      return ErrorMessages(
        title: _carrierTitle,
        bodyText: '卡上空间不足，无法下载这个 eSIM。',
        errorDetails: '请先在卡上删除一个不用的套餐，然后重试。',
        technical: d.toString(),
      );
    }
    // These three mean "the operator rejected the profile"; the exact GSMA
    // meaning does not change what the user should do.
    for (final pair in const [('8.1.1', '3.8'), ('8.2.6', '3.8'), ('8.2.7', '6.4')]) {
      if (s == pair.$1 && r == pair.$2) {
        return ErrorMessages(
          title: _carrierTitle,
          bodyText: _issueBody,
          errorDetails: _provideInfoSmdx(s!, r!),
          technical: d.toString(),
        );
      }
    }
    // This profile is already on the card.
    if (s == '8.2' && r == '1.2') {
      return ErrorMessages(
        title: '套餐已下载',
        bodyText: carrierName == null || carrierName!.isEmpty
            ? '请确认该 eSIM 套餐此前没有被下载过。'
            : '请确认 $carrierName 的这个套餐此前没有被下载过。',
        errorDetails: _provideInfoSmdx(s!, r!),
        technical: d.toString(),
      );
    }
    return _fallback(d);
  }

  ErrorMessages _fallback(DetailedCode d) => ErrorMessages(
        title: '激活失败',
        bodyText: '激活时出现问题。',
        errorDetails: d.operation == OperationCode.smdxSubjectReason
            ? '你可以把这些信息提供给运营商：\n'
                'Subject Code: ${d.subjectCode}\n'
                'Reason Code: ${d.reasonCode}'
            : '你可以把这些信息提供给运营商：\n'
                'Operation Code: ${d.operation?.value}\n'
                'Error Code: ${d.errorCode}',
        technical: d.toString(),
      );

  // ---------------------------------------------------------------- helpers

  String get _carrierTitle => carrierName == null || carrierName!.isEmpty
      ? '无法激活服务'
      : '无法激活 $carrierName';

  String get _issueBody {
    if (carrierName == null || carrierName!.isEmpty) {
      return '这个 eSIM 套餐有问题。请向运营商提供下方信息以解决。';
    }
    return '这个 eSIM 套餐有问题。请联系 $carrierName 并提供下方信息以解决。';
  }

  String get _unlockDetails {
    if (carrierName == null || carrierName!.isEmpty) {
      return '请联系你的运营商，确认设备是否可以解锁。';
    }
    if (csTel == null || csTel!.isEmpty) {
      return '请联系 $carrierName，确认设备是否可以解锁。';
    }
    return '请联系 $carrierName（$csTel），确认设备是否可以解锁。';
  }

  String _provideInfo(int operationCode, int errorCode) =>
      '你可以把这些信息提供给运营商：\n'
      'Operation Code: $operationCode\n'
      'Error Code: $errorCode';

  String _provideInfoSmdx(String subject, String reason) =>
      '你可以把这些信息提供给运营商：\n'
      'Subject Code: $subject\n'
      'Reason Code: $reason';
}
