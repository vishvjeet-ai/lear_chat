/// Failures the connection layer reports to the UI, each with a message that
/// says what went wrong and how to fix it.
library;

enum BleFailureKind {
  bluetoothOff,
  bluetoothUnsupported,
  permissionDenied,
  permissionPermanentlyDenied,
  outOfRange,
  pairingFailed,
  pairingCancelled,
  notLearDevice,
  connectionLost,
  writeFailed,
  unknown,
}

class BleFailure implements Exception {
  BleFailure(this.kind, {String? deviceName, this.cause})
    : message = messageFor(kind, deviceName: deviceName);

  final BleFailureKind kind;
  final String message;
  final Object? cause;

  /// Whether the fix is in the system app settings.
  bool get opensSettings => kind == BleFailureKind.permissionPermanentlyDenied;

  /// Whether the app can offer to turn Bluetooth on.
  bool get canEnableBluetooth => kind == BleFailureKind.bluetoothOff;

  static String messageFor(BleFailureKind kind, {String? deviceName}) {
    final device = deviceName ?? 'the handheld';
    return switch (kind) {
      BleFailureKind.bluetoothOff => 'Bluetooth is off. Turn it on to connect.',
      BleFailureKind.bluetoothUnsupported =>
        "This phone doesn't support Bluetooth Low Energy, so it can't talk to a handheld.",
      BleFailureKind.permissionDenied =>
        'LEAR Chat needs the Nearby devices permission to find your handheld. Allow it and try again.',
      BleFailureKind.permissionPermanentlyDenied =>
        'Nearby devices permission is turned off. Open Settings, allow it for LEAR Chat, then try again.',
      BleFailureKind.outOfRange =>
        "Couldn't reach $device. Make sure it's on and nearby, then try again.",
      BleFailureKind.pairingFailed =>
        "Pairing with $device failed. Check the passkey on the handheld's screen and try again.",
      BleFailureKind.pairingCancelled =>
        'Pairing was cancelled. Connect again and enter the passkey shown on the handheld.',
      BleFailureKind.notLearDevice =>
        "This isn't a LEAR handheld, or its firmware is out of date. Update it and try again.",
      BleFailureKind.connectionLost =>
        'Lost the connection to $device. Move closer and tap Connect.',
      BleFailureKind.writeFailed => "The message didn't reach $device. Tap it to retry.",
      BleFailureKind.unknown =>
        'Something went wrong with Bluetooth. Turn Bluetooth off and on, then try again.',
    };
  }

  @override
  String toString() => 'BleFailure(${kind.name}): $message${cause == null ? '' : ' [$cause]'}';
}
