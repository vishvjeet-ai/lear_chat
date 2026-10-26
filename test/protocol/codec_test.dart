import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lear_chat/core/protocol/codec.dart';
import 'package:lear_chat/core/protocol/constants.dart';

Uint8List b(List<int> bytes) => Uint8List.fromList(bytes);

void main() {
  group('encodeTx', () {
    test('v2 puts CID then DST, big-endian, then UTF-8 text', () {
      final out = encodeTx(protocolVersion: 2, cid: 0x0102, dst: 0xA0B1, text: 'Hi');
      expect(out, [0x01, 0x02, 0xA0, 0xB1, 0x48, 0x69]);
    });

    test('v1 has DST then text, no CID', () {
      final out = encodeTx(protocolVersion: 1, dst: 0x0002, text: 'Hi');
      expect(out, [0x00, 0x02, 0x48, 0x69]);
    });

    test('encodes multi-byte text as UTF-8', () {
      final out = encodeTx(protocolVersion: 1, dst: 1, text: 'é😀');
      expect(out.sublist(2), utf8.encode('é😀'));
    });

    test('accepts exactly 144 bytes and rejects 145', () {
      expect(
        encodeTx(protocolVersion: 2, cid: 1, dst: 1, text: 'a' * kMaxTextBytes).length,
        4 + kMaxTextBytes,
      );
      expect(
        () => encodeTx(protocolVersion: 2, cid: 1, dst: 1, text: 'a' * (kMaxTextBytes + 1)),
        throwsArgumentError,
      );
      // 48 × 3-byte characters = 144 bytes, one more is 147.
      expect(() => encodeTx(protocolVersion: 1, dst: 1, text: '€' * 48), returnsNormally);
      expect(() => encodeTx(protocolVersion: 1, dst: 1, text: '€' * 49), throwsArgumentError);
    });

    test('rejects out-of-range IDs and a missing v2 CID', () {
      expect(() => encodeTx(protocolVersion: 1, dst: 0x10000, text: 'x'), throwsArgumentError);
      expect(() => encodeTx(protocolVersion: 1, dst: -1, text: 'x'), throwsArgumentError);
      expect(() => encodeTx(protocolVersion: 2, dst: 1, text: 'x'), throwsArgumentError);
      expect(
        () => encodeTx(protocolVersion: 2, cid: 0x10000, dst: 1, text: 'x'),
        throwsArgumentError,
      );
    });

    test('round-trips through decodeTx', () {
      final v2 = decodeTx(
        encodeTx(protocolVersion: 2, cid: 0xFFFF, dst: 0x1234, text: 'ok ✓'),
        protocolVersion: 2,
      )!;
      expect([v2.cid, v2.dst, v2.text], [0xFFFF, 0x1234, 'ok ✓']);
      final v1 = decodeTx(encodeTx(protocolVersion: 1, dst: 7, text: ''), protocolVersion: 1)!;
      expect([v1.cid, v1.dst, v1.text], [null, 7, '']);
      expect(decodeTx(b([0x00, 0x01, 0x02]), protocolVersion: 2), isNull);
    });
  });

  group('decodeRx', () {
    test('incoming message', () {
      final p = decodeRx(b([0x01, 0x00, 0xAB, ...utf8.encode('Hello ñ')]));
      expect(p, const RxMessage(src: 0x00AB, text: 'Hello ñ'));
    });

    test('incoming message with empty text', () {
      expect(decodeRx(b([0x01, 0xFF, 0xFF])), const RxMessage(src: 0xFFFF, text: ''));
    });

    test('status for each known state', () {
      for (final s in [kWireQueued, kWireDelivered, kWireFailed, kWireSent]) {
        expect(decodeRx(b([0x02, 0x12, 0x34, s])), RxStatus(id: 0x1234, state: s));
      }
    });

    test('malformed text does not throw', () {
      final p = decodeRx(b([0x01, 0x00, 0x01, 0xC3])) as RxMessage;
      expect(p.text, '�');
    });

    test('returns null for short, unknown or invalid packets', () {
      expect(decodeRx(b([])), isNull);
      expect(decodeRx(b([0x01, 0x00])), isNull);
      expect(decodeRx(b([0x02, 0x00, 0x01])), isNull);
      expect(decodeRx(b([0x02, 0x00, 0x01, 0])), isNull);
      expect(decodeRx(b([0x02, 0x00, 0x01, 9])), isNull);
      expect(decodeRx(b([0x7F, 0x00, 0x01, 0x01])), isNull);
    });

    test('node-side encoders round-trip', () {
      expect(decodeRx(encodeRxMessage(0x0A0B, 'yo')), const RxMessage(src: 0x0A0B, text: 'yo'));
      expect(
        decodeRx(encodeRxStatus(0xBEEF, kWireDelivered)),
        const RxStatus(id: 0xBEEF, state: kWireDelivered),
      );
    });
  });

  group('NodeStatus', () {
    test('decodes node, battery, queue and link', () {
      expect(
        decodeNodeStatus(b([0x00, 0x01, 87, 3, 2])),
        const NodeStatus(nodeId: 1, batteryPercent: 87, queueLength: 3, link: LinkQuality.good),
      );
      expect(decodeNodeStatus(b([0x12, 0x34, 5, 0, 1]))!.link, LinkQuality.weak);
      expect(decodeNodeStatus(b([0x12, 0x34, 5, 0, 0]))!.link, LinkQuality.none);
    });

    test('clamps battery and treats unknown link as none', () {
      final s = decodeNodeStatus(b([0, 1, 250, 0, 9]))!;
      expect(s.batteryPercent, 100);
      expect(s.link, LinkQuality.none);
    });

    test('ignores extra bytes and rejects short values', () {
      expect(decodeNodeStatus(b([0, 1, 50, 0, 2, 0xFF])), isNotNull);
      expect(decodeNodeStatus(b([0, 1, 50, 0])), isNull);
    });

    test('round-trips', () {
      const s = NodeStatus(
        nodeId: 0xABCD,
        batteryPercent: 42,
        queueLength: 7,
        link: LinkQuality.weak,
      );
      expect(decodeNodeStatus(encodeNodeStatus(s)), s);
    });
  });

  test('protocol version: missing or zero means v1', () {
    expect(decodeProtocolVersion(null), 1);
    expect(decodeProtocolVersion(b([])), 1);
    expect(decodeProtocolVersion(b([0])), 1);
    expect(decodeProtocolVersion(b([2])), 2);
  });

  test('truncateUtf8 never splits a character', () {
    expect(truncateUtf8('abc', 10), 'abc');
    expect(truncateUtf8('aé', 2), 'a');
    expect(truncateUtf8('😀😀', 5), '😀');
  });
}
