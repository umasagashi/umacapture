// Guards the `record-load-deletes-on-failure` boundary while the storage/IO
// layer is being ported to an async-first FS backend (wasm PoC stage 5).
//
// `CharaDetailRecord.load` reads `record.json` through the FS backend and then
// either returns a `RecordLoaded` (decode succeeded) or quarantines the record
// (decode failed) — it never deletes. This test pins that decode/quarantine
// contract so the async-first refactor cannot silently change it: seeding a
// valid fixture must decode and round-trip; a malformed one must quarantine,
// not vanish.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_decode_roundtrip_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';

void main() {
  setUpAll(initializeMappers);

  late Directory tempRoot;
  final validRecordJson = File('test/fixtures/chara_detail_record.json').readAsStringSync();

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_decode_roundtrip_test');
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  // Seeds a record at <root>/active/<id>/record.json, mirroring the on-disk
  // layout the loader scans.
  DirectoryPath seedRecord(String id, String recordJson) {
    final dir = Directory('${tempRoot.path}/active/$id')..createSync(recursive: true);
    File('${dir.path}/record.json').writeAsStringSync(recordJson);
    return DirectoryPath(dir);
  }

  test('a valid record decodes via load and round-trips through the mapper', () {
    final dir = seedRecord('9a1e0d66-0654-4416-aa11-5613e7a9f05e', validRecordJson);

    final result = CharaDetailRecord.load(dir);

    expect(result, isA<RecordLoaded>());
    final record = (result as RecordLoaded).record;
    // Re-encoding then decoding yields an equal record: the decode path the
    // loader takes is lossless and stable.
    final reDecoded = CharaDetailRecordMapper.fromJson(record.toJson());
    expect(reDecoded, record);
    // The active directory is left in place (loaded, not quarantined/deleted).
    expect(Directory(dir.path).existsSync(), isTrue);
  });

  test('a malformed record is quarantined, not deleted', () {
    final dir = seedRecord('id-bad', 'not valid json');

    final result = CharaDetailRecord.load(dir);

    expect(result, isA<RecordQuarantined>());
    expect(Directory(dir.path).existsSync(), isFalse);
    expect(Directory('${tempRoot.path}/quarantine/id-bad').existsSync(), isTrue);
    expect(File('${tempRoot.path}/quarantine/id-bad/record.json').existsSync(), isTrue);
  });
}
