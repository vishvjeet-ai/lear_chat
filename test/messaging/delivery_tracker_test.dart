import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lear_chat/core/messaging/delivery_tracker.dart';
import 'package:lear_chat/core/messaging/models.dart';
import 'package:lear_chat/core/protocol/codec.dart';

const sending = MessageState.sending;
const queued = MessageState.queued;
const sent = MessageState.sent;
const delivered = MessageState.delivered;
const failed = MessageState.failed;

void main() {
  group('protocol v2 (client IDs)', () {
    late DeliveryTracker t;
    setUp(() => t = DeliveryTracker(protocolVersion: 2, random: Random(1)));

    test('happy path: sending → queued → sent → delivered', () {
      final cid = t.beginSend(10)!;
      expect(t.stateOf(10), sending);
      expect(t.onWriteSucceeded(10), [StateChange(10, queued, msgId: cid)]);
      expect(t.onStatus(cid, kWireQueued), isEmpty, reason: 'already queued');
      expect(t.onStatus(cid, kWireSent), [StateChange(10, sent, msgId: cid)]);
      expect(t.onStatus(cid, kWireDelivered), [StateChange(10, delivered, msgId: cid)]);
      expect(t.stateOf(10), isNull, reason: 'forgotten once final');
      expect(t.onStatus(cid, kWireDelivered), isEmpty);
    });

    test('each message gets its own CID and statuses match exactly', () {
      final a = t.beginSend(1)!;
      final b = t.beginSend(2)!;
      expect(a, isNot(b));
      t.onWriteSucceeded(1);
      t.onWriteSucceeded(2);
      // Out of order is fine: IDs, not order, decide.
      expect(t.onStatus(b, kWireDelivered), [StateChange(2, delivered, msgId: b)]);
      expect(t.onStatus(a, kWireFailed), [StateChange(1, failed, msgId: a)]);
    });

    test('CIDs wrap at 16 bits and skip IDs still in use', () {
      final t2 = DeliveryTracker(protocolVersion: 2, random: _Fixed(0xFFFF));
      final a = t2.beginSend(1)!;
      expect(a, 0xFFFF);
      expect(t2.beginSend(2), 0x0000);
    });

    test('race: status arrives before the write resolves', () {
      final cid = t.beginSend(5)!;
      expect(t.onStatus(cid, kWireQueued), [StateChange(5, queued, msgId: cid)]);
      expect(t.onStatus(cid, kWireDelivered), [StateChange(5, delivered, msgId: cid)]);
      expect(t.onWriteSucceeded(5), isEmpty, reason: 'must not move back to queued');
    });

    test('race: write failure after the node already queued it is ignored', () {
      final cid = t.beginSend(5)!;
      t.onStatus(cid, kWireQueued);
      expect(t.onWriteFailed(5), isEmpty);
      expect(t.stateOf(5), queued);
    });

    test('write failure marks failed, retry gets a new CID', () {
      final first = t.beginSend(7)!;
      expect(t.onWriteFailed(7), [const StateChange(7, failed)]);
      expect(t.onStatus(first, kWireQueued), isEmpty, reason: 'old CID released');
      final second = t.beginSend(7)!;
      expect(second, isNot(first));
      expect(t.onWriteSucceeded(7), [StateChange(7, queued, msgId: second)]);
    });

    test('states never move backwards; FAILED after DELIVERED is ignored', () {
      final cid = t.beginSend(1)!;
      t.onWriteSucceeded(1);
      t.onStatus(cid, kWireSent);
      expect(t.onStatus(cid, kWireQueued), isEmpty);
      expect(t.stateOf(1), sent);
      t.onStatus(cid, kWireDelivered);
      expect(t.onStatus(cid, kWireFailed), isEmpty);
    });

    test('unknown IDs and unknown wire states are ignored', () {
      expect(t.onStatus(0x4242, kWireDelivered), isEmpty);
      final cid = t.beginSend(1)!;
      expect(t.onStatus(cid, 99), isEmpty);
    });

    test('disconnect fails SENDING but keeps queued messages trackable', () {
      final a = t.beginSend(1)!;
      t.onWriteSucceeded(1);
      t.beginSend(2);
      expect(t.onDisconnect(), [const StateChange(2, failed)]);
      expect(t.onStatus(a, kWireDelivered), [StateChange(1, delivered, msgId: a)]);
    });

    test('restore after restart keeps matching by CID', () {
      t.restore([const OpenMessage(42, sent, 0x0BAD)]);
      expect(t.onStatus(0x0BAD, kWireDelivered), [const StateChange(42, delivered, msgId: 0x0BAD)]);
    });
  });

  group('protocol v1 (FIFO of node IDs)', () {
    late DeliveryTracker t;
    setUp(() => t = DeliveryTracker(protocolVersion: 1));

    test('beginSend returns no CID and queues the message for an ID', () {
      expect(t.beginSend(1), isNull);
      expect(t.pendingIds, [1]);
    });

    test('QUEUED IDs are matched to messages in write order', () {
      t.beginSend(1);
      t.beginSend(2);
      t.beginSend(3);
      t.onWriteSucceeded(1);
      t.onWriteSucceeded(2);
      t.onWriteSucceeded(3);
      expect(t.onStatus(0x0100, kWireQueued), [const StateChange(1, queued, msgId: 0x0100)]);
      expect(t.onStatus(0x0101, kWireQueued), [const StateChange(2, queued, msgId: 0x0101)]);
      expect(t.onStatus(0x0102, kWireQueued), [const StateChange(3, queued, msgId: 0x0102)]);
      expect(t.pendingIds, isEmpty);
      // Later statuses use the node ID.
      expect(t.onStatus(0x0101, kWireDelivered), [const StateChange(2, delivered, msgId: 0x0101)]);
      expect(t.onStatus(0x0100, kWireFailed), [const StateChange(1, failed, msgId: 0x0100)]);
    });

    test('race: QUEUED arrives before the write promise resolves', () {
      t.beginSend(1);
      expect(t.onStatus(0x0200, kWireQueued), [const StateChange(1, queued, msgId: 0x0200)]);
      expect(t.onWriteSucceeded(1), isEmpty, reason: 'only SENDING may become QUEUED');
      expect(t.onStatus(0x0200, kWireDelivered), [const StateChange(1, delivered, msgId: 0x0200)]);
    });

    test('race: DELIVERED before the write resolves stays delivered', () {
      t.beginSend(1);
      t.onStatus(0x0200, kWireQueued);
      t.onStatus(0x0200, kWireDelivered);
      expect(t.onWriteSucceeded(1), isEmpty);
    });

    test('write resolves first, then QUEUED: the ID is still saved', () {
      t.beginSend(1);
      expect(t.onWriteSucceeded(1), [const StateChange(1, queued)]);
      expect(t.onStatus(0x0300, kWireQueued), [const StateChange(1, queued, msgId: 0x0300)]);
    });

    test('a failed write leaves the FIFO so the next message gets the next ID', () {
      t.beginSend(1);
      t.beginSend(2);
      expect(t.onWriteFailed(1), [const StateChange(1, failed)]);
      expect(t.pendingIds, [2]);
      t.onWriteSucceeded(2);
      expect(t.onStatus(0x0400, kWireQueued), [const StateChange(2, queued, msgId: 0x0400)]);
    });

    test('QUEUED with an empty FIFO is ignored', () {
      expect(t.onStatus(0x0500, kWireQueued), isEmpty);
    });

    test('disconnect clears the FIFO and fails messages that never got an ID', () {
      t.beginSend(1);
      t.onWriteSucceeded(1);
      t.onStatus(0x0600, kWireQueued); // 1 has an ID
      t.beginSend(2);
      t.onWriteSucceeded(2); // queued, no ID yet
      t.beginSend(3); // still sending
      final changes = t.onDisconnect();
      expect(
        changes,
        unorderedEquals([const StateChange(2, failed), const StateChange(3, failed)]),
      );
      expect(t.pendingIds, isEmpty);
      // 1 still gets its final status after reconnecting.
      expect(t.onStatus(0x0600, kWireDelivered), [const StateChange(1, delivered, msgId: 0x0600)]);
      // A late QUEUED for the cleared messages matches nothing.
      expect(t.onStatus(0x0601, kWireQueued), isEmpty);
    });

    test('a reused node ID moves to the newest message', () {
      t.beginSend(1);
      t.onStatus(0x0700, kWireQueued);
      t.beginSend(2);
      t.onStatus(0x0700, kWireQueued); // node wrapped around
      expect(t.onStatus(0x0700, kWireDelivered), [const StateChange(2, delivered, msgId: 0x0700)]);
    });

    test('switching protocol version clears the FIFO', () {
      t.beginSend(1);
      t.protocolVersion = 2;
      expect(t.pendingIds, isEmpty);
    });
  });
}

/// Random that always starts at a chosen value.
class _Fixed implements Random {
  _Fixed(this.value);

  final int value;

  @override
  int nextInt(int max) => value % max;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}
