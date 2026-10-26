import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lear_chat/core/protocol/constants.dart';
import 'package:lear_chat/core/protocol/node_id.dart';
import 'package:lear_chat/core/protocol/utf8_limit.dart';

void main() {
  group('utf8ByteLength', () {
    const samples = [
      '',
      'hello',
      'café', // 2-byte é
      '日本語', // 3-byte CJK
      '😀', // 4-byte emoji, a surrogate pair in Dart
      '👩‍👩‍👧', // ZWJ sequence: several code points, one glyph
      '🇪🇨', // flag: two regional indicators
      'é', // e + combining accent
      'mixed ascii é 日 😀',
    ];

    for (final s in samples) {
      test('matches utf8.encode for "$s"', () {
        expect(utf8ByteLength(s), utf8.encode(s).length);
      });
    }

    test('counts bytes, not characters', () {
      expect('😀'.length, 2); // UTF-16 code units
      expect('😀'.runes.length, 1);
      expect(utf8ByteLength('😀'), 4);
      expect(utf8ByteLength('👩‍👩‍👧'), 18);
    });

    test('unpaired surrogate counts as the 3-byte replacement character', () {
      final lone = String.fromCharCode(0xD83D);
      expect(utf8ByteLength(lone), utf8.encode(lone).length);
    });
  });

  group('144-byte limit', () {
    test('ASCII: 144 fits, 145 does not', () {
      expect(fitsMessageLimit('a' * 144), isTrue);
      expect(fitsMessageLimit('a' * 145), isFalse);
    });

    test('emoji: 36 fit (144 bytes), 37 do not', () {
      expect(utf8ByteLength('😀' * 36), kMaxTextBytes);
      expect(fitsMessageLimit('😀' * 36), isTrue);
      expect(fitsMessageLimit('😀' * 37), isFalse);
    });

    test('CJK: 48 fit, 49 do not', () {
      expect(fitsMessageLimit('語' * 48), isTrue);
      expect(fitsMessageLimit('語' * 49), isFalse);
    });

    test('mixed text at the boundary', () {
      final text = '${'a' * 140}😀'; // 140 + 4
      expect(utf8ByteLength(text), 144);
      expect(fitsMessageLimit(text), isTrue);
      expect(fitsMessageLimit('${text}a'), isFalse);
    });

    test('ZWJ family at the boundary', () {
      final text = '${'a' * 126}👩‍👩‍👧'; // 126 + 18
      expect(fitsMessageLimit(text), isTrue);
      expect(fitsMessageLimit('a$text'), isFalse);
    });
  });

  group('node IDs', () {
    test('formats as 4 uppercase hex digits', () {
      expect(formatNodeId(0), '0000');
      expect(formatNodeId(0xAB), '00AB');
      expect(formatNodeId(0xFFFF), 'FFFF');
      expect(defaultContactName(0x1A2B), 'Node 1A2B');
    });

    test('parses valid input', () {
      expect(parseNodeId('0000'), 0);
      expect(parseNodeId('ffff'), 0xFFFF);
      expect(parseNodeId(' 00aB '), 0xAB);
      expect(parseNodeId('0x1F'), 0x1F);
      expect(parseNodeId('A'), 0xA);
    });

    test('rejects invalid input', () {
      for (final bad in ['', '10000', 'G123', '12 34', '-1', '0x', 'xyz']) {
        expect(parseNodeId(bad), isNull, reason: bad);
      }
    });
  });

  test('UUID validation', () {
    expect(isValidUuid(kDefaultServiceUuid), isTrue);
    expect(isValidUuid(kDefaultServiceUuid.toUpperCase()), isTrue);
    expect(isValidUuid('4c454152-4d45-5348-0001'), isFalse);
    expect(isValidUuid('not-a-uuid'), isFalse);
  });
}
