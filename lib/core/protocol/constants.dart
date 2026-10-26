/// BLE contract constants shared with the handheld firmware.
///
/// See docs/ble-contract.md. Every value here can be overridden at runtime
/// from Settings through [BleConfig].
library;

const String kDefaultServiceUuid = '4c454152-4d45-5348-0001-000000000000';
const String kDefaultTxUuid = '4c454152-4d45-5348-0002-000000000000';
const String kDefaultRxUuid = '4c454152-4d45-5348-0003-000000000000';
const String kDefaultStatusUuid = '4c454152-4d45-5348-0004-000000000000';
const String kDefaultVersionUuid = '4c454152-4d45-5348-0005-000000000000';
const String kDefaultNamePrefix = 'LEAR';

/// Maximum UTF-8 payload of one message, in bytes.
const int kMaxTextBytes = 144;

/// ATT MTU the phone asks for after connecting.
const int kDesiredMtu = 247;

/// Protocol version assumed when the node has no VERSION characteristic.
const int kLegacyProtocolVersion = 1;

/// Protocol version this app speaks natively.
const int kCurrentProtocolVersion = 2;

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// True when [value] is a full 128-bit UUID string (any case).
bool isValidUuid(String value) => _uuidPattern.hasMatch(value.trim().toLowerCase());

/// The UUIDs and advertised name prefix used to find and talk to a handheld.
class BleConfig {
  const BleConfig({
    this.serviceUuid = kDefaultServiceUuid,
    this.txUuid = kDefaultTxUuid,
    this.rxUuid = kDefaultRxUuid,
    this.statusUuid = kDefaultStatusUuid,
    this.versionUuid = kDefaultVersionUuid,
    this.namePrefix = kDefaultNamePrefix,
  });

  final String serviceUuid;
  final String txUuid;
  final String rxUuid;
  final String statusUuid;
  final String versionUuid;
  final String namePrefix;

  BleConfig copyWith({
    String? serviceUuid,
    String? txUuid,
    String? rxUuid,
    String? statusUuid,
    String? versionUuid,
    String? namePrefix,
  }) {
    return BleConfig(
      serviceUuid: serviceUuid ?? this.serviceUuid,
      txUuid: txUuid ?? this.txUuid,
      rxUuid: rxUuid ?? this.rxUuid,
      statusUuid: statusUuid ?? this.statusUuid,
      versionUuid: versionUuid ?? this.versionUuid,
      namePrefix: namePrefix ?? this.namePrefix,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BleConfig &&
      other.serviceUuid == serviceUuid &&
      other.txUuid == txUuid &&
      other.rxUuid == rxUuid &&
      other.statusUuid == statusUuid &&
      other.versionUuid == versionUuid &&
      other.namePrefix == namePrefix;

  @override
  int get hashCode => Object.hash(serviceUuid, txUuid, rxUuid, statusUuid, versionUuid, namePrefix);
}
