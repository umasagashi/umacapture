// Verifies that all saved record.json files decode with dart_mappable (non-destructive, read-only).
// Run: .fvm/flutter_sdk/bin/flutter test test/decode_records_test.dart
//
// Note: this test references local real data (~/Documents/umacapture/...) for migration verification.
// It is skipped in environments without that data.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/core/mapper_init.dart';

void main() {
  test('all stored record.json decode via dart_mappable', () {
    initializeMappers();
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME']!;
    final active = Directory('$home/Documents/umacapture/storage/chara_detail/active');
    if (!active.existsSync()) {
      // ignore: avoid_print
      print('active dir not found, skipping: ${active.path}');
      return;
    }
    int ok = 0;
    final failures = <String>[];
    for (final dir in active.listSync().whereType<Directory>()) {
      final f = File('${dir.path}/record.json');
      if (!f.existsSync()) continue;
      try {
        final r = CharaDetailRecordMapper.fromJson(f.readAsStringSync());
        r.metadata.recordType;
        r.skills.length;
        r.factors.flattened.length;
        r.races.length;
        ok++;
      } catch (e) {
        failures.add('${dir.path}: $e');
      }
    }
    // ignore: avoid_print
    print('=== decode result: OK=$ok, NG=${failures.length} ===');
    for (final m in failures.take(10)) {
      // ignore: avoid_print
      print('DECODE FAILED: $m');
    }
    expect(failures, isEmpty);
  });
}
