/// BLE transport for Linksfield-compatible eSIM cards.
///
/// The card exposes a Nordic UART Service (NUS):
///   service  6e400001-b5a3-f393-e0a9-e50e24dcca9e
///   RX       6e400002-...  (we write commands here)
///   TX       6e400003-...  (we subscribe for notifications)
///
/// Framing. Contrary to what a plain UART bridge would suggest, the firmware
/// does NOT treat the characteristic as a byte stream. Every payload -- in both
/// directions -- is prefixed with a 2-byte big-endian length:
///
///     [ len_hi ][ len_lo ][ ...payload... ]
///
/// On receive the firmware may deliver a message split across several
/// notifications; the first chunk carries the header, subsequent chunks are raw
/// continuation bytes. Total length = header + payload length, verified against
/// the value delivered in the first notification.
///
/// On send, the payload is chunked into (MTU - 3 - 2) byte pieces: the first
/// chunk is preceded by the length header, later chunks are raw.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Well-known GATT identifiers used by the LPAd card firmware.
class LpadGatt {
  static const String service = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const String rx = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
  static const String tx = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
  static const String cccd = '00002902-0000-1000-8000-00805f9b34fb';

  /// Alternative service UUID used by 32-bit card revisions.
  static const String service32 = '1cfde1cc-0000-1000-8000-00805f9b34fb';
}

/// Size of the length prefix in front of every message, in bytes.
///
/// The firmware stores this as a configurable field; 2 is the factory value
/// shipped on the cards we have seen. A 4-byte mode exists but is not used by
/// the stock app, so it is not implemented here.
const int lpadHeaderSize = 2;

class BleCardException implements Exception {
  final String message;
  BleCardException(this.message);
  @override
  String toString() => 'BleCardException: $message';
}

/// A discovered card. [advertisedName] is what the phone shows in the scanner.
class CardDevice {
  final BluetoothDevice device;
  final String name;
  final int rssi;

  CardDevice(this.device, this.name, this.rssi);

  String get id => device.remoteId.str;
}

/// Scans for BLE cards advertising the LPAd service.
///
/// We filter on service UUID rather than name because the advertised name
/// varies by batch ("eSIM", "LPAD", "LPA-xxxx", "BLE-eSIM-xxxxxxxx") while the
/// service UUID is fixed.
class CardScanner {
  StreamSubscription<List<ScanResult>>? _sub;

  /// Emits each newly-seen card once, then keeps the stream open so the UI can
  /// update RSSI. Caller cancels via [stop].
  Stream<CardDevice> scan({Duration timeout = const Duration(seconds: 15)}) {
    final controller = StreamController<CardDevice>();
    final seen = <String>{};

    _sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final id = r.device.remoteId.str;
        if (seen.contains(id)) continue;
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : (r.device.platformName.isNotEmpty ? r.device.platformName : id);
        final hasService = r.advertisementData.serviceUuids.any((u) {
          final s = u.str.toLowerCase();
          return s == LpadGatt.service || s == LpadGatt.service32;
        });
        // Accept by service UUID when advertised; fall back to name match
        // because some firmware revisions omit service data from the adv packet.
        if (!hasService &&
            !name.toUpperCase().contains('ESIM') &&
            !name.toUpperCase().contains('LPA')) {
          continue;
        }
        seen.add(id);
        controller.add(CardDevice(r.device, name, r.rssi));
      }
    });

    FlutterBluePlus.startScan(
      withServices: [Guid(LpadGatt.service)],
      timeout: timeout,
    ).catchError((_) {
      // Some Android builds reject a service filter when the peripheral does
      // not advertise the UUID; retry unfiltered and let the name filter above
      // do the work.
      return FlutterBluePlus.startScan(timeout: timeout);
    });

    Timer(timeout, () {
      if (!controller.isClosed) controller.close();
    });

    controller.onCancel = stop;
    return controller.stream;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await FlutterBluePlus.stopScan();
  }
}

/// An open, connected card. Owns the GATT connection and the framed write path.
class CardConnection {
  final BluetoothDevice device;
  final BluetoothCharacteristic _rx;
  final BluetoothCharacteristic _tx;

  /// Negotiated ATT MTU. Starts at the BLE default and is updated once
  /// requestMtu() completes, mirroring the vendor stack's onMtuChanged handling.
  int _negotiatedMtu = 23;

  int get mtu => _negotiatedMtu;

  /// Bytes accumulated for the message currently being received.
  final _incoming = <int>[];

  /// Total size (header + payload) of the message in progress, or null when we
  /// have not yet seen its header.
  int? _expected;

  StreamSubscription<List<int>>? _notifySub;
  final _responses = StreamController<Uint8List>.broadcast();

