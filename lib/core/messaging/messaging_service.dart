import 'dart:async';
import 'dart:typed_data';

import '../../transport/ble_transport.dart';
import '../protocol/codec.dart';
import '../protocol/constants.dart';
import '../protocol/utf8_limit.dart';
import 'delivery_tracker.dart';
import 'message_store.dart';
import 'models.dart';

/// Sends and receives messages over whichever transport is attached and keeps
/// the store in step with the delivery tracker. Pure Dart, no Flutter.
class MessagingService {
  MessagingService({required this.store, DeliveryTracker? tracker, int Function()? clock})
    : tracker = tracker ?? DeliveryTracker(),
      _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final MessageStore store;
  final DeliveryTracker tracker;
  final int Function() _clock;

  BleTransport? _transport;
  StreamSubscription<Uint8List>? _rxSub;
  bool _initialized = false;

  bool get isAttached => _transport != null;

  /// Restores open messages after an app restart. Call once at startup.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await store.failStaleOutgoing();
    final open = await store.openOutgoing();
    tracker.restore([for (final m in open) OpenMessage(m.rowid, m.state, m.msgId!)]);
  }

  /// Starts using [transport] after a successful connect.
  void attach(BleTransport transport, int protocolVersion) {
    _rxSub?.cancel();
    _transport = transport;
    tracker.protocolVersion = protocolVersion;
    _rxSub = transport.rx.listen((bytes) => handleRx(bytes));
  }

  /// The link dropped or was closed: fail what can no longer be tracked.
  Future<void> detach() async {
    await _rxSub?.cancel();
    _rxSub = null;
    _transport = null;
    await _apply(tracker.onDisconnect());
  }

  /// Saves and sends [text] to [peer]. Returns the message rowid.
  ///
  /// Throws [ArgumentError] when the text is empty or over the byte limit.
  Future<int> send(int peer, String text) async {
    if (text.trim().isEmpty) throw ArgumentError.value(text, 'text', 'is empty');
    if (!fitsMessageLimit(text)) {
      throw ArgumentError.value(text, 'text', 'is over $kMaxTextBytes bytes');
    }
    await store.ensureContact(peer);
    final rowid = await store.insertMessage(
      peer: peer,
      direction: MessageDirection.outgoing,
      text: text,
      state: MessageState.sending,
      ts: _clock(),
    );
    await _transmit(rowid, peer, text);
    return rowid;
  }

  /// Resends a failed outgoing message in place.
  Future<void> retry(int rowid) async {
    final m = await store.message(rowid);
    if (m == null || !m.isOutgoing || m.state != MessageState.failed) return;
    await store.updateMessage(rowid, MessageState.sending);
    await _transmit(rowid, m.peer, m.text);
  }

  Future<void> _transmit(int rowid, int peer, String text) async {
    final transport = _transport;
    if (transport == null) {
      await store.updateMessage(rowid, MessageState.failed);
      return;
    }
    final cid = tracker.beginSend(rowid);
    if (cid != null) await store.updateMessage(rowid, MessageState.sending, msgId: cid);

    final payload = encodeTx(
      protocolVersion: tracker.protocolVersion,
      dst: peer,
      text: text,
      cid: cid,
    );
    List<StateChange> changes;
    try {
      await transport.write(payload);
      changes = tracker.onWriteSucceeded(rowid);
    } catch (_) {
      changes = tracker.onWriteFailed(rowid);
    }
    await _apply(changes);
  }

  /// Handles one RX notification. Public for tests.
  Future<void> handleRx(Uint8List bytes) async {
    final packet = decodeRx(bytes);
    switch (packet) {
      case RxStatus(:final id, :final state):
        await _apply(tracker.onStatus(id, state));
      case RxMessage(:final src, :final text):
        await store.ensureContact(src);
        await store.insertMessage(
          peer: src,
          direction: MessageDirection.incoming,
          text: text,
          state: MessageState.received,
          ts: _clock(),
        );
      case null:
        break;
    }
  }

  Future<void> _apply(List<StateChange> changes) async {
    for (final c in changes) {
      await store.updateMessage(c.localId, c.state, msgId: c.msgId);
    }
  }

  Future<void> dispose() async {
    await _rxSub?.cancel();
    _rxSub = null;
    _transport = null;
  }
}
