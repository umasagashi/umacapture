// Unit tests for the custom dart_mappable mappers that serialize dart:ui /
// material types (Size / Offset / RegExp / ThemeMode). These guard the
// encode<->decode round-trip; a regression here silently corrupts persisted
// window geometry, theme mode, or saved regex filters.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/json_adapter_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/json_adapter.dart';

void main() {
  group('SizeMapper', () {
    const mapper = SizeMapper();

    test('round-trips width and height', () {
      const size = Size(12.5, 34.0);
      final encoded = mapper.encode(size);
      expect(encoded, {'width': 12.5, 'height': 34.0});
      expect(mapper.decode(encoded), size);
    });

    test('decodes integer JSON numbers via toDouble', () {
      expect(mapper.decode({'width': 3, 'height': 4}), const Size(3, 4));
    });
  });

  group('OffsetMapper', () {
    const mapper = OffsetMapper();

    test('round-trips dx and dy', () {
      const offset = Offset(-5.5, 7.0);
      final encoded = mapper.encode(offset);
      expect(encoded, {'dx': -5.5, 'dy': 7.0});
      expect(mapper.decode(encoded), offset);
    });
  });

  group('RegExpMapper', () {
    const mapper = RegExpMapper();

    test('round-trips the pattern string', () {
      final source = RegExp(r'^foo\d+$');
      expect(mapper.encode(source), r'^foo\d+$');
      expect(mapper.decode(mapper.encode(source)).pattern, source.pattern);
    });

    test('preserves only the pattern, not flags (documented limitation)', () {
      final decoded = mapper.decode(mapper.encode(RegExp('a', caseSensitive: false)));
      expect(decoded.isCaseSensitive, isTrue, reason: 'the case-insensitive flag is not serialized');
    });
  });

  group('ThemeModeMapper', () {
    const mapper = ThemeModeMapper();

    test('round-trips every ThemeMode by name', () {
      for (final mode in ThemeMode.values) {
        expect(mapper.encode(mode), mode.name);
        expect(mapper.decode(mode.name), mode);
      }
    });

    test('throws on an unknown name', () {
      expect(() => mapper.decode('not_a_mode'), throwsStateError);
    });
  });
}
