/// ES10b notification handling.
///
/// After a profile is installed or removed, the eUICC queues a notification
/// that must be delivered to the responsible SM-DP+ (or SM-DS). If it is never
/// sent, the operator's server keeps the profile marked as "downloading" and
/// the next install for the same ICCID may be refused.
///
/// Sequence:
///   1. ES10b ListNotification        (0xBF28) -> seqNumber list
///   2. ES10b RetrieveNotificationsList (0xBF2B) -> PendingNotification + address
///   3. ES9+  handleNotification      (SM-DP+)
///   4. ES10b NotificationSent        (0xBF30) -> acknowledges, frees the slot
library;

import 'dart:convert';
import 'dart:typed_data';

import 'asn1.dart';
import 'lpa.dart';
import 'smdp_client.dart';

/// One queued notification on the card.
class PendingNotification {
  final int seqNumber;
  /// Address of the server that owns this notification (usually the SM-DP+).
  final String notificationAddress;
  /// The notification itself, already base64-encoded for ES9+.
  final String pendingNotificationB64;
  /// True when this is a ProfileInstallationResult (0xBF37) rather than a
  /// generic otherSignedNotification (0x30).
  final bool isInstallationResult;

  PendingNotification({
    required this.seqNumber,
    required this.notificationAddress,
    required this.pendingNotificationB64,
    required this.isInstallationResult,
  });

  @override
  String toString() => 'PendingNotification(seq=$seqNumber, '
      'to=$notificationAddress, install=$isInstallationResult)';
}

extension NotificationSupport on Lpa {
  /// Runs `der` on the notification applet's channel when the card offers one.
  ///
  /// Falls back to the ISD-R channel: on cards that expose a single session
  /// the two applets are reachable through it, and refusing to read
  /// notifications there is worse than the channel-sharing risk.
  Future<Uint8List> _notificationEs10x(Uint8List der) {
    final ch = session.notificationChannel;
    if (ch == null) return es10x(der);
    return session.es10xOnChannel(der, ch);
  }

  /// ES10b ListNotification: returns the sequence numbers still queued.
  Future<List<int>> listNotifications() async {
    final rsp = await _notificationEs10x(tlv(0xBF28, const []));
    final root = findByTag(rsp, 0xBF28);
    if (root == null) throw LpaError('No ListNotificationResponse');

    // ListNotificationResponse ::= [1] SEQUENCE OF INTEGER (seqNumber)
    final seqs = <int>[];
    for (final node in parseAll(root.value)) {
      _collectIntegers(node, seqs);
    }
    return seqs;
  }

  void _collectIntegers(DerNode node, List<int> out) {
    if (node.tag == 0x02) {
      var v = 0;
      for (final b in node.value) {
        v = (v << 8) | b;
      }
      out.add(v);
      return;
    }
    try {
      for (final child in parseAll(node.value)) {
        _collectIntegers(child, out);
      }
    } on FormatException {
      // Leaf content, not a container.
    }
  }

  /// ES10b RetrieveNotificationsList for one [seqNumber].
  Future<PendingNotification?> retrieveNotification(int seqNumber) async {
    final request = tlvChildren(0xBF2B, [
      tlvChildren(0xA0, [
        tlv(0x80, _encodeInt(seqNumber)),
      ]),
    ]);

    final rsp = await _notificationEs10x(request);
    final root = findByTag(rsp, 0xBF2B);
    if (root == null) return null;

    // Look for either a ProfileInstallationResult or an otherSignedNotification.
    final install = findByTag(root.value, 0xBF37);
    final notification = install ?? findByTag(root.value, 0x30);
    if (notification == null) return null;

    // The metadata (0xBF2F) inside carries the notificationAddress (UTF8String).
    final meta = findByTag(notification.value, 0xBF2F);
    final addressNode = meta == null
        ? findByTag(notification.value, 0x0C)
        : findByTag(meta.value, 0x0C);
    if (addressNode == null) return null;

    return PendingNotification(
      seqNumber: seqNumber,
      notificationAddress: utf8.decode(addressNode.value, allowMalformed: true),
      pendingNotificationB64: base64.encode(notification.self),
      isInstallationResult: install != null,
    );
  }

  /// ES10b NotificationSent for [seqNumber].
  Future<void> notificationSent(int seqNumber) async {
    await _notificationEs10x(tlv(0xBF30, _encodeInt(seqNumber)));
  }

  /// Drains every queued notification: retrieve, POST to its owner, acknowledge.
  ///
  /// Returns the number of notifications successfully delivered. Individual
  /// failures are collected in [errors] rather than aborting the whole drain,
  /// because one unreachable SM-DP+ should not block notifications belonging
  /// to others.
  Future<NotificationDrainResult> flushNotifications({
    SmdpClient Function(String address)? clientFactory,
  }) async {
    final result = NotificationDrainResult();
    final seqs = await listNotifications();

    for (final seq in seqs) {
      PendingNotification? pending;
      try {
        pending = await retrieveNotification(seq);
      } catch (e) {
        result.errors.add('seq $seq: could not retrieve ($e)');
        continue;
      }
      if (pending == null) continue;

      final client = (clientFactory ?? SmdpClient.new)(
        pending.notificationAddress,
      );
      try {
        await client.handleNotification(pending.pendingNotificationB64);
        await notificationSent(seq);
        result.delivered++;
      } catch (e) {
        result.errors.add('seq $seq -> ${pending.notificationAddress}: $e');
      } finally {
        client.close();
      }
    }
    return result;
  }

  static Uint8List _encodeInt(int value) {
    if (value == 0) return Uint8List.fromList([0]);
    final bytes = <int>[];
    var v = value;
    while (v > 0) {
      bytes.insert(0, v & 0xFF);
      v >>= 8;
    }
    return Uint8List.fromList(bytes);
  }
}

class NotificationDrainResult {
  int delivered = 0;
  final List<String> errors = [];

  bool get isClean => errors.isEmpty;

  @override
  String toString() => 'NotificationDrainResult(delivered=$delivered, '
      'errors=${errors.length})';
}
