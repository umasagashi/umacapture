// Regression test for the dart_mappable migration of the Hive-stored enums.
// The pre-dart_mappable JsonAdapter serialized every enum with CaseStyle.snake
// (e.g. "skill_plain"). The new @MappableEnum must keep decoding those exact
// strings, otherwise a user's previously-saved multi-word setting throws
// MapperException.unknownEnumValue on read and crashes the provider build.
// Run: .fvm/flutter_sdk/bin/flutter test test/hive_enum_compat_test.dart
import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/clipboard_alt.dart';
import 'package:umacapture/src/core/mapper_init.dart';

void main() {
  setUpAll(initializeMappers);

  group('CharaDetailRecordImageMode decodes legacy snake_case values', () {
    // These are the literal strings the old dart_json_mapper adapter persisted.
    const legacy = {
      '"none"': CharaDetailRecordImageMode.none,
      '"skill_plain"': CharaDetailRecordImageMode.skillPlain,
      '"factor_plain"': CharaDetailRecordImageMode.factorPlain,
      '"campaign_plain"': CharaDetailRecordImageMode.campaignPlain,
    };
    legacy.forEach((stored, expected) {
      test('$stored -> $expected', () {
        expect(MapperContainer.globals.fromJson<CharaDetailRecordImageMode>(stored), expected);
      });
    });

    test('round-trips back to snake_case so newly-written data stays compatible', () {
      final json = MapperContainer.globals.toJson<CharaDetailRecordImageMode>(CharaDetailRecordImageMode.campaignPlain);
      expect(json, '"campaign_plain"');
    });
  });

  group('ClipboardPasteImageMode round-trips', () {
    test('single-word values are identical in either case style', () {
      for (final value in ClipboardPasteImageMode.values) {
        final json = MapperContainer.globals.toJson<ClipboardPasteImageMode>(value);
        expect(MapperContainer.globals.fromJson<ClipboardPasteImageMode>(json), value);
      }
    });
  });
}
