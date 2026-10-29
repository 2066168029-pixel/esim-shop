/// 9eSIM BLE reader transport.
///
/// The 9eSIM "mini tool" is an ESP32-S3 board holding an eUICC slot. Its
/// firmware is open source (github.com/9esim/eLPA) and it exposes the same
/// Nordic-UART service as Linksfield cards:
///
///   service 6e400001-b5a3-f393-e0a9-e50e24dcca9e
///   RX      6e400002-...   (write commands here)
///   TX      6e400003-...   (notifications)
///
/// What is different -- and much simpler -- is the protocol:
///
///   * There is **no framing**. Whatever you write to RX is handed straight to
///     `lpac` as a command line; whatever the board prints comes back on TX.
///   * The board runs `lpac` itself. This transport drives it through lpac's
///     stdio APDU driver, which speaks JSON -- see `driver/apdu/stdio.c`:
///
///         -> {"func":"transmit","param":"80E2..."}
///         <- {"type":"apdu","payload":{"ecode":0,"data":"BF2D...9000"}}
///
///     Functions: connect, disconnect, logic_channel_open,
///     logic_channel_close, transmit.
///
/// Using the APDU path (rather than text commands like `profile list`) keeps
/// one code path for every device: the same `Lpa` that drives a Linksfield
/// card or a PC/SC reader drives this reader too.
///
/// Notes taken from the vendor firmware and from NekokoLPA's BLE adapters:
///   * The board is not strictly request/response: a status frame can arrive
///     after a command was already answered. Every request therefore clears
///     the receive queue first, otherwise one straggler shifts every later
///     exchange by a reply.
///   * Writes must be paced; the link drops commands during a burst.
///   * Keep writes at BLE MTU size (20 bytes is always safe); the board
///     reassembles the line itself.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'euicc_transport.dart';

/// GATT identifiers, identical to the Linksfield NUS service.
class Esim9Gatt {
  static const String service = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const String rx = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
  static const String tx = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
}

/// A 9eSIM BLE reader session.
class Esim9BleTransport implements EuiccTransport {
  final BluetoothDevice device;
  final BluetoothCharacteristic _rx;
  final BluetoothCharacteristic _tx;

  /// Broadcast so several consumers can listen: the command waiter and the
  /// diagnostics panel both do.
  final _lines = StreamController<String>.broadcast();
  final _buffer = StringBuffer();
  StreamSubscription<List<int>>? _sub;

  /// Log lines seen since the current command started. Kept only so a
  /// failure message can say what the board actually replied.
  final _sink = <String>[];

  int _mtu = 23;

  /// Milliseconds between GATT writes. The firmware answers a burst by simply
  /// not answering; 20 ms costs nothing at these message sizes.
  final int writeGapMs;

  /// Budget for one JSON round trip. Reads of large profile lists are slow.
  final Duration timeout;

  bool _open = false;

  Esim9BleTransport._(
    this.device,
    this._rx,
    this._tx, {
    this.writeGapMs = 20,
    this.timeout = const Duration(seconds: 30),
  });

  @override
  String get kind => '9esim-ble';

  @override
  String get description =>
      device.platformName.isNotEmpty ? device.platformName : device.remoteId.str;

  @override
  bool get isOpen => _open;

  // ------------------------------------------------------------- discovery

