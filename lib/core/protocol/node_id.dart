/// 16-bit mesh node IDs, shown to people as 4 uppercase hex digits.
library;

final RegExp _hexId = RegExp(r'^(0x)?[0-9a-f]{1,4}$', caseSensitive: false);

/// Formats [id] as `00AB`.
String formatNodeId(int id) => (id & 0xFFFF).toRadixString(16).toUpperCase().padLeft(4, '0');

/// Parses user input such as `00ab`, `AB` or `0x00AB`. Returns null when
/// the input is not a hex number from 0000 to FFFF.
int? parseNodeId(String input) {
  final value = input.trim();
  if (!_hexId.hasMatch(value)) return null;
  final digits = value.toLowerCase().startsWith('0x') ? value.substring(2) : value;
  return int.parse(digits, radix: 16);
}

/// Default name for a contact created from an unknown sender.
String defaultContactName(int id) => 'Node ${formatNodeId(id)}';
