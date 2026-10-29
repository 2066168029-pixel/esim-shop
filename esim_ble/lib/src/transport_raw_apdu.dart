/// Plain-APDU-over-NUS transport.
///
/// The last-resort dialect: a reader that simply forwards GATT writes to the
/// card and returns its answer on the notify characteristic, with no framing,
/// no protobuf and no JSON. Every eUICC answers ISO 7816 APDUs, so if a reader
/// is "transparent" this is the whole protocol.
///
/// Used by the protocol scan to identify such readers; the SGP.22 engine then
/// drives it exactly like any other transport.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'euicc_transport.dart';
import 'transport_linksfield.dart' show LpadGatt;

class RawApduTransport implements EuiccTransport {
  final BluetoothDevice device;
  final BluetoothCharacteristic rx;
  final BluetoothCharacteristic tx;
  final Duration replyTimeout;

  final _rx = StreamController<Uint8List>.broadcast();
  final _buf = <int>[];
  StreamSubscription<List<int>>? _sub;
  bool _open = false;
  Future<void> _chain = Future.value();

  RawApduTransport._(this.device, this.rx, this.tx, this.replyTimeout);

  /// Connects, discovers the NUS pair, and subscribes before the first write.
  ///
  /// Subscribing first is not optional: the card can answer before `write`
  /// returns, and a broadcast stream drops whatever arrived with no listener.
  static Future<RawApduTransport> connect(
    BluetoothDevice device, {
    Duration replyTimeout = const Duration(seconds: 10),
  }) async {
    if (device.isConnected) {
      try {
        await device.disconnect();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 400));
    }
    await device.connect(timeout: const Duration(seconds: 20), mtu: null);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!device.isConnected && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    await Future.delayed(const Duration(milliseconds: 300));

    final services = await device.discoverServices();
    BluetoothCharacteristic? r;
    BluetoothCharacteristic? t;
    for (final s in services) {
      final su = s.uuid.str.toLowerCase();
      if (su != LpadGatt.service && su != LpadGatt.service32) continue;
      for (final c in s.characteristics) {
        final cu = c.uuid.str.toLowerCase();
        if (cu == LpadGatt.rx) r = c;
        if (cu == LpadGatt.tx) t = c;
      }
    }
    if (r == null || t == null) {
      try {
        await device.disconnect();
      } catch (_) {}
      throw TransportError('没有 NUS 写/通知特征，不是透传读卡器');
    }

    final tr = RawApduTransport._(device, r, t, replyTimeout);
    await tr._subscribe();
    tr._open = true;
    return tr;
  }

  Future<void> _subscribe() async {
    _sub = tx.onValueReceived.listen((v) {
      if (v.isEmpty) return;
      _buf.addAll(v);
      if (!_rx.isClosed) _rx.add(Uint8List.fromList(v));
    });
    await tx.setNotifyValue(true);
    await Future.delayed(const Duration(milliseconds: 250));
  }

  @override
  String get kind => 'raw-apdu';

  @override
  bool get isOpen => _open;

  @override
  String get description =>
      device.platformName.isNotEmpty ? device.platformName : device.remoteId.str;

  @override
  Future<void> open() async {
    // Nothing to negotiate: the transport is usable as soon as it connects.
  }

  /// Writes one APDU and collects until a status word arrives.
  ///
  /// A transparent reader does not tell us where a response ends, so the stop
  /// condition is the status word itself: any response shorter than two bytes
  /// cannot be complete, and SW1/SW2 are whatever the last two bytes are.
  @override
  Future<ApduResponse> transmit(Uint8List apdu) {
    final done = Completer<ApduResponse>();
    _chain = _chain.then((_) async {
      try {
        _buf.clear();
        final chunk = _mtu - 3;
        for (var i = 0; i < apdu.length; i += chunk) {
          final end = (i + chunk) > apdu.length ? apdu.length : i + chunk;
          await rx.write(apdu.sublist(i, end), withoutResponse: false);
          if (end < apdu.length) {
            await Future.delayed(const Duration(milliseconds: 15));
          }
        }

        final deadline = DateTime.now().add(replyTimeout);
        while (_buf.length < 2 && DateTime.now().isBefore(deadline)) {
          await Future.delayed(const Duration(milliseconds: 40));
        }
        if (_buf.length < 2) {
          done.completeError(TransportError(
              '透传读卡器在 ${replyTimeout.inSeconds}s 内没有返回状态字'));
          return;
        }
        // Give a fragmented tail a moment to land, then take what we have.
        await Future.delayed(const Duration(milliseconds: 60));
        final bytes = List<int>.from(_buf);
        final sw = (bytes[bytes.length - 2] << 8) | bytes[bytes.length - 1];
        done.complete(ApduResponse(
          Uint8List.sublistView(Uint8List.fromList(bytes), 0, bytes.length - 2),
          sw,
        ));
      } catch (e, st) {
        if (!done.isCompleted) {
          done.completeError(TransportError('APDU 发送失败: $e', e), st);
        }
      }
    });
    return done.future;
  }

  int _mtu = 23;

  /// Negotiates a larger MTU; a failure is not fatal (23 still works).
  Future<void> negotiateMtu() async {
    try {
      final m = await device.requestMtu(517).timeout(
            const Duration(seconds: 4),
            onTimeout: () => _mtu,
          );
      if (m >= 23) _mtu = m;
    } catch (_) {}
  }

  @override
  Future<int> openChannel(Uint8List aid) async {
    final rsp = await transmit(Uint8List.fromList([0x00, 0x70, 0x00, 0x00, 0x01]));
    if (rsp.isOk && rsp.data.isNotEmpty) return rsp.data.first;
    final sel = Uint8List.fromList([0x00, 0xA4, 0x04, 0x00, aid.length, ...aid, 0x00]);
    final ok = await transmit(sel);
    if (!ok.isOk) throw TransportError('无可用逻辑通道（SELECT SW=0x${ok.sw.toRadixString(16)}）');
    return 1;
  }

  @override
  Future<void> closeChannel(int channel) async {
    if (channel <= 0) return;
    try {
      await transmit(Uint8List.fromList([0x00, 0x70, 0x80, channel & 0xFF, 0x00]));
    } catch (_) {}
  }

  /// A transparent reader has one card session; a second channel would take the
  /// replies meant for the first.
  @override
  Future<int> addChannel(Uint8List aid) =>
      throw UnsupportedError('透传读卡器只有一个卡片会话');

  @override
  Future<bool> closeChannelOnCard(int channel) async {
    if (channel <= 0) return true;
    try {
      final rsp = await transmit(
          Uint8List.fromList([0x00, 0x70, 0x80, channel & 0xFF, 0x00]));
      return rsp.isOk;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> close() async {
    _open = false;
    await _sub?.cancel();
    _sub = null;
    try {
      await tx.setNotifyValue(false);
    } catch (_) {}
    try {
      await device.disconnect();
    } catch (_) {}
    if (!_rx.isClosed) await _rx.close();
  }
}
