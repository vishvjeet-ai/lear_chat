import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:universal_ble/universal_ble.dart';

import '../core/ble_failure.dart';
import '../core/protocol/codec.dart';
import '../core/protocol/constants.dart';
import 'ble_transport.dart';

/// [BleTransport] on a real phone, built on universal_ble.
class UniversalBleTransport implements BleTransport {
  static const _connectTimeout = Duration(seconds: 15);
  static const _pairTimeout = Duration(minutes: 2);
  static const _opTimeout = Duration(seconds: 10);

  final _rx = StreamController<Uint8List>.broadcast();
  final _status = StreamController<NodeStatus>.broadcast();
  final _disconnected = StreamController<void>.broadcast();

  String? _deviceId;
  String? _deviceName;
  BleConfig _config = const BleConfig();
  bool _closingOnPurpose = false;
  final List<StreamSubscription<Object?>> _linkSubs = [];
  StreamSubscription<BleDevice>? _scanSub;
  Timer? _scanTimer;
  bool _scanActive = false;
  StreamController<DiscoveredDevice>? _scanResults;

  @override
  bool get isDemo => false;

  @override
  Stream<Uint8List> get rx => _rx.stream;

  @override
  Stream<NodeStatus> get status => _status.stream;

  @override
  Stream<void> get disconnected => _disconnected.stream;

  @override
  Future<void> ensureReady() async {
    if (Platform.isAndroid) await _ensureAndroidPermissions();

    var state = await UniversalBle.getBluetoothAvailabilityState();
    if (state == AvailabilityState.unknown || state == AvailabilityState.resetting) {
      // iOS reports unknown until CoreBluetooth has started.
      state = await UniversalBle.availabilityStream
          .firstWhere((s) => s != AvailabilityState.unknown && s != AvailabilityState.resetting)
          .timeout(const Duration(seconds: 3), onTimeout: () => state);
    }
    switch (state) {
      case AvailabilityState.poweredOn:
        return;
      case AvailabilityState.poweredOff:
        throw BleFailure(BleFailureKind.bluetoothOff);
      case AvailabilityState.unsupported:
        throw BleFailure(BleFailureKind.bluetoothUnsupported);
      case AvailabilityState.unauthorized:
        // iOS can't ask again once denied; the fix is in Settings.
        throw BleFailure(BleFailureKind.permissionPermanentlyDenied);
      case AvailabilityState.unknown || AvailabilityState.resetting:
        throw BleFailure(BleFailureKind.unknown);
    }
  }

  Future<void> _ensureAndroidPermissions() async {
    final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
    // Android 12+: Nearby devices. Android 11 and below: location, which BLE
    // scanning needs there. BLUETOOTH and BLUETOOTH_ADMIN are install-time.
    final permissions = sdk >= 31
        ? [Permission.bluetoothScan, Permission.bluetoothConnect]
        : [Permission.locationWhenInUse];
    final results = await permissions.request();
    if (results.values.any((s) => s.isPermanentlyDenied)) {
      throw BleFailure(BleFailureKind.permissionPermanentlyDenied);
    }
    if (!results.values.every((s) => s.isGranted || s.isLimited)) {
      throw BleFailure(BleFailureKind.permissionDenied);
    }
  }

  /// Opens this app's page in the system settings.
  static Future<bool> openSystemSettings() => openAppSettings();

  /// Asks Android to turn Bluetooth on. Returns false where unsupported.
  static Future<bool> requestEnableBluetooth() async {
    try {
      return await UniversalBle.enableBluetooth();
    } catch (_) {
      return false;
    }
  }