  /// Connects and resolves the NUS characteristics.
  ///
  /// Two failure modes this firmware family has, both handled here:
  ///
  ///   * **It drops the link if the MTU is requested too early.** `connect()`
  ///     defaults to `mtu: 512`, which is exactly that mistake -- so the MTU is
  ///     passed as null and negotiated later, after discovery.
  ///   * **Discovery issued the instant connect returns fails** with "device
  ///     is disconnected" because Android has not finished the GATT handshake.
  ///     A short settle plus a couple of retries fixes it.
  ///
  /// Pairing does NOT happen here: see [startBond]. Android refuses to pair a
  /// legacy-PIN BLE device while a GATT link is open, so the caller closes the
  /// link first, pairs, then calls this.
  static Future<Esim9BleTransport> connect(
    BluetoothDevice device, {
    int writeGapMs = 20,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await device.connect(
          timeout: const Duration(seconds: 20),
          mtu: null,
          autoConnect: false,
        );
        await Future.delayed(
            Duration(milliseconds: attempt == 0 ? 800 : 1500));

        final services = await device.discoverServices();
        final pair = _findNus(services);
        if (pair == null) {
          await device.disconnect();
          throw TransportError(
            '这不是 9ESIM 读卡器：没有 NUS 服务 (${Esim9Gatt.service})',
          );
        }

        final t = Esim9BleTransport._(device, pair.$1, pair.$2,
            writeGapMs: writeGapMs, timeout: timeout);
        await t._subscribe();
        await t._negotiateMtu(device);
        return t;
      } catch (e) {
        lastError = e;
        try {
          await device.disconnect();
        } catch (_) {}
        if (attempt < 2) {
          await Future.delayed(Duration(milliseconds: 800 + attempt * 700));
        }
      }
    }
    throw TransportError('连不上读卡器: $lastError', lastError);
  }

  // ------------------------------------------------------------------ bond

  /// Closes the GATT link so a legacy PIN pairing can be started.
  static Future<void> disconnectBle(BluetoothDevice device) async {
    try {
      await device.disconnect();
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 500));
  }

  /// Current bond state, or [BluetoothBondState.none] when unavailable.
  static Future<BluetoothBondState> bondStateOf(BluetoothDevice device) async {
    try {
      return await device.bondState.first;
    } catch (_) {
      return BluetoothBondState.none;
    }
  }

  /// Starts pairing and waits for the final state.
  ///
  /// [pin] answers Android's PIN request; without it the system dialog is left
  /// for the user to type into (what the vendor app does).
  ///
  /// `createBond` is only a trigger: on many Android builds it throws
  /// "device is not connected" for BLE even while the OS pairing request is
  /// already running, so a thrown error is NOT proof of failure. The bond state
  /// is the only trustworthy signal, so this polls it.
  static Future<bool> startBond(
    BluetoothDevice device, {
    String? pin,
    Duration timeout = const Duration(seconds: 35),
  }) async {
    if (await bondStateOf(device) == BluetoothBondState.bonded) return true;

    // Note: this plugin has no setPin(); only the `pin:` argument of
    // createBond reaches the native side. So if the OS dialog cannot be
    // answered automatically, it is left to the user -- which still produces a
    // valid bond, and the poll below notices it.
    try {
      await device.createBond(
        pin: pin == null || pin.isEmpty
            ? null
            : Uint8List.fromList(pin.codeUnits),
        timeout: timeout.inSeconds,
      );
    } catch (_) {
      // A throw says nothing about the bond state; the poll below decides.
    }

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final state = await bondStateOf(device);
      if (state == BluetoothBondState.bonded) return true;
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return await bondStateOf(device) == BluetoothBondState.bonded;
  }

  /// Finds the write/notify pair in the NUS service, tolerating firmware that
  /// renumbers the characteristics.
  static (BluetoothCharacteristic, BluetoothCharacteristic)? _findNus(
    List<BluetoothService> services,
  ) {
    for (final s in services) {
      if (s.uuid.str.toLowerCase() != Esim9Gatt.service) continue;
      BluetoothCharacteristic? rx;
      BluetoothCharacteristic? tx;
      for (final c in s.characteristics) {
        final u = c.uuid.str.toLowerCase();
        if (u == Esim9Gatt.rx) rx = c;
        if (u == Esim9Gatt.tx) tx = c;
      }
      if (rx != null && tx != null) return (rx, tx);

      // Fall back to properties when the UUIDs differ.
      for (final c in s.characteristics) {
        final p = c.properties;
        final writable = p.write || p.writeWithoutResponse;
        final notifiable = p.notify || p.indicate;
        if (writable && !notifiable && rx == null) rx = c;
        if (notifiable && !writable && tx == null) tx = c;
      }
      if (rx != null && tx != null) return (rx, tx);
    }
    return null;
  }

  /// Negotiates the largest MTU the link allows, without ever failing.
  Future<void> _negotiateMtu(BluetoothDevice device) async {
    try {
      final mtu = await device.requestMtu(517).timeout(
            const Duration(seconds: 4),
            onTimeout: () => _mtu,
          );
      if (mtu >= 23) _mtu = mtu;
    } catch (_) {
      // Keep the default; see _write for why this is not fatal.
    }
  }

  Future<void> _subscribe() async {
    await _tx.setNotifyValue(true);
    _sub = _tx.onValueReceived.listen(_onChunk);
    await Future.delayed(const Duration(milliseconds: 150));
  }

  /// Splits the notification byte stream into lines.
  ///
  /// The board prints log lines and JSON replies on the same channel, so every
  /// line is kept both for matching (with the raw text) and for diagnostics.
  void _onChunk(List<int> chunk) {
    if (chunk.isEmpty) return;
    final text = latin1.decode(chunk);
    for (final ch in text.split('')) {
      if (ch == '\n') {
        _emitLine();
      } else if (ch != '\r') {
        _buffer.write(ch);
      }
    }
    // Firmware that never sends '\n' would otherwise stall: flush a complete
    // JSON object as soon as it is closed.
    final pending = _buffer.toString().trim();
    if (pending.startsWith('{') && pending.endsWith('}')) {
      _buffer.clear();
      _emitLine(already: pending);
    }
  }

  void _emitLine({String? already}) {
    final line = already ?? _buffer.toString().trim();
    if (already == null) _buffer.clear();
    if (line.isEmpty) return;
    _sink.add(line);
    if (_sink.length > 40) _sink.removeAt(0);
    lastRawLine = line;
    if (!_lines.isClosed) _lines.add(line);
  }

  /// The most recent complete line the board sent, whatever it was. Shown in
  /// error messages so a silent device can still be diagnosed from a
  /// screenshot.
  String lastRawLine = '';

  /// Everything the board said since the current command was written.
  List<String> get recentOutput => List.unmodifiable(_sink);

  /// Sends a raw line and returns the raw reply text -- no JSON parsing.
  ///
  /// Used by the diagnostics panel: it is the only way to see what a device
  /// that speaks "almost JSON" is actually saying.
  Future<String> rawRoundTrip(String line) async {
    final response = _waitFor(true, requireApdu: false);
    _sink.clear();
    await _write(line);
    return response;
  }

  /// Asks the board what it is (its own info command). Falls back to `help`
  /// and then to a plain newline, so a firmware revision with a different
  /// command set still gets exercised.
  Future<List<String>> identify() async {
    final out = <String>[];
    for (final cmd in const ['{"cmd":"getElpaInfo"}', 'help', '\n']) {
      try {
        out.add('> $cmd\n${await rawRoundTrip(cmd)}');
      } catch (e) {
        out.add('> $cmd\n(no reply: $e)');
      }
    }
    return out;
  }

  // ------------------------------------------------------------- lifecycle

  @override
  Future<void> open() async {
    if (_open) return;
    // The board powers the card on when the reader is powered. Tell lpac to
    // connect so later transmits have a card handle, then open ISD-R.
    await _rawApduCommand('connect', null);
    await _rawApduCommand('logic_channel_open', const [
      0xA0, 0x00, 0x00, 0x05, 0x59, 0x10, 0x10, 0xFF,
      0xFF, 0xFF, 0xFF, 0x89, 0x00, 0x00, 0x01, 0x00,
    ]);
    _open = true;
  }

  /// Cheap liveness check: sends the lpac `connect` request and reports whether
  /// the board answered in the JSON shape we expect.
  ///
  /// Used to tell a 9eSIM board apart from a Linksfield card, which exposes the
  /// same NUS service but speaks protobuf. Never throws; a silent or garbled
  /// answer just means "not this device".
  Future<bool> probe() async {
    try {
      await _rawApduCommand(
        'connect',
        null,
        shortTimeout: true,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<ApduResponse> transmit(Uint8List apdu) async {
    final data = await _rawApduCommand('transmit', apdu);
    if (data.length < 2) {
      throw TransportError(
        '读卡器返回的 APDU 响应太短 (${data.length}B)',
      );
    }
    final sw = (data[data.length - 2] << 8) | data[data.length - 1];
    return ApduResponse(
      Uint8List.sublistView(data, 0, data.length - 2),
      sw,
    );
  }

  @override
  Future<int> openChannel(Uint8List aid) async {
    // open() already opened channel 1; reusable for the lifetime of the
    // session. A second open on the same AID is harmless on this firmware.
    await _rawApduCommand('logic_channel_open', aid);
    return 1;
  }

  /// Opens another channel without disturbing the ISD-R one.
  ///
  /// The board keeps one lpac card handle per connection but honours
  /// MANAGE CHANNEL for every `logic_channel_open`, so the notification
  /// applet can live on channel 2 while the ES10x traffic stays on 1.
  @override
  Future<int> addChannel(Uint8List aid) async {
    await _rawApduCommand('logic_channel_open', aid);
    return 2;
  }

  @override
  Future<void> closeChannel(int channel) async {
    try {
      await _rawApduCommand('logic_channel_close', [channel]);
    } catch (_) {
      // Closing is advisory; the board resets on disconnect anyway.
    }
  }

  /// Closes [channel] with the ISO 7816-4 MANAGE CHANNEL command.
  ///
  /// The board's `logic_channel_close` helper targets the channel it opened
  /// itself, so a channel this client opened is closed here explicitly.
  @override
  Future<bool> closeChannelOnCard(int channel) async {
    if (channel <= 0) return true;
    try {
      final rsp = await transmit(
        Uint8List.fromList([0x00, 0x70, 0x80, channel & 0xFF, 0x00]),
      );
      return rsp.isOk;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> close() async {
    try {
      await _rawApduCommand('disconnect', null, shortTimeout: true);
    } catch (_) {}
    await _sub?.cancel();
    _sub = null;
    await _lines.close();
    try {
      await _tx.setNotifyValue(false);
    } catch (_) {}
    try {
      await device.disconnect();
    } catch (_) {}
    _open = false;
  }

  // -------------------------------------------------------------- lpac CLI

  // The board runs lpac, so text commands work too (`profile list`,
  // `profile enable -I <iccid>`). They are not used by the SGP.22 path: the
  // APDU route above is identical for every device, and text output would
  // have to be re-parsed per firmware version.

  // ------------------------------------------------------------ JSON APDUs

  Future<Uint8List> _rawApduCommand(
    String func,
    List<int>? param, {
    bool shortTimeout = false,
  }) async {
    final payload = <String, dynamic>{'func': func};
    if (param != null) payload['param'] = _hex(param);
    final request = jsonEncode({'type': 'apdu', 'payload': payload});

    // Subscribe *before* writing: the board can answer before `write`
    // returns, and a broadcast stream would drop that reply on the floor.
    final response = _waitFor(shortTimeout);
    _sink.clear();
    await _write(request);

    final line = await response;

    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(line) as Map<String, dynamic>;
    } catch (e) {
      throw TransportError('读卡器返回无法解析: $line', e);
    }
    final body = (decoded['payload'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final ecode = (body['ecode'] as num?)?.toInt() ?? -1;
    if (ecode < 0) {
      throw TransportError('读卡器执行 $func 失败 (ecode=$ecode)');
    }
    final data = body['data'];
    return data is String && data.isNotEmpty ? _unhex(data) : Uint8List(0);
  }

  /// Resolves with the next line that is an apdu reply.
  ///
  /// Must be *created before* the request is written, because the board can
  /// answer before `write` returns on a fast link -- a broadcast stream would
  /// drop that reply.
  Future<String> _waitFor(bool shortTimeout, {bool requireApdu = true}) {
    final waiting = _lines.stream
        .where((l) =>
            l.startsWith('{') && (!requireApdu || l.contains('"apdu"')))
        .first
        .timeout(
          shortTimeout ? const Duration(seconds: 5) : timeout,
          onTimeout: () => throw TransportError(
            '读卡器 ${shortTimeout ? 5 : timeout.inSeconds}s 内没有回应'
            '${_sink.isEmpty ? "" : "；最后的输出: ${_sink.last}"}',
          ),
        );
    return waiting;
  }

  /// Writes [text] in MTU-sized chunks, paced.
  Future<void> _write(String text) async {
    // Anything queued predates this command and belongs to an earlier
    // exchange; keeping it would shift every later reply.
    await _drain();
    await _ensureLive();

    final bytes = utf8.encode(text);
    // Subtracting twice (ATT header already comes off the MTU) is the classic
    // reason a negotiated 517-byte MTU still fails on write. `requestMtu`
    // returns the ATT MTU, so the payload is exactly `mtu - 3`.
    final byMtu = _mtu - 3;
    final chunk = byMtu < 20 ? 20 : byMtu;
    for (var i = 0; i < bytes.length; i += chunk) {
      final end = (i + chunk) > bytes.length ? bytes.length : i + chunk;
      try {
        await _rx.write(
          Uint8List.fromList(bytes.sublist(i, end)),
          withoutResponse: false,
        );
      } catch (e) {
        // Some ESP32 builds only accept write-without-response on the RX
        // characteristic; retry that way before giving up on the link.
        if (!_wroteWithoutResponse) {
          _wroteWithoutResponse = true;
          await _rx.write(
            Uint8List.fromList(bytes.sublist(i, end)),
            withoutResponse: true,
          );
        } else {
          rethrow;
        }
      }
      if (end < bytes.length) {
        await Future.delayed(Duration(milliseconds: writeGapMs));
      }
    }
  }

  /// Reconnects when the firmware has silently dropped the link.
  ///
  /// These readers disconnect a few seconds after the last command, and every
  /// later write fails with "device is disconnected" instead of a useful
  /// message. Checking first turns that into a reconnect the user never sees.
  Future<void> _ensureLive() async {
    try {
      if (await device.isConnected) return;
    } catch (_) {
      // Fall through to the reconnect attempt.
    }
    await device.connect(timeout: const Duration(seconds: 15), autoConnect: false);
    await Future.delayed(const Duration(milliseconds: 500));
    await _tx.setNotifyValue(true);
    await Future.delayed(const Duration(milliseconds: 150));
  }

  /// Set once a write-with-response was rejected and we switched modes.
  bool _wroteWithoutResponse = false;

  Future<void> _drain() async {
    // Give already-delivered notifications a tick to land, then drop whatever
    // is parked in the line buffer. Cheap: one short wait, not a poll loop.
    await Future.delayed(const Duration(milliseconds: 30));
    if (_buffer.isNotEmpty) _buffer.clear();
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

  static Uint8List _unhex(String s) {
    final clean = s.replaceAll(RegExp(r'\s'), '');
    final out = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
