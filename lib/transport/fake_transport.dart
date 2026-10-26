import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../core/ble_failure.dart';
import '../core/protocol/codec.dart';
import '../core/protocol/constants.dart';
import 'ble_transport.dart';
import 'demo_lan.dart';

/// A simulated handheld for demo mode and tests. Uses only Dart timers, so it
/// runs in tests under fake time and on any phone without Bluetooth.
///
/// After each write: QUEUED at [queuedDelay], DELIVERED at [deliveredDelay],
/// and an echo reply `Got it: <text>` from the destination at [replyDelay].
///
/// With a [lan], messages go to other phones in demo mode instead: the phone
/// whose node ID matches the destination shows the message and acknowledges
/// it, which marks the sender's message DELIVERED. There is no echo.
class FakeTransport implements BleTransport {
  FakeTransport({
    this.protocolVersion = kCurrentProtocolVersion,
    this.queuedDelay = const Duration(milliseconds: 300),
    this.deliveredDelay = const Duration(seconds: 2),
    this.replyDelay = const Duration(milliseconds: 3500),
    this.nodeStatus = const NodeStatus(
      nodeId: 0x0001,
      batteryPercent: 87,
      queueLength: 0,
      link: LinkQuality.good,
    ),
    this.isDemo = true,
    this.lan,
  });

  static const DiscoveredDevice demoDevice = DiscoveredDevice(
    id: 'demo-handheld',
    name: 'LEAR-DEMO',
    rssi: -48,
  );

  final int protocolVersion;
  final Duration queuedDelay;
  final Duration deliveredDelay;
  final Duration replyDelay;
  final NodeStatus nodeStatus;
  final DemoLan? lan;

  /// When set, the next write throws instead of being accepted.
  bool failNextWrite = false;

  /// How many of the next connect attempts fail as out of range.
  int failNextConnects = 0;

  /// Number of connect calls, for tests.
  int connectCalls = 0;

  /// Every TX frame written, for tests.
  final List<Uint8List> writes = [];

  final _rx = StreamController<Uint8List>.broadcast();
  final _status = StreamController<NodeStatus>.broadcast();
  final _disconnected = StreamController<void>.broadcast();
  final List<Timer> _timers = [];
  bool _connected = false;
  int _nextNodeMsgId = 0x0100;
  // Random start so a restarted phone does not reuse ids the receiver has
  // just seen.
  int _nextLanId = Random().nextInt(0x10000);

  /// Recent incoming `src:id` keys. One message arrives once per broadcast
  /// address it was sent to, so repeats are dropped (but still acknowledged).
  final Set<int> _seenLan = {};
  StreamSubscription<DemoLanPacket>? _lanSub;

  /// LAN message id to the status id its DELIVERED report will use.
  final Map<int, int> _awaitingAck = {};

  bool get isConnected => _connected;

  /// False lets tests use this transport as if it were real hardware.
  @override
  final bool isDemo;

  @override
  Stream<Uint8List> get rx => _rx.stream;

  @override
  Stream<NodeStatus> get status => _status.stream;

  @override
  Stream<void> get disconnected => _disconnected.stream;

  @override
  Future<void> ensureReady() async {}

  @override
  Stream<DiscoveredDevice> scan(
    BleConfig config, {
    Duration timeout = const Duration(seconds: 15),
    bool showAll = false,
  }) => Stream.value(demoDevice);

  @override
  Future<void> stopScan() async {}

  @override
  Future<LinkInfo> connect(DiscoveredDevice device, BleConfig config) async {
    connectCalls++;
    if (failNextConnects > 0) {
      failNextConnects--;
      throw BleFailure(BleFailureKind.outOfRange, deviceName: device.name);
    }
    final lan = this.lan;
    if (lan != null) {
      try {
        await lan.start();
      } on Object {
        throw BleFailure(BleFailureKind.connectionLost, deviceName: device.name);
      }
      await _lanSub?.cancel();
      _lanSub = lan.packets.listen(_onLanPacket);
    }
    _connected = true;
    _schedule(Duration.zero, () => _status.add(nodeStatus));
    return LinkInfo(
      device: device,
      protocolVersion: protocolVersion,
      status: nodeStatus,
      mtu: kDesiredMtu,
    );
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    _cancelTimers();
    await _stopLan();
  }

  Future<void> _stopLan() async {
    await _lanSub?.cancel();
    _lanSub = null;
    _awaitingAck.clear();
    _seenLan.clear();
    await lan?.stop();
  }

  void _onLanPacket(DemoLanPacket p) {
    if (!_connected || p.src == nodeStatus.nodeId) return;
    switch (p.kind) {
      case DemoLanKind.message:
        if (p.dst != nodeStatus.nodeId) return;
        if (_seenLan.add((p.src << 16) | p.id)) {
          if (_seenLan.length > 256) _seenLan.remove(_seenLan.first);
          _rx.add(encodeRxMessage(p.src, p.text));
        }
        lan?.send(
          DemoLanPacket(kind: DemoLanKind.ack, src: nodeStatus.nodeId, dst: p.src, id: p.id),
        );
      case DemoLanKind.ack:
        if (p.dst != nodeStatus.nodeId) return;
        final statusId = _awaitingAck.remove(p.id);
        if (statusId != null) _rx.add(encodeRxStatus(statusId, kWireDelivered));
    }
  }

  /// Simulates the handheld going out of range.
  void simulateLinkLoss() {
    if (!_connected) return;
    _connected = false;
    _cancelTimers();
    unawaited(_stopLan());
    _disconnected.add(null);
  }

  @override
  Future<void> write(Uint8List payload) async {
    if (!_connected) {
      throw BleFailure(BleFailureKind.connectionLost, deviceName: demoDevice.name);
    }
    if (failNextWrite) {
      failNextWrite = false;
      throw BleFailure(BleFailureKind.writeFailed, deviceName: demoDevice.name);
    }
    final frame = decodeTx(payload, protocolVersion: protocolVersion);
    if (frame == null) {
      throw BleFailure(BleFailureKind.writeFailed, deviceName: demoDevice.name);
    }
    writes.add(payload);

    final statusId = frame.cid ?? _takeNodeMsgId();
    _schedule(queuedDelay, () => _rx.add(encodeRxStatus(statusId, kWireQueued)));
    final lan = this.lan;
    if (lan != null) {
      final lanId = _nextLanId;
      _nextLanId = (_nextLanId + 1) & 0xFFFF;
      _awaitingAck[lanId] = statusId;
      lan.send(
        DemoLanPacket(
          kind: DemoLanKind.message,
          src: nodeStatus.nodeId,
          dst: frame.dst,
          id: lanId,
          text: frame.text,
        ),
      );
      return;
    }
    _schedule(deliveredDelay, () => _rx.add(encodeRxStatus(statusId, kWireDelivered)));
    _schedule(replyDelay, () {
      final reply = truncateUtf8('Got it: ${frame.text}', kMaxTextBytes);
      _rx.add(encodeRxMessage(frame.dst, reply));
    });
  }

  int _takeNodeMsgId() {
    final id = _nextNodeMsgId;
    _nextNodeMsgId = (_nextNodeMsgId + 1) & 0xFFFF;
    return id;
  }

  void _schedule(Duration delay, void Function() action) {
    late final Timer timer;
    timer = Timer(delay, () {
      _timers.remove(timer);
      if (_connected) action();
    });
    _timers.add(timer);
  }

  void _cancelTimers() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
  }

  @override
  Future<void> dispose() async {
    _connected = false;
    _cancelTimers();
    await _stopLan();
    await _rx.close();
    await _status.close();
    await _disconnected.close();
  }
}
