import 'constants.dart';

/// Number of bytes [text] takes when encoded as UTF-8, without allocating.
///
/// Matches `utf8.encode(text).length`, including unpaired surrogates, which
/// the encoder replaces with U+FFFD (3 bytes).
int utf8ByteLength(String text) {
  var bytes = 0;
  for (final rune in text.runes) {
    if (rune < 0x80) {
      bytes += 1;
    } else if (rune < 0x800) {
      bytes += 2;
    } else if (rune < 0x10000) {
      bytes += 3;
    } else {
      bytes += 4;
    }
  }
  return bytes;
}

/// True when [text] fits in one message.
bool fitsMessageLimit(String text, {int limit = kMaxTextBytes}) => utf8ByteLength(text) <= limit;
