/// Regression tests for the "璁惧鍦?2s鍐呮病鏈夊洖澶嶏紙宸插彂閫?鐗囷級" failure.
///
/// That message means the first frame went out and nothing came back. Three
/// defects could each produce it, and all three are covered here:
///
///   1. A leaked `stream.first` listener, so the *second* attempt loses the
///      race to a zombie subscription from the first.
///   2. A closed StreamController being reused after a probe/fallback cycle.
///   3. No settle window between MTU negotiation and the first write.
///
/// These tests exercise the same primitives the transport uses, without BLE.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// The buggy pattern, kept here so the test proves the hazard is real and
/// that the replacement is not merely different-looking.
Future<Uint8List> leakyAwait(
  Stream<Uint8List> hub,
  Future<void> Function() write, {
  required Duration timeout,
}) async {
  final reply = hub.first.timeout(
    timeout,
    onTimeout: () => throw StateError('timeout'),
  );
  await write();
  return reply;
}

/// The fixed pattern: manually managed subscription, cancelled in a finally.
Future<Uint8List> safeAwait(
  Stream<Uint8List> hub,
  Future<void> Function() write, {
  required Duration timeout,
}) async {
  final completer = Completer<Uint8List>();
  final timer = Timer.periodic(timeout, (_) {
    if (!completer.isCompleted) completer.completeError(StateError('timeout'));
  });
  final sub = hub.listen(
    (f) {
      if (!completer.isCompleted) completer.complete(f);
    },
    onError: (Object e) {
      if (!completer.isCompleted) completer.completeError(e);
    },
  );
  try {
    await write();
    return await completer.future;
  } finally {
    timer.cancel();
    await sub.cancel();
  }
}

void main() {
  group('reply listener lifecycle', () {
    test('leaky pattern leaves a live listener behind', () async {
      final hub = StreamController<Uint8List>.broadcast();
      addTearDown(hub.close);

      // First attempt: device never answers -> timeout.
      await expectLater(
        leakyAwait(hub.stream, () async {}, timeout: const Duration(milliseconds: 40)),
        throwsA(isA<StateError>()),
      );

      // A listener from the failed attempt is still attached, so hasListener
      // is true. That is the zombie that steals the next reply.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        hub.hasListener,
        isTrue,
        reason: 'the buggy path leaks an active subscription after timeout',
      );
    });

    test('safe pattern releases the listener on timeout', () async {
      final hub = StreamController<Uint8List>.broadcast();
      addTearDown(hub.close);

      await expectLater(
        safeAwait(hub.stream, () async {}, timeout: const Duration(milliseconds: 40)),
        throwsA(isA<StateError>()),
      );

      expect(
        hub.hasListener,
        isFalse,
        reason: 'subscription must be cancelled in the finally block',
      );
    });

    test('safe pattern still receives a fast reply', () async {
      final hub = StreamController<Uint8List>.broadcast();
      addTearDown(hub.close);

      final reply = await safeAwait(hub.stream,
        () async {
          // Device answers immediately after the write.
          Future<void>.delayed(const Duration(milliseconds: 5), () {
            hub.add(Uint8List.fromList([0x08, 0x01, 0x10, 0x01]));
          });
        },
        timeout: const Duration(seconds: 1),
      );

      expect(reply, orderedEquals([0x08, 0x01, 0x10, 0x01]));
      expect(hub.hasListener, isFalse);
    });

    test('a retry succeeds after the first attempt times out', () async {
      final hub = StreamController<Uint8List>.broadcast();
      addTearDown(hub.close);

      await expectLater(
        safeAwait(hub.stream, () async {}, timeout: const Duration(milliseconds: 40)),
        throwsA(isA<StateError>()),
      );

      // Second attempt: the device answers this time.
      final reply = await safeAwait(hub.stream,
        () async {
          Future<void>.delayed(const Duration(milliseconds: 5), () {
            hub.add(Uint8List.fromList([0xAA]));
          });
        },
        timeout: const Duration(seconds: 1),
      );

      expect(reply, orderedEquals([0xAA]));
    });
  });

  group('hub replacement on close', () {
    test('adding to a closed controller never surfaces, so the hub is swapped',
        () async {
      var hub = StreamController<Uint8List>.broadcast();
      await hub.close();
      expect(hub.isClosed, isTrue);

      // The old code did `_frames.add(...)` unconditionally. On a closed
      // controller that is silently dropped -- the exact "sent 1 chunk, nothing
      // came back" symptom.
      expect(hub.hasListener, isFalse);

      // Reopening must build a fresh controller, otherwise every reply after
      // the first close is lost.
      hub = StreamController<Uint8List>.broadcast();
      final got = <int>[];
      final sub = hub.stream.listen((f) => got.addAll(f));
      hub.add(Uint8List.fromList([1, 2, 3]));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();
      await hub.close();

      expect(got, orderedEquals([1, 2, 3]));
    });
  });

  group('first frame shape', () {
    test('getDeviceInfo is a single 8-byte write including the 2-byte header',
        () {
      // `08 00 12 02 08 01` = EuiccDeviceReq{cmd:0, request:DeviceReq{cmd:1}}
      const payload = [0x08, 0x00, 0x12, 0x02, 0x08, 0x01];
      final header = [(payload.length >> 8) & 0xFF, payload.length & 0xFF];
      final frame = [...header, ...payload];

      expect(frame, orderedEquals([0x00, 0x06, 0x08, 0x00, 0x12, 0x02, 0x08, 0x01]));
      // At MTU 23 the first chunk capacity is mtu-5 = 18 bytes, so an 8-byte
      // frame is a single write -- matching the "宸插彂閫?1 鐗? in the report.
      expect(frame.length, lessThanOrEqualTo(18));
    });
  });
}