  @override
  Stream<DiscoveredDevice> scan(
    BleConfig config, {
    Duration timeout = const Duration(seconds: 15),
    bool showAll = false,
  }) {
    final serviceUuid = config.serviceUuid.toLowerCase();
    final prefix = config.namePrefix.toLowerCase();
    late final StreamController<DiscoveredDevice> controller;
    controller = StreamController<DiscoveredDevice>(
      onListen: () async {
        _scanResults = controller;
        _scanSub = UniversalBle.scanStream.listen((d) {
          final name = d.name ?? d.rawName ?? '';
          final isLear =
              d.services.contains(serviceUuid) ||
              (prefix.isNotEmpty && name.toLowerCase().startsWith(prefix));
          if (!isLear && !showAll) return;
          controller.add(
            DiscoveredDevice(
              id: d.deviceId,
              name: name.isNotEmpty ? name : (isLear ? 'LEAR handheld' : 'Unnamed device'),
              rssi: d.rssi,
              isLear: isLear,
              services: d.services,
            ),
          );
        });
        try {
          // Filter in Dart only: Android's native name-prefix filter is
          // case-sensitive, and showAll needs every advertisement anyway.
          await UniversalBle.startScan();
          _scanActive = true;
          _scanTimer = Timer(timeout, () => stopScan());
        } catch (e) {
          controller.addError(_mapError(e));
          await stopScan();
        }
      },
      onCancel: () => stopScan(),
    );
    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    await _scanSub?.cancel();
    _scanSub = null;
    final results = _scanResults;
    _scanResults = null;
    // stopScan is reached from the timeout, the picker closing and connect();
    // only the first call should reach Android, which otherwise logs
    // "could not find callback wrapper" for a scan that is already stopped.
    if (_scanActive) {
      _scanActive = false;
      try {
        await UniversalBle.stopScan();
      } catch (_) {
        // Bluetooth went off mid-scan; nothing to undo.
      }
    }
    if (results != null && !results.isClosed) await results.close();
  }

  @override
  Future<LinkInfo> connect(DiscoveredDevice device, BleConfig config) async {
    await stopScan();
    await _teardownLink();
    _config = config;
    _deviceId = device.id;
    _deviceName = device.name;
    _closingOnPurpose = false;
    final id = device.id;

    try {
      await UniversalBle.connect(id, timeout: _connectTimeout);
    } catch (e) {
      _deviceId = null;
      throw _mapError(e, connecting: true);
    }

    try {
      if (Platform.isAndroid) {
        // LE Secure Connections with passkey: Android shows its own dialog
        // where the person types the code from the handheld's screen.
        final paired = await UniversalBle.isPaired(id, timeout: _opTimeout);
        if (paired != true) await UniversalBle.pair(id, timeout: _pairTimeout);
      }

      int? mtu;
      try {
        mtu = await UniversalBle.requestMtu(id, kDesiredMtu, timeout: _opTimeout);
      } catch (_) {
        // iOS negotiates the MTU itself; a refusal here is not fatal.
      }

      final services = await UniversalBle.discoverServices(id, timeout: _opTimeout);
      final service = services.where((s) => s.uuid == config.serviceUuid.toLowerCase()).firstOrNull;
      if (service == null) throw BleFailure(BleFailureKind.notLearDevice, deviceName: device.name);
      final chars = {for (final c in service.characteristics) c.uuid};
      for (final required in [config.txUuid, config.rxUuid, config.statusUuid]) {
        if (!chars.contains(required.toLowerCase())) {
          throw BleFailure(BleFailureKind.notLearDevice, deviceName: device.name);
        }
      }

      var version = kLegacyProtocolVersion;
      if (chars.contains(config.versionUuid.toLowerCase())) {
        version = decodeProtocolVersion(
          await UniversalBle.read(
            id,
            config.serviceUuid,
            config.versionUuid,
            // On iOS this first encrypted read triggers pairing.
            timeout: _pairTimeout,
          ),
        );
      }

      _linkSubs
        ..add(UniversalBle.characteristicValueStream(id, config.rxUuid).listen(_rx.add))
        ..add(
          UniversalBle.characteristicValueStream(id, config.statusUuid).listen((bytes) {
            final s = decodeNodeStatus(bytes);
            if (s != null) _status.add(s);
          }),
        )
        ..add(
          UniversalBle.connectionStream(id).listen((connected) {
            if (!connected) _onLinkDown();
          }),
        );

      await UniversalBle.subscribeNotifications(
        id,
        config.serviceUuid,
        config.rxUuid,
        timeout: _pairTimeout,
      );
      await UniversalBle.subscribeNotifications(
        id,
        config.serviceUuid,
        config.statusUuid,
        timeout: _opTimeout,
      );

      NodeStatus? status;
      try {
        status = decodeNodeStatus(
          await UniversalBle.read(id, config.serviceUuid, config.statusUuid, timeout: _opTimeout),
        );
        if (status != null) _status.add(status);
      } catch (_) {
        // A notification will bring the status later.
      }

      return LinkInfo(device: device, protocolVersion: version, status: status, mtu: mtu);
    } catch (e) {
      _closingOnPurpose = true;
      await _teardownLink();
      try {
        await UniversalBle.disconnect(id);
      } catch (_) {}
      _deviceId = null;
      throw e is BleFailure ? e : _mapError(e);
    }
  }