  CardConnection._(this.device, this._rx, this._tx, int mtu)
      : _negotiatedMtu = mtu;

  /// Connect, discover the NUS characteristics, and subscribe to TX.
  ///
  /// Retries once on failure: these modules occasionally reject the very first
  /// connection attempt right after advertising starts, and Android caches the
  /// failed GATT, so a clean disconnect + retry clears it.
  static Future<CardConnection> open(
    BluetoothDevice device, {
    String? pin,
  }) async {
    Object? lastError;

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _openOnce(device, pin: pin);
      } catch (e) {
        lastError = e;
        // Make sure the stack tears the half-open GATT down before retrying.
        try {
          await device.disconnect();
        } catch (_) {}
        if (attempt == 0) {
          await Future.delayed(const Duration(seconds: 2));
        }
      }
    }

    throw BleCardException(
      'Could not connect to the card: $lastError',
    );
  }

  static Future<CardConnection> _openOnce(
    BluetoothDevice device, {
    String? pin,
  }) async {
    // The plugin registers an ACTION_PAIRING_REQUEST receiver and answers it
    // with `device.setPin(...)` when a PIN was registered via createBond. That
    // is the only reliable way to pair silently: the OS dialog cannot be driven
    // from Dart, and without a bond this firmware rejects every command.
    if (pin != null && pin.isNotEmpty) {
      try {
        final state = await device.bondState.first;
        if (state != BluetoothBondState.bonded) {
          await device.createBond(
            pin: Uint8List.fromList(pin.codeUnits),
            timeout: 60,
          );
        }
      } catch (e) {
        final after = await device.bondState.first.catchError(
          (_) => BluetoothBondState.none,
        );
        if (after != BluetoothBondState.bonded) {
          throw BleCardException('蓝牙配对失败（密码 $pin）：$e');
        }
      }
    }

    await device.connect(
      timeout: const Duration(seconds: 30),
      mtu: null,
      autoConnect: false,
    );
    // A short settle: some Android stacks report services before the GATT is
    // fully usable right after connect.
    await Future.delayed(const Duration(milliseconds: 350));

    final List<BluetoothService> services;
    try {
      services = await device.discoverServices();
    } catch (e) {
      throw BleCardException('已连接但无法发现服务：$e');
    }

    BluetoothCharacteristic? rx;
    BluetoothCharacteristic? tx;

    // Pass 1: exact match on the documented NUS UUIDs. This is what stock
    // LPAd cards use and it is unambiguous when present.
    for (final s in services) {
      final su = s.uuid.str.toLowerCase();
      if (su != LpadGatt.service && su != LpadGatt.service32) continue;
      for (final c in s.characteristics) {
        final cu = c.uuid.str.toLowerCase();
        if (cu == LpadGatt.rx) rx = c;
        if (cu == LpadGatt.tx) tx = c;
      }
    }

    // Pass 2: match on the 24-character UUID prefix, exactly as the vendor app
    // does (`uuid.substring(0, 24)`). A UUID is 36 chars in canonical form, so
    // this compares the full 32-bit service field plus the 16-bit group field
    // and ignores the trailing node id. Firmware that reuses the NUS contract
    // under a different trailing node id is accepted here.
    if (rx == null || tx == null) {
      for (final s in services) {
        final su = s.uuid.str.toLowerCase();
        if (!_samePrefix(su, LpadGatt.service) &&
            !_samePrefix(su, LpadGatt.service32)) {
          continue;
        }
        for (final c in s.characteristics) {
          final cu = c.uuid.str.toLowerCase();
          if (cu == LpadGatt.rx) rx = c;
          if (cu == LpadGatt.tx) tx = c;
        }
        // Characteristics usually follow the service's own prefix with a
        // changed node id; fall back to their properties when the exact UUIDs
        // are absent.
        if (rx == null || tx == null) {
          for (final c in s.characteristics) {
            final p = c.properties;
            final writable = p.writeWithoutResponse || p.write;
            final notifiable = p.notify || p.indicate;
            if (writable && !notifiable && rx == null) rx = c;
            if (notifiable && !writable && tx == null) tx = c;
          }
        }
      }
    }

    if (rx == null || tx == null) {
      await device.disconnect();
      // Listing what IS there turns a dead end into actionable information.
      final found = services
          .map((s) => '  ${s.uuid.str} (${s.characteristics.length} chars)')
          .join('\n');
      throw BleCardException(
        '这个设备没有暴露 eSIM 卡服务。\n'
        '期望服务: ${LpadGatt.service}\n'
        '实际发现:\n${found.isEmpty ? '(无服务)' : found}',
      );
    }

    // Order matters: the vendor stack subscribes to TX first, waits for the
    // CCCD write to complete, and only then negotiates the MTU (b0.onDescriptorWrite
    // triggers requestMtu(517)). Requesting MTU before the descriptor lands can
    // leave the link at the 23-byte default, which silently truncates writes.
    final conn = CardConnection._(device, rx, tx, 23);
    await conn._subscribe();
    final mtu = await device.requestMtu(517).catchError((_) => 23);
    conn._negotiatedMtu = mtu;
    return conn;
  }

  /// Compares the first 24 characters of two UUIDs, matching the vendor app's
  /// `uuid.substring(0, 24)` service lookup.
  static bool _samePrefix(String a, String b) {
    if (a.length < 24 || b.length < 24) return false;
    return a.substring(0, 24) == b.substring(0, 24);
  }

  Future<void> _subscribe() async {
    await _tx.setNotifyValue(true);
    _notifySub = _tx.onValueReceived.listen(_onChunk);
    // Give the CCCD write time to land before the first request is sent.
    await Future.delayed(const Duration(milliseconds: 150));
  }

  /// Reassembles length-prefixed messages from notification chunks.
  ///
  /// The first notification of a message starts with a 2-byte big-endian
  /// length; continuation notifications are raw. A single notification may
  /// carry the tail of one message plus the head of the next, so this drains in
  /// a loop instead of assuming one message per callback.
  void _onChunk(List<int> chunk) {
    if (chunk.isNotEmpty) _incoming.addAll(chunk);

    // Drain every complete message currently in the buffer.
    while (true) {
      if (_expected == null) {
        // Need at least the length header before we know the boundary.
        if (_incoming.length < lpadHeaderSize) return;
        final payloadLen = _readHeader(_incoming, 0);
        _expected = lpadHeaderSize + payloadLen;
      }

      final expected = _expected!;
      if (_incoming.length < expected) return;

      final message = Uint8List.fromList(
        _incoming.sublist(lpadHeaderSize, expected),
      );
      _incoming.removeRange(0, expected);
      _expected = null;
      _responses.add(message);

      // Loop again: the remainder may hold another complete message.
    }
  }

  /// Reads the big-endian length prefix at [offset].
  static int _readHeader(List<int> data, int offset) {
    if (lpadHeaderSize == 4) {
      return (data[offset] << 24) |
          (data[offset + 1] << 16) |
          (data[offset + 2] << 8) |
          data[offset + 3];
    }
    return (data[offset] << 8) | data[offset + 1];
  }

  /// Bytes of payload that fit in one write.
  ///
  /// The reference implementation sets the chunk size to `negotiatedMtu - 5`
  /// once MTU negotiation completes (onMtuChanged: `f3429n = i2 - 5`), which
  /// accounts for the 3-byte ATT header plus the 2-byte protocol length prefix.
  /// The fixed 512 is only the pre-negotiation value.
  int get _chunkSize {
    final byMtu = mtu - 5;
    if (byMtu < 18) return 18;
    return byMtu > 512 ? 512 : byMtu;
  }

  /// Sends one request frame and waits for the matching response.
  ///
  /// Framing: a 2-byte big-endian length covering the payload, followed by the
  /// payload itself. Only the FIRST write carries that header; continuation
  /// writes are raw payload bytes. This matches the reference implementation,
  /// where the first chunk is sized `512 - headerSize` and later chunks are
  /// full `512`-byte slices.
  Future<Uint8List> request(
    Uint8List payload, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    _incoming.clear();
    _expected = null;

    final chunk = _chunkSize;
    var offset = 0;

    // First write: header + as much payload as fits in one chunk.
    final firstPayloadLen =
        (chunk - lpadHeaderSize).clamp(1, payload.length == 0 ? 1 : payload.length);
    final first = Uint8List(lpadHeaderSize + firstPayloadLen);
    first[0] = (payload.length >> 8) & 0xFF;
    first[1] = payload.length & 0xFF;
    if (firstPayloadLen > 0) {
      first.setRange(lpadHeaderSize, first.length, payload);
    }
    await _rx.write(first, withoutResponse: false);
    offset = firstPayloadLen;

    // Continuation writes: raw slices, no header.
    while (offset < payload.length) {
      final end = (offset + chunk).clamp(0, payload.length);
      await _rx.write(payload.sublist(offset, end), withoutResponse: false);
      offset = end;
    }

    return _responses.stream.first.timeout(
      timeout,
      onTimeout: () => throw BleCardException(
        'The card did not answer within ${timeout.inSeconds}s. '
        'Check that the card is powered and the eSIM is seated properly.',
      ),
    );
  }

  Future<void> close() async {
    await _notifySub?.cancel();
    await _responses.close();
    try {
      await _tx.setNotifyValue(false);
    } catch (_) {
      // The device may already be gone; nothing useful to do.
    }
    await device.disconnect();
  }
}
