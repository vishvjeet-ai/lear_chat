import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lear_chat/core/messaging/messaging_service.dart';
import 'package:lear_chat/core/messaging/models.dart';
import 'package:lear_chat/core/protocol/codec.dart';
import 'package:lear_chat/core/protocol/constants.dart';
import 'package:lear_chat/transport/fake_transport.dart';

import '../support/memory_store.dart';

void main() {
  late MemoryMessageStore store;
  late MessagingService service;
  late FakeTransport transport;

  Future<void> connect(FakeTransport t) async {
    final info = await t.connect(FakeTransport.demoDevice, const BleConfig());
    service.attach(t, info.protocolVersion);
  }

  Message only(int peer, MessageDirection dir) =>
      store.messages.values.singleWhere((m) => m.peer == peer && m.direction == dir);

  for (final version in [1, 2]) {
    group('demo flow, protocol v$version', () {
      test('sending → queued → delivered → echo reply, on demo timings', () {
        fakeAsync((async) {
          store = MemoryMessageStore();
          var now = 1000;
          service = MessagingService(store: store, clock: () => now++);
          transport = FakeTransport(protocolVersion: version);
          connect(transport);
          async.flushMicrotasks();

          service.send(0x0002, 'Hi there');
          async.flushMicrotasks();
          expect(
            only(2, MessageDirection.outgoing).state,
            MessageState.queued,
            reason: 'write succeeded',
          );

          async.elapse(const Duration(milliseconds: 300));
          final queued = only(2, MessageDirection.outgoing);
          expect(queued.state, MessageState.queued);
          expect(queued.msgId, isNotNull);

          async.elapse(const Duration(milliseconds: 1700)); // t = 2 s
          expect(only(2, MessageDirection.outgoing).state, MessageState.delivered);

          async.elapse(const Duration(milliseconds: 1500)); // t = 3.5 s
          final reply = only(2, MessageDirection.incoming);
          expect(reply.text, 'Got it: Hi there');
          expect(reply.state, MessageState.received);
          expect(store.contacts[2]!.name, 'Node 0002', reason: 'auto-created');
          transport.dispose();
        });
      });
    });
  }

  test('a failed write marks the message failed and retry resends it', () {
    fakeAsync((async) {
      store = MemoryMessageStore();
      service = MessagingService(store: store);
      transport = FakeTransport()..failNextWrite = true;
      connect(transport);
      async.flushMicrotasks();

      service.send(5, 'one');
      async.flushMicrotasks();
      final rowid = only(5, MessageDirection.outgoing).rowid;
      expect(store.messages[rowid]!.state, MessageState.failed);

      service.retry(rowid);
      async.flushMicrotasks();
      expect(store.messages[rowid]!.state, MessageState.queued);
      async.elapse(const Duration(seconds: 2));
      expect(store.messages[rowid]!.state, MessageState.delivered);
      expect(transport.writes, hasLength(1));
      transport.dispose();
    });
  });

  test('sending while detached fails immediately', () async {
    store = MemoryMessageStore();
    service = MessagingService(store: store);
    final rowid = await service.send(9, 'nobody home');
    expect(store.messages[rowid]!.state, MessageState.failed);
  });

  test('send rejects empty and over-limit text', () async {
    store = MemoryMessageStore();
    service = MessagingService(store: store);
    expect(() => service.send(1, '   '), throwsArgumentError);
    expect(() => service.send(1, '😀' * 37), throwsArgumentError);
  });

  test('incoming from an unknown sender creates "Node XXXX" once', () async {
    store = MemoryMessageStore();
    service = MessagingService(store: store);
    await service.handleRx(encodeRxMessage(0x00AB, 'first'));
    await service.handleRx(encodeRxMessage(0x00AB, 'second'));
    expect(store.contacts.values.map((c) => c.name), ['Node 00AB']);
    expect(store.messages, hasLength(2));
  });

  test('incoming from a saved contact keeps its name', () async {
    store = MemoryMessageStore();
    await store.addContact(0x0010, 'Ana');
    service = MessagingService(store: store);
    await service.handleRx(encodeRxMessage(0x0010, 'hola'));
    expect(store.contacts[0x10]!.name, 'Ana');
  });

  test('link loss mid-send: v2 queued messages still complete after reconnect', () {
    fakeAsync((async) {
      store = MemoryMessageStore();
      service = MessagingService(store: store);
      transport = FakeTransport(protocolVersion: 2);
      connect(transport);
      async.flushMicrotasks();

      service.send(3, 'x');
      async.flushMicrotasks();
      final m = only(3, MessageDirection.outgoing);
      expect(m.state, MessageState.queued);

      transport.simulateLinkLoss();
      service.detach();
      async.flushMicrotasks();
      expect(store.messages[m.rowid]!.state, MessageState.queued, reason: 'has a CID');

      connect(transport);
      async.flushMicrotasks();
      // The node reports the final state for the old CID after reconnecting.
      service.handleRx(encodeRxStatus(m.msgId!, kWireDelivered));
      async.flushMicrotasks();
      expect(store.messages[m.rowid]!.state, MessageState.delivered);
      transport.dispose();
    });
  });

  test('init fails stale SENDING rows and restores open ones', () async {
    store = MemoryMessageStore();
    final stale = await store.insertMessage(
      peer: 1,
      direction: MessageDirection.outgoing,
      text: 'a',
      state: MessageState.sending,
      ts: 1,
    );
    final open = await store.insertMessage(
      peer: 1,
      direction: MessageDirection.outgoing,
      text: 'b',
      state: MessageState.sent,
      ts: 2,
      msgId: 0x0042,
    );
    service = MessagingService(store: store);
    await service.init();
    expect(store.messages[stale]!.state, MessageState.failed);
    await service.handleRx(encodeRxStatus(0x0042, kWireDelivered));
    expect(store.messages[open]!.state, MessageState.delivered);
  });

  test('statuses arriving before the write resolves are not overwritten', () async {
    store = MemoryMessageStore();
    service = MessagingService(store: store);
    final slow = _SlowWriteTransport();
    service.attach(slow, 2);
    final sendFuture = service.send(4, 'race');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final m = only(4, MessageDirection.outgoing);
    // Node answers before the write callback fires.
    await service.handleRx(encodeRxStatus(m.msgId!, kWireQueued));
    await service.handleRx(encodeRxStatus(m.msgId!, kWireDelivered));
    slow.completeWrite();
    await sendFuture;
    expect(store.messages[m.rowid]!.state, MessageState.delivered);
    await slow.dispose();
  });
}

/// A transport whose write completes only when told to.
class _SlowWriteTransport extends FakeTransport {
  final _pending = Completer<void>();

  void completeWrite() => _pending.complete();

  @override
  Future<void> write(payload) => _pending.future;
}