  void _onLinkDown() {
    if (_closingOnPurpose || _deviceId == null) return;
    _deviceId = null;
    unawaited(_teardownLink());
    _disconnected.add(null);
  }

  Future<void> _teardownLink() async {
    final subs = List.of(_linkSubs);
    _linkSubs.clear();
    for (final s in subs) {
      await s.cancel();
    }
  }

  @override
  Future<void> disconnect() async {
    final id = _deviceId;
    _closingOnPurpose = true;
    _deviceId = null;
    await _teardownLink();
    if (id == null) return;
    try {
      await UniversalBle.disconnect(id);
    } catch (_) {
      // The link may already be gone.
    }
  }

  @override
  Future<void> write(Uint8List payload) async {
    final id = _deviceId;
    if (id == null) throw BleFailure(BleFailureKind.connectionLost, deviceName: _deviceName);
    try {
      await UniversalBle.write(
        id,
        _config.serviceUuid,
        _config.txUuid,
        payload,
        timeout: _opTimeout,
      );
    } catch (e) {
      throw BleFailure(BleFailureKind.writeFailed, deviceName: _deviceName, cause: e);
    }
  }

  BleFailure _mapError(Object e, {bool connecting = false}) {
    if (e is BleFailure) return e;
    final name = _deviceName;
    if (e is TimeoutException) {
      return BleFailure(BleFailureKind.outOfRange, deviceName: name, cause: e);
    }
    if (e is UniversalBleException) {
      final kind = switch (e.code) {
        UniversalBleErrorCode.bluetoothNotEnabled ||
        UniversalBleErrorCode.bluetoothNotAvailable => BleFailureKind.bluetoothOff,
        UniversalBleErrorCode.bluetoothNotAllowed ||
        UniversalBleErrorCode.bluetoothUnauthorized => BleFailureKind.permissionDenied,
        UniversalBleErrorCode.pairingCancelled => BleFailureKind.pairingCancelled,
        UniversalBleErrorCode.pairingFailed ||
        UniversalBleErrorCode.pairingTimeout ||
        UniversalBleErrorCode.pairingNotAllowed ||
        UniversalBleErrorCode.notPaired ||
        UniversalBleErrorCode.notPairable ||
        UniversalBleErrorCode.authenticationFailure ||
        UniversalBleErrorCode.insufficientAuthentication ||
        UniversalBleErrorCode.insufficientEncryption ||
        UniversalBleErrorCode.insufficientKeySize => BleFailureKind.pairingFailed,
        UniversalBleErrorCode.serviceNotFound ||
        UniversalBleErrorCode.characteristicNotFound => BleFailureKind.notLearDevice,
        UniversalBleErrorCode.connectionTimeout ||
        UniversalBleErrorCode.deviceNotFound ||
        UniversalBleErrorCode.operationTimeout => BleFailureKind.outOfRange,
        UniversalBleErrorCode.connectionFailed ||
        UniversalBleErrorCode.connectionRejected ||
        UniversalBleErrorCode.connectionTerminated ||
        UniversalBleErrorCode.deviceDisconnected =>
          connecting ? BleFailureKind.outOfRange : BleFailureKind.connectionLost,
        _ => BleFailureKind.unknown,
      };
      return BleFailure(kind, deviceName: name, cause: e);
    }
    return BleFailure(
      connecting ? BleFailureKind.outOfRange : BleFailureKind.unknown,
      deviceName: name,
      cause: e,
    );
  }

  @override
  Future<void> dispose() async {
    await stopScan();
    await disconnect();
    await _rx.close();
    await _status.close();
    await _disconnected.close();
  }
}
