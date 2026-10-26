import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// UDP port the demo uses on the local Wi-Fi network.
const int kDemoLanPort = 47474;

enum DemoLanKind { message, ack }

/// One demo datagram: a text message, or the receiver's acknowledgement of it.
class DemoLanPacket {
  const DemoLanPacket({
    required this.kind,
    required this.src,
    required this.dst,
    required this.id,
    this.text = '',
  });

  final DemoLanKind kind;
  final int src;
  final int dst;

  /// Sender-chosen message id; an ack repeats the id it acknowledges.
  final int id;
  final String text;

  static const _magic = [0x4C, 0x44]; // 'LD'

  Uint8List encode() => Uint8List.fromList([
    ..._magic,
    kind.index,
    src >> 8,
    src & 0xFF,
    dst >> 8,
    dst & 0xFF,
    id >> 8,
    id & 0xFF,
    ...utf8.encode(text),
  ]);

  /// Null for anything that is not a well-formed demo packet.
  static DemoLanPacket? decode(Uint8List b) {
    if (b.length < 9 || b[0] != _magic[0] || b[1] != _magic[1]) return null;
    if (b[2] >= DemoLanKind.values.length) return null;
    return DemoLanPacket(
      kind: DemoLanKind.values[b[2]],
      src: (b[3] << 8) | b[4],
      dst: (b[5] << 8) | b[6],
      id: (b[7] << 8) | b[8],
      text: utf8.decode(b.sublist(9), allowMalformed: true),
    );
  }
}

/// How demo phones reach each other. Everything sent is heard by every other
/// phone on the network; receivers pick out what is addressed to them.
abstract class DemoLan {
  Stream<DemoLanPacket> get packets;
  Future<void> start();
  void send(DemoLanPacket packet);
  Future<void> stop();
}

/// Broadcasts demo packets over the local Wi-Fi network.
class UdpDemoLan implements DemoLan {
  UdpDemoLan({this.port = kDemoLanPort});

  final int port;
  final _packets = StreamController<DemoLanPacket>.broadcast();
  RawDatagramSocket? _socket;

  @override
  Stream<DemoLanPacket> get packets => _packets.stream;

  @override
  Future<void> start() async {
    if (_socket != null) return;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final packet = DemoLanPacket.decode(datagram.data);
      if (packet != null && !_packets.isClosed) _packets.add(packet);
    });
    _socket = socket;
  }

  @override
  void send(DemoLanPacket packet) => unawaited(_broadcast(packet.encode()));

  /// Sends to the limited broadcast address and to each network's own
  /// broadcast address. Android often routes 255.255.255.255 out of the wrong
  /// interface (mobile data), so the per-network address is what usually works.
  /// Dart cannot read the netmask, so networks are assumed to be /24, which
  /// holds for home routers and phone hotspots.
  Future<void> _broadcast(Uint8List bytes) async {
    final socket = _socket;
    if (socket == null) return;
    final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final i in interfaces) {
        for (final a in i.addresses) {
          final o = a.rawAddress;
          targets.add(InternetAddress.fromRawAddress(Uint8List.fromList([o[0], o[1], o[2], 255])));
        }
      }
    } on Object {
      // Fall back to the limited broadcast alone.
    }
    for (final t in targets) {
      if (_socket != socket) return;
      try {
        socket.send(bytes, t, port);
      } on Object {
        // One unreachable network must not stop the others.
      }
    }
  }

  @override
  Future<void> stop() async {
    _socket?.close();
    _socket = null;
  }
}

/// In-process stand-in for the network, so tests can link several phones.
class MemoryDemoLanHub {
  final List<_MemoryDemoLan> _members = [];

  DemoLan join() => _MemoryDemoLan(this);
}

class _MemoryDemoLan implements DemoLan {
  _MemoryDemoLan(this._hub);

  final MemoryDemoLanHub _hub;
  final _packets = StreamController<DemoLanPacket>.broadcast(sync: true);

  @override
  Stream<DemoLanPacket> get packets => _packets.stream;

  @override
  Future<void> start() async => _hub._members.add(this);

  @override
  void send(DemoLanPacket packet) {
    for (final m in List.of(_hub._members)) {
      if (m != this) m._packets.add(packet);
    }
  }

  @override
  Future<void> stop() async => _hub._members.remove(this);
}
