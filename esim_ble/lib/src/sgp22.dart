/// Generic SGP.22 engine on top of any [EuiccTransport].
///
/// This is the device-independent half of the protocol: it builds the APDUs,
/// handles 61XX/6CXX, and exposes ES10b/ES10c operations. Because it only talks
/// APDUs, the same code drives
///
///   * the 9eSIM BLE reader            ([Esim9BleTransport])
///   * a Linksfield card in APDU mode  (any transport that maps to eUICC APDUs)
///   * a USB CCID / PC/SC reader       (a host-side transport)
///   * the phone's built-in eSIM slot  (OMAPI / Telephony transport)
///
/// `lpa.dart` keeps the per-operation methods (challenge, authenticate, load,
/// list profiles); this class owns the session: opening ISD-R, framing ES10x
/// segments, and the GET RESPONSE loop.
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'constants.dart';
import 'euicc_transport.dart';

/// Raised when the card rejects an APDU or the session is misused.
class EuiccError implements Exception {
  final String message;
  final int? sw;
  EuiccError(this.message, [this.sw]);
  @override
  String toString() => sw == null
      ? 'EuiccError: $message'
      : 'EuiccError: $message (SW=0x${sw!.toRadixString(16).padLeft(4, '0').toUpperCase()})';
}

/// One open eUICC session over a transport.
class EuiccSession {
  /// The device underneath. Protected so test doubles can observe the APDUs
  /// that were actually sent.
  @protected
  final EuiccTransport transport;

  /// Logical channel carrying ISD-R. 0 means the basic channel.
  int channel = 0;

  bool _isdrSelected = false;
  bool _opened = false;

  EuiccSession(this.transport);

  bool get isOpen => _opened;
  bool get isIsdrSelected => _isdrSelected;

  /// Logical channels this session opened, newest last. Closing them by hand
  /// matters: the firmware keeps a channel open until told otherwise, and a
  /// leaked channel makes the *next* connection fail to select ISD-R.
  final List<int> _ownedChannels = [];

  /// Channel carrying the ISD-R-notification applet, or null when the
  /// transport only offers a single channel (or only the basic one).
  int? notificationChannel;

  /// When true, ES10x commands go to the basic channel and no logical channel
  /// is opened. Set by callers that must not leave channel state behind on a
  /// card they do not own (the standalone writer tool).
  bool preferBasicChannel = false;

  /// Connects, then opens/maintains a channel to ISD-R.
  ///
  /// The AID is selected on the channel the card hands back, because a bare
  /// SELECT on the basic channel is rejected by some cards while others only
  /// work that way. MANAGE CHANNEL first, fall back to channel 0.
  Future<void> open() async {
    await transport.open();
    _opened = true;

    if (preferBasicChannel) {
      final sel = await transmit(_selectApdu(isdrAid, 0));
      if (sel.sw1 == 0x90 || sel.sw1 == 0x61) {
        channel = 0;
        _isdrSelected = true;
        return;
      }
      throw EuiccError('基础通道上选择 ISD-R 失败', sel.sw);
    }

    try {
      final ch = await transport.openChannel(isdrAid);
      channel = ch;
      if (ch != 0) _ownedChannels.add(ch);
      final sel = await transmit(_selectApdu(isdrAid, ch));
      if (sel.sw1 != 0x90 && sel.sw1 != 0x61) {
        throw EuiccError('ISD-R 选择失败', sel.sw);
      }
      _isdrSelected = true;
    } on TransportError {
      rethrow;
    } catch (e) {
      // A transport that already selected ISD-R during open() lands here.
      // Confirm by a status probe before giving up.
      final probe = await transmit(_selectApdu(isdrAid, 0));
      if (probe.sw1 == 0x90 || probe.sw1 == 0x61) {
        channel = 0;
        _isdrSelected = true;
      } else {
        throw EuiccError('无法打开 ISD-R 逻辑通道: $e', probe.sw);
      }
    }

    notificationChannel = await _openNotificationChannel();
  }

  /// Opens a second channel to the ISD-R-notification applet.
  ///
  /// Both applets answer to the same AID prefix (`A0…10`); the notification
  /// one only differs in the trailing instance bytes, and several card
  /// vendors accept the ISD-R AID itself and route on the applet selected
  /// afterwards. A card that keeps one session cannot do this at all, which is
  /// why the failure is swallowed rather than surfaced: notifications are the
  /// only thing that needs it.
  Future<int?> _openNotificationChannel() async {
    try {
      final ch = await transport.addChannel(isdrAid);
      if (ch == 0 || _ownedChannels.contains(ch)) return null;
      _ownedChannels.add(ch);
      return ch;
    } catch (_) {
      return null;
    }
  }

