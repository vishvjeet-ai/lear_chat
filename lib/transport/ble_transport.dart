import 'dart:typed_data';

import '../core/protocol/codec.dart';
import '../core/protocol/constants.dart';

/// A device found while scanning.
class DiscoveredDevice {
  const DiscoveredDevice({
    required this.id,
    required this.name,
    this.rssi,
    this.isLear = true,
    this.services = const [],
  });

  /// Platform identifier (MAC address on Android, UUID on iOS).
  final String id;
  final String name;
  final int? rssi;

  /// False for other devices, which only appear when scanning with `showAll`.
  final bool isLear;

  /// Advertised service UUIDs, for diagnosing firmware advertising.
  final List<String> services;
}

/// What the app learns from a successful connect.
class LinkInfo {
  const LinkInfo({required this.device, required this.protocolVersion, this.status, this.mtu});

  final DiscoveredDevice device;
  final int protocolVersion;
  final NodeStatus? status;
  final int? mtu;
}

/// The phone's link to one handheld. The UI and messaging logic depend only
/// on this interface; the real BLE stack and the demo are interchangeable.
///
/// Methods throw `BleFailure` with a user-facing message.
abstract class BleTransport {
  /// True for the demo transport.
  bool get isDemo;

  /// Checks permissions (asking if needed) and that Bluetooth is on.
  Future<void> ensureReady();

  /// Scans for handhelds advertising the service or the name prefix. With
  /// [showAll], every advertising device is reported (for diagnosing a
  /// handheld that doesn't show up). The stream ends after [timeout] or when
  /// [stopScan] is called.
  Stream<DiscoveredDevice> scan(BleConfig config, {Duration timeout, bool showAll});
  Future<void> stopScan();

  /// Connects, pairs, negotiates the MTU, discovers characteristics,
  /// subscribes to RX and STATUS and reads STATUS once.
  Future<LinkInfo> connect(DiscoveredDevice device, BleConfig config);

  /// Disconnects on purpose. Does not emit on [disconnected].
  Future<void> disconnect();

  /// Writes a TX frame with response.
  Future<void> write(Uint8List payload);

  /// RX notifications, raw.
  Stream<Uint8List> get rx;

  /// STATUS notifications and reads.
  Stream<NodeStatus> get status;

  /// Emits when the link drops without [disconnect] being called.
  Stream<void> get disconnected;

  Future<void> dispose();
}
