/// Byte-level encoding of the LEAR BLE contract (docs/ble-contract.md).
///
/// All 16-bit values are big-endian. Decoders never throw on bad input: they
/// return null so a malformed notification cannot crash the app.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'constants.dart';
import 'utf8_limit.dart';

/// First byte of an RX notification.
const int kRxIncoming = 0x01;
const int kRxStatus = 0x02;

/// Delivery states as they travel over the air.
const int kWireQueued = 1;
const int kWireDelivered = 2;
const int kWireFailed = 3;

/// v2 only: the first mesh hop acknowledged the message.
const int kWireSent = 4;

enum LinkQuality { none, weak, good }

/// Contents of the STATUS characteristic.
class NodeStatus {
  const NodeStatus({
    required this.nodeId,
    required this.batteryPercent,
    required this.queueLength,
    required this.link,
  });

  final int nodeId;
  final int batteryPercent;
  final int queueLength;
  final LinkQuality link;

  @override
  bool operator ==(Object other) =>
      other is NodeStatus &&
      other.nodeId == nodeId &&
      other.batteryPercent == batteryPercent &&
      other.queueLength == queueLength &&
      other.link == link;

  @override
  int get hashCode => Object.hash(nodeId, batteryPercent, queueLength, link);

  @override
  String toString() =>
      'NodeStatus(node: $nodeId, battery: $batteryPercent%, queue: $queueLength, link: ${link.name})';
}

/// A decoded RX notification.
sealed class RxPacket {
  const RxPacket();
}

/// A message from another node.
class RxMessage extends RxPacket {
  const RxMessage({required this.src, required this.text});

  final int src;
  final String text;

  @override
  bool operator ==(Object other) => other is RxMessage && other.src == src && other.text == text;

  @override
  int get hashCode => Object.hash(src, text);
}

/// A delivery status. [id] is the client ID (v2) or the node's message ID (v1).
class RxStatus extends RxPacket {
  const RxStatus({required this.id, required this.state});

  final int id;
  final int state;

  @override
  bool operator ==(Object other) => other is RxStatus && other.id == id && other.state == state;

  @override
  int get hashCode => Object.hash(id, state);
}

/// What the node sees after decoding a TX write. Used by the fake transport
/// and tests.
class TxFrame {
  const TxFrame({required this.dst, required this.text, this.cid});

  final int? cid;
  final int dst;
  final String text;
}

void _check16(String name, int value) {
  if (value < 0 || value > 0xFFFF) {
    throw ArgumentError.value(value, name, 'must be 0 to 65535');
  }
}

int _read16(Uint8List b, int offset) => (b[offset] << 8) | b[offset + 1];

/// Builds a TX write.
///
/// v2: `CID_hi CID_lo DST_hi DST_lo text`. v1: `DST_hi DST_lo text`.
/// Throws [ArgumentError] if the text is over [kMaxTextBytes] or an ID is out
/// of range.
Uint8List encodeTx({
  required int protocolVersion,
  required int dst,
  required String text,
  int? cid,
}) {
  _check16('dst', dst);
  final body = utf8.encode(text);
  if (body.length > kMaxTextBytes) {
    throw ArgumentError.value(
      body.length,
      'text',
      'is ${body.length} bytes; the limit is $kMaxTextBytes',
    );
  }
  final b = BytesBuilder(copy: false);
  if (protocolVersion >= 2) {
    if (cid == null) throw ArgumentError.notNull('cid');
    _check16('cid', cid);
    b.add([cid >> 8, cid & 0xFF]);
  }
  b.add([dst >> 8, dst & 0xFF]);
  b.add(body);
  return b.toBytes();
}

/// Node-side decode of a TX write. Returns null when too short.
TxFrame? decodeTx(Uint8List bytes, {required int protocolVersion}) {
  final header = protocolVersion >= 2 ? 4 : 2;
  if (bytes.length < header) return null;
  final text = utf8.decode(bytes.sublist(header), allowMalformed: true);
  if (protocolVersion >= 2) {
    return TxFrame(cid: _read16(bytes, 0), dst: _read16(bytes, 2), text: text);
  }
  return TxFrame(dst: _read16(bytes, 0), text: text);
}

/// Decodes an RX notification. Returns null for unknown types, short packets
/// and unknown delivery states.
RxPacket? decodeRx(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  switch (bytes[0]) {
    case kRxIncoming:
      if (bytes.length < 3) return null;
      return RxMessage(
        src: _read16(bytes, 1),
        text: utf8.decode(bytes.sublist(3), allowMalformed: true),
      );
    case kRxStatus:
      if (bytes.length < 4) return null;
      final state = bytes[3];
      if (state < kWireQueued || state > kWireSent) return null;
      return RxStatus(id: _read16(bytes, 1), state: state);
    default:
      return null;
  }
}

/// Decodes the STATUS characteristic. Returns null when shorter than 5 bytes.
NodeStatus? decodeNodeStatus(Uint8List bytes) {
  if (bytes.length < 5) return null;
  final link = switch (bytes[4]) {
    1 => LinkQuality.weak,
    2 => LinkQuality.good,
    _ => LinkQuality.none,
  };
  return NodeStatus(
    nodeId: _read16(bytes, 0),
    batteryPercent: bytes[2].clamp(0, 100),
    queueLength: bytes[3],
    link: link,
  );
}

/// Reads the VERSION characteristic. Null or empty means a v1 node.
int decodeProtocolVersion(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty || bytes[0] == 0) {
    return kLegacyProtocolVersion;
  }
  return bytes[0];
}

/// Node-side encoders, used by the fake transport and tests.
Uint8List encodeRxMessage(int src, String text) {
  _check16('src', src);
  return Uint8List.fromList([kRxIncoming, src >> 8, src & 0xFF, ...utf8.encode(text)]);
}

Uint8List encodeRxStatus(int id, int state) {
  _check16('id', id);
  return Uint8List.fromList([kRxStatus, id >> 8, id & 0xFF, state]);
}

Uint8List encodeNodeStatus(NodeStatus s) {
  _check16('nodeId', s.nodeId);
  return Uint8List.fromList([
    s.nodeId >> 8,
    s.nodeId & 0xFF,
    s.batteryPercent.clamp(0, 100),
    s.queueLength.clamp(0, 255),
    s.link.index,
  ]);
}

/// Truncates [text] so it fits in [maxBytes] of UTF-8 without splitting a
/// code point. Used for demo echo replies.
String truncateUtf8(String text, int maxBytes) {
  if (utf8ByteLength(text) <= maxBytes) return text;
  final out = StringBuffer();
  var used = 0;
  for (final rune in text.runes) {
    final size = utf8ByteLength(String.fromCharCode(rune));
    if (used + size > maxBytes) break;
    out.writeCharCode(rune);
    used += size;
  }
  return out.toString();
}