  /// Sends one APDU, retrying once on 6CXX (wrong Le).
  Future<ApduResponse> transmit(Uint8List apdu) async {
    var rsp = await transport.transmit(apdu);
    if (rsp.wrongLength && apdu.isNotEmpty) {
      final fixed = Uint8List.fromList(apdu)..[apdu.length - 1] = rsp.sw2;
      rsp = await transport.transmit(fixed);
    }
    return rsp;
  }

  /// Runs one ES10x command: segment the DER body, concatenate responses.
  ///
  /// Mirrors lpac's `es10x_command`: `CLA=0x80|channel`, `INS=0xE2`,
  /// `P1=0x11` for non-final / `0x91` for final segment, `P2` = segment index,
  /// 120-byte segments. A 61XX answer means "more data" and is drained with
  /// GET RESPONSE before the next segment.
  Future<Uint8List> es10x(Uint8List der) async {
    return _es10xOn(der, channel);
  }

  /// Runs an ES10x command on [ch] instead of the ISD-R channel.
  ///
  /// Same framing; only the CLA low nibble and the GET RESPONSE channel
  /// change. Used for the notification applet, which must not be addressed on
  /// the channel that carries ES10b profile operations.
  Future<Uint8List> es10xOnChannel(Uint8List der, int ch) async {
    return _es10xOn(der, ch);
  }

  Future<Uint8List> _es10xOn(Uint8List der, int ch) async {
    final out = BytesBuilder();
    var offset = 0;
    var seq = 0;

    do {
      final remaining = der.length - offset;
      final isLast = remaining <= es10xMss;
      final len = isLast ? remaining : es10xMss;
      final chunk = Uint8List.sublistView(der, offset, offset + len);

      final rsp = await transmit(_es10xApdu(isLast ? 0x91 : 0x11, seq, chunk, ch));

      if (rsp.isOk) {
        out.add(rsp.data);
      } else if (rsp.hasMoreData) {
        out.add(rsp.data);
        out.add(await _getResponseOn(rsp.sw2, ch));
      } else {
        throw EuiccError('ES10x 命令在第 $seq 段被拒绝', rsp.sw);
      }

      offset += len;
      seq++;
    } while (offset < der.length);

    return out.toBytes();
  }

  /// Drains a 61XX chain.
  Future<Uint8List> getResponse(int le) => _getResponseOn(le, channel);

  Future<Uint8List> _getResponseOn(int le, int ch) async {
    final out = BytesBuilder();
    var cur = le;
    var guard = 0;
    while (cur > 0) {
      if (guard++ > 64) throw EuiccError('GET RESPONSE 循环');
      final rsp = await transmit(_getResponseApdu(cur, ch));
      out.add(rsp.data);
      if (!rsp.hasMoreData) {
        if (!rsp.isOk && rsp.sw1 != 0x90) {
          throw EuiccError('GET RESPONSE 失败', rsp.sw);
        }
        break;
      }
      cur = rsp.sw2;
    }
    return out.toBytes();
  }

  Future<void> close() async {
    // Close the notification channel first: it was opened last, and a
    // single-handle firmware gets confused if the first channel disappears
    // from under the second.
    for (final ch in _ownedChannels.reversed) {
      try {
        await transport.closeChannel(ch);
      } catch (_) {
        // The link teardown below releases it anyway.
      }
    }
    _ownedChannels.clear();
    notificationChannel = null;
    await transport.close();
    _opened = false;
    _isdrSelected = false;
  }

  // ------------------------------------------------------------- APDU build

  Uint8List _es10xApdu(int p1, int p2, Uint8List chunk, int ch) {
    final cla = (0x80 & 0xF0) | (ch & 0x0F);
    final out = Uint8List(5 + chunk.length);
    out[0] = cla;
    out[1] = 0xE2;
    out[2] = p1;
    out[3] = p2;
    out[4] = chunk.length;
    out.setRange(5, out.length, chunk);
    return out;
  }

  Uint8List _getResponseApdu(int le, int ch) {
    final cla = (0x80 & 0xF0) | (ch & 0x0F);
    return Uint8List.fromList([cla, 0xC0, 0x00, 0x00, le & 0xFF]);
  }

  Uint8List _selectApdu(Uint8List aid, int ch) {
    // 00 A4 04 00 <Lc> <AID>, with the channel ORed into CLA.
    final cla = (0x00 & 0xF0) | (ch & 0x0F);
    final out = Uint8List(5 + aid.length);
    out[0] = cla;
    out[1] = 0xA4;
    out[2] = 0x04;
    out[3] = 0x00;
    out[4] = aid.length;
    out.setRange(5, out.length, aid);
    return out;
  }
}
