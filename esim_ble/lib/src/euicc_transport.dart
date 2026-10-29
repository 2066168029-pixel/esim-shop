/// Transport abstraction for eUICC cards.
///
/// Everything above this layer (ES10b/ES10c in `lpa.dart`, ES9+ in
/// `smdp_client.dart`, the download orchestrator) is plain SGP.22 and does not
/// care how the APDU reaches the card. Only three things differ per device:
///
///   1. how to bring the card up / down          ([EuiccTransport.open])
///   2. how to send one APDU                      ([EuiccTransport.transmit])
///   3. how to open/close a logical channel to ISD-R
///
/// That is the whole interface. A BLE reader, a USB CCID reader, the phone's
/// built-in eSIM slot and a Linksfield protobuf bridge all implement it, and the
/// same [Lpa] instance then drives any of them.
///
/// Why an APDU-level interface rather than "send me a profile":
/// ES10x is multi-round-trip (challenge -> authenticateServer ->
/// authenticateClient -> getBoundProfilePackage -> LoadBoundProfilePackage with
/// 120-byte segments and 61XX GET RESPONSE). Deciding those steps on the device
/// is the only thing that works everywhere; a transport that only accepted
/// pre-rendered byte streams would need a per-vendor bridge on the server.
library;

import 'dart:typed_data';

/// A response to one APDU.
class ApduResponse {
  /// Data payload without the status word.
  final Uint8List data;

  /// Status word, e.g. 0x9000 for success.
  final int sw;

  ApduResponse(this.data, this.sw);

  int get sw1 => (sw >> 8) & 0xFF;
  int get sw2 => sw & 0xFF;

  /// True for 9000.
  bool get isOk => sw == 0x9000;

  /// True for 61XX -- the card has more data, issue GET RESPONSE.
  bool get hasMoreData => sw1 == 0x61;

  /// True for 6CXX -- wrong Le, re-issue with the length in SW2.
  bool get wrongLength => sw1 == 0x6C;

  @override
  String toString() =>
      'ApduResponse(${data.length}B, SW=0x${sw.toRadixString(16).padLeft(4, '0').toUpperCase()})';
}

/// Raised when a transport cannot reach or talk to a card.
class TransportError implements Exception {
  final String message;
  final Object? cause;
  TransportError(this.message, [this.cause]);
  @override
  String toString() => cause == null ? 'TransportError: $message'
      : 'TransportError: $message ($cause)';
}

/// One physical/logical path to an eUICC.
abstract class EuiccTransport {
  /// Stable identifier for diagnostics ("9esim-ble", "pcsc", "phone", ...).
  String get kind;

  /// True once [open] has completed successfully.
  bool get isOpen;

  /// Brings the card up and puts it in a state where APDUs can flow.
  ///
  /// Implementations that need to select the ISD-R on the basic channel, reset
  /// the card, or run a reader-specific handshake do it here. Afterwards
  /// [openChannel] must work.
  Future<void> open();

  /// Sends one APDU (header already includes CLA/INS/P1/P2/P3/data).
  ///
  /// Implementations must NOT interpret the APDU: 61XX handing is done by the
  /// caller ([Lpa]), because the required GET RESPONSE framing is identical
  /// everywhere and keeping it in one place avoids divergent retry logic.
  ///
  /// [apdu] is the raw command bytes: CLA INS P1 P2 [Lc data] [Le].
  Future<ApduResponse> transmit(Uint8List apdu);

  /// Opens a logical channel to [aid] and returns the channel number (1..19).
  ///
  /// Transports that only expose a single session (phone eSIM slot, some
  /// readers) may return 0 to mean "use the basic channel".
  Future<int> openChannel(Uint8List aid);

  /// Closes [channel], if the transport supports it.
  /// Whether [channel] can still carry APDUs.
  Future<void> closeChannel(int channel);

  /// Releases the connection and any reader-side resources.
  Future<void> close();

  /// Human-readable description for the UI (device name, reader slot, ...).
  String get description;

  /// Opens a **second** logical channel to [aid] while earlier ones stay open.
  ///
  /// Needed for a dual-path card: the eUICC applet sits on the ISD-R channel,
  /// while ES10 notifications are retrieved from the ISD-R-notification applet
  /// on a channel of its own. Firmware that exposes a single card handle (the
  /// Linksfield protobuf card) cannot do this and throws [UnsupportedError];
  /// callers then fall back to [openChannel].
  Future<int> addChannel(Uint8List aid) =>
      throw UnsupportedError('$kind does not support a second logical channel');

  /// Closes [channel] on the card itself (ISO 7816-4 MANAGE CHANNEL, 00 70 80).
  ///
  /// Distinct from [closeChannel], which is the vendor's own close request and
  /// on some firmware only releases the helper's bookkeeping. Channels that
  /// were opened by a separate tool session must be closed here, or the next
  /// session finds the card with no free channel.
  Future<bool> closeChannelOnCard(int channel) async {
    await closeChannel(channel);
    return true;
  }
}
