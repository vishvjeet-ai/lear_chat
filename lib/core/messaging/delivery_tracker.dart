import 'dart:collection';
import 'dart:math';

import '../protocol/codec.dart';
import '../protocol/constants.dart';
import 'models.dart';

/// A state change the caller should persist.
class StateChange {
  const StateChange(this.localId, this.state, {this.msgId});

  final int localId;
  final MessageState state;
  final int? msgId;

  @override
  bool operator ==(Object other) =>
      other is StateChange &&
      other.localId == localId &&
      other.state == state &&
      other.msgId == msgId;

  @override
  int get hashCode => Object.hash(localId, state, msgId);

  @override
  String toString() => 'StateChange($localId → ${state.name}${msgId == null ? '' : ', id $msgId'})';
}

/// An outgoing message the tracker restores after an app restart.
class OpenMessage {
  const OpenMessage(this.localId, this.state, this.msgId);

  final int localId;
  final MessageState state;
  final int msgId;
}

class _Entry {
  _Entry(this.state);

  MessageState state;
  int? wireId;
}

/// Delivery state machine for outgoing messages. Pure Dart, no I/O.
///
/// Every method returns the changes to persist; nothing is applied twice.
/// States only move forward (sending → queued → sent → delivered), and failed
/// can only replace a state before delivered.
///
/// Protocol v2: the phone picks a client ID (CID) per message and every
/// status names it, so matching is exact.
///
/// Protocol v1: QUEUED statuses carry a node-assigned ID in the same order the
/// messages were written, so pending messages sit in a FIFO and the oldest one
/// takes the ID. The message joins the FIFO *before* the write so a QUEUED
/// status that beats the write's completion still finds it.
class DeliveryTracker {
  DeliveryTracker({int protocolVersion = kCurrentProtocolVersion, Random? random})
    // Named parameters can't be private, so no initializing formal here.
    // ignore: prefer_initializing_formals
    : _protocolVersion = protocolVersion,
      _nextCid = (random ?? Random()).nextInt(0x10000);

  int _protocolVersion;
  int _nextCid;
  final Map<int, _Entry> _entries = {};
  final Map<int, int> _localByWireId = {};
  final Queue<int> _fifo = Queue<int>();

  int get protocolVersion => _protocolVersion;

  /// Called on connect with the version the node reported.
  set protocolVersion(int value) {
    if (value != _protocolVersion) _fifo.clear();
    _protocolVersion = value;
  }

  bool get _isV2 => _protocolVersion >= 2;

  /// Messages waiting for a v1 ID, oldest first. For tests and diagnostics.
  List<int> get pendingIds => List.unmodifiable(_fifo);

  MessageState? stateOf(int localId) => _entries[localId]?.state;

  /// Reloads queued and sent messages that already have an ID.
  void restore(Iterable<OpenMessage> open) {
    for (final m in open) {
      final entry = _Entry(m.state)..wireId = m.msgId;
      _entries[m.localId] = entry;
      _localByWireId[m.msgId] = m.localId;
    }
  }

  /// Starts sending [localId]. Returns the CID to put in the TX frame (v2),
  /// or null (v1).
  int? beginSend(int localId) {
    _forget(localId);
    final entry = _Entry(MessageState.sending);
    _entries[localId] = entry;
    if (_isV2) {
      final cid = _allocateCid();
      entry.wireId = cid;
      _localByWireId[cid] = localId;
      return cid;
    }
    _fifo.addLast(localId);
    return null;
  }

  /// The TX write succeeded. Moves SENDING to QUEUED, unless a status
  /// already moved the message on.
  List<StateChange> onWriteSucceeded(int localId) {
    final entry = _entries[localId];
    if (entry == null || entry.state != MessageState.sending) return const [];
    entry.state = MessageState.queued;
    return [StateChange(localId, MessageState.queued, msgId: entry.wireId)];
  }

  /// The TX write failed. Marks the message failed unless a status already
  /// proved the node accepted it.
  List<StateChange> onWriteFailed(int localId) {
    final entry = _entries[localId];
    if (entry == null || entry.state != MessageState.sending) return const [];
    _forget(localId);
    return [StateChange(localId, MessageState.failed)];
  }

  /// A delivery status arrived from the node.
  List<StateChange> onStatus(int wireId, int wireState) {
    final target = _stateFromWire(wireState);
    if (target == null) return const [];

    int? localId;
    var idAssigned = false;
    if (!_isV2 && wireState == kWireQueued && _fifo.isNotEmpty) {
      // v1: the oldest message still waiting takes this ID. A stale entry
      // left with the same (wrapped) ID loses its mapping.
      localId = _fifo.removeFirst();
      final stale = _localByWireId[wireId];
      if (stale != null && stale != localId) _entries[stale]?.wireId = null;
      _entries[localId]?.wireId = wireId;
      _localByWireId[wireId] = localId;
      idAssigned = true;
    } else {
      localId = _localByWireId[wireId];
    }
    if (localId == null) return const [];
    final entry = _entries[localId];
    if (entry == null) return const [];

    return _advance(localId, entry, target, idAssigned: idAssigned);
  }

  /// The BLE link dropped. Messages still SENDING fail. In v1 the FIFO is
  /// cleared and messages still waiting for an ID fail, since their IDs will
  /// never be matched. Messages with an ID stay open.
  List<StateChange> onDisconnect() {
    final changes = <StateChange>[];
    final waiting = Set<int>.of(_fifo);
    _fifo.clear();
    for (final id in _entries.keys.toList()) {
      final entry = _entries[id]!;
      final noId = !_isV2 && waiting.contains(id);
      if (entry.state == MessageState.sending || noId) {
        _forget(id);
        changes.add(StateChange(id, MessageState.failed));
      }
    }
    return changes;
  }

  List<StateChange> _advance(
    int localId,
    _Entry entry,
    MessageState target, {
    bool idAssigned = false,
  }) {
    if (target == MessageState.failed) {
      if (entry.state == MessageState.delivered) return const [];
      _forget(localId);
      return [StateChange(localId, MessageState.failed, msgId: entry.wireId)];
    }
    if (_rank(target) <= _rank(entry.state)) {
      // No state change, but a freshly assigned v1 ID must still be saved.
      return idAssigned ? [StateChange(localId, entry.state, msgId: entry.wireId)] : const [];
    }
    entry.state = target;
    final change = StateChange(localId, target, msgId: entry.wireId);
    if (target == MessageState.delivered) _forget(localId);
    return [change];
  }

  void _forget(int localId) {
    final entry = _entries.remove(localId);
    _fifo.remove(localId);
    final wireId = entry?.wireId;
    if (wireId != null && _localByWireId[wireId] == localId) {
      _localByWireId.remove(wireId);
    }
  }

  int _allocateCid() {
    for (var i = 0; i < 0x10000; i++) {
      final cid = _nextCid;
      _nextCid = (_nextCid + 1) & 0xFFFF;
      if (!_localByWireId.containsKey(cid)) return cid;
    }
    throw StateError('All 65536 client IDs are in use');
  }

  static MessageState? _stateFromWire(int wire) => switch (wire) {
    kWireQueued => MessageState.queued,
    kWireSent => MessageState.sent,
    kWireDelivered => MessageState.delivered,
    kWireFailed => MessageState.failed,
    _ => null,
  };

  static int _rank(MessageState s) => switch (s) {
    MessageState.sending => 0,
    MessageState.queued => 1,
    MessageState.sent => 2,
    MessageState.delivered => 3,
    MessageState.failed || MessageState.received => -1,
  };
}
