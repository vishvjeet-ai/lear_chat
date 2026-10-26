import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lear_chat/core/protocol/codec.dart';
import 'package:lear_chat/core/protocol/constants.dart';
import 'package:lear_chat/transport/demo_lan.dart';
import 'package:lear_chat/transport/fake_transport.dart';

void main() {
  FakeTransport phone(MemoryDemoLanHub hub, int nodeId) => FakeTransport(
    nodeStatus: NodeStatus(nodeId: nodeId, batteryPercent: 87, queueLength: 0, link: LinkQuality.good),
    lan: hub.join(),
  );

  test('packet round trip', () {
    const p = DemoLanPacket(kind: DemoLanKind.message, src: 0x1234, dst: 0xABCD, id: 7, text: 'héllo');
    final d = DemoLanPacket.decode(p.encode())!;
    expect((d.kind, d.src, d.dst, d.id, d.text), (DemoLanKind.message, 0x1234, 0xABCD, 7, 'héllo'));
    expect(DemoLanPacket.decode(Uint8List.fromList([1, 2, 3])), isNull);
  });

  test('a message reaches the phone it is addressed to, which acknowledges it', () async {
    final hub = MemoryDemoLanHub();
    final a = phone(hub, 0x00A1);
    final b = phone(hub, 0x00B2);
    await a.connect(FakeTransport.demoDevice, const BleConfig());
    await b.connect(FakeTransport.demoDevice, const BleConfig());

    final aRx = <RxPacket?>[];
    final bRx = <RxPacket?>[];
    a.rx.listen((e) => aRx.add(decodeRx(e)));
    b.rx.listen((e) => bRx.add(decodeRx(e)));

    await a.write(encodeTx(protocolVersion: kCurrentProtocolVersion, dst: 0x00B2, text: 'hi B', cid: 5));
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(bRx, [const RxMessage(src: 0x00A1, text: 'hi B')]);
    expect(aRx, contains(const RxStatus(id: 5, state: kWireDelivered)));
    expect(aRx.whereType<RxMessage>(), isEmpty, reason: 'no echo reply');
  });

  test('a message received twice is shown once', () async {
    final hub = MemoryDemoLanHub();
    final b = phone(hub, 0x00B2);
    final sender = hub.join();
    await sender.start();
    await b.connect(FakeTransport.demoDevice, const BleConfig());
    final bRx = <RxPacket?>[];
    b.rx.listen((e) => bRx.add(decodeRx(e)));

    const p = DemoLanPacket(kind: DemoLanKind.message, src: 0x00A1, dst: 0x00B2, id: 9, text: 'once');
    sender.send(p);
    sender.send(p);
    await Future<void>.delayed(Duration.zero);

    expect(bRx, [const RxMessage(src: 0x00A1, text: 'once')]);
  });

  test('a third phone ignores a message for someone else', () async {
    final hub = MemoryDemoLanHub();
    final a = phone(hub, 0x00A1);
    final b = phone(hub, 0x00B2);
    final c = phone(hub, 0x00C3);
    for (final t in [a, b, c]) {
      await t.connect(FakeTransport.demoDevice, const BleConfig());
    }
    final cRx = <RxPacket?>[];
    c.rx.listen((e) => cRx.add(decodeRx(e)));

    await a.write(encodeTx(protocolVersion: kCurrentProtocolVersion, dst: 0x00B2, text: 'private', cid: 1));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(cRx, isEmpty);
  });

  test('no acknowledgement when the destination is not on the network', () async {
    final hub = MemoryDemoLanHub();
    final a = phone(hub, 0x00A1);
    await a.connect(FakeTransport.demoDevice, const BleConfig());
    final aRx = <RxPacket?>[];
    a.rx.listen((e) => aRx.add(decodeRx(e)));

    await a.write(encodeTx(protocolVersion: kCurrentProtocolVersion, dst: 0x0999, text: 'anyone?', cid: 2));
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(aRx, [const RxStatus(id: 2, state: kWireQueued)]);
  });
}
