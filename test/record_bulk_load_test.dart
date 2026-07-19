// Verifies the bulk record loader that fans record decoding out across worker
// isolates: every record directory is loaded (regardless of how it is split
// into chunks), non-directory entries in the root are skipped rather than
// quarantined, and a corrupt record yields a RecordQuarantined alongside the
// successfully loaded ones.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_bulk_load_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';

Character _chara(int card) => Character(0, 0, card, 0);

Parent _parent(int card) => Parent(_chara(card), _chara(0), _chara(0), null);

// Builds a decodable record with the given id; everything else is dummy.
// Mirrors the minimal builder in factor_probe_match_test.dart.
CharaDetailRecord makeRecord({required String id}) {
  final metadata = Metadata(
    '1.0.0',
    'JPN',
    RecordId(id, null, null),
    'trainer',
    '2026-01-01T00:00:00+0900',
    '2026-01-01T00:00:00+0900',
    RecordStage.active,
    0,
    null,
    RecordType.standard,
  );
  return CharaDetailRecord(
    metadata,
    _chara(1),
    0,
    const CharacterStatus(0, 0, 0, 0, 0),
    const AptitudeSet(GroundAptitude(0, 0), DistanceAptitude(0, 0, 0, 0), StyleAptitude(0, 0, 0, 0)),
    const <Skill>[],
    const FactorSet([], [], []),
    const <SupportCard>[],
    Family(_parent(0), _parent(0)),
    0,
    const Scenario(0),
    '2026/01/01',
    const <Race>[],
  );
}

void main() {
  setUpAll(initializeMappers);

  late Directory tempRoot;
  late DirectoryPath activeDir;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_bulk_load_test');
    activeDir = DirectoryPath(Directory('${tempRoot.path}/active')..createSync(recursive: true));
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  // Seeds a record directory at <root>/active/<id>/ holding the given
  // record.json content, mirroring the on-disk layout the loader scans.
  void seedRecordJson(String id, String recordJson) {
    final dir = Directory('${activeDir.path}/$id')..createSync(recursive: true);
    File('${dir.path}/record.json').writeAsStringSync(recordJson);
  }

  void seedValidRecord(String id) => seedRecordJson(id, jsonEncode(makeRecord(id: id).toMap()));

  test('loads every record, regardless of how they are split into chunks', () async {
    // More records than the worker cap (8), so on a multi-core machine the scan
    // splits into several chunks and the results must be merged across them.
    final ids = [for (var i = 0; i < 20; i++) 'id-$i'];
    for (final id in ids) {
      seedValidRecord(id);
    }

    final results = await loadAllCharaDetailRecord(activeDir);

    final loadedIds = results.whereType<RecordLoaded>().map((e) => e.record.id).toSet();
    expect(loadedIds, ids.toSet());
    expect(results.whereType<RecordQuarantined>(), isEmpty);
  });

  test('skips non-directory entries in the root instead of quarantining them', () async {
    seedValidRecord('id-001');
    File('${activeDir.path}/desktop.ini').writeAsStringSync('[.ShellClassInfo]');

    final results = await loadAllCharaDetailRecord(activeDir);

    expect(results, hasLength(1));
    expect(results.single, isA<RecordLoaded>());
    // The stray file is left in place, not moved into a quarantine folder.
    expect(File('${activeDir.path}/desktop.ini').existsSync(), isTrue);
    expect(Directory('${tempRoot.path}/quarantine').existsSync(), isFalse);
  });

  test('returns empty when the root holds no directories', () async {
    File('${activeDir.path}/desktop.ini').writeAsStringSync('[.ShellClassInfo]');

    expect(await loadAllCharaDetailRecord(activeDir), isEmpty);
  });

  test('a corrupt record is quarantined without affecting the valid ones', () async {
    seedValidRecord('id-001');
    seedValidRecord('id-002');
    seedRecordJson('id-corrupt', 'not valid json');

    final results = await loadAllCharaDetailRecord(activeDir);

    expect(results, hasLength(3));
    expect(results.whereType<RecordLoaded>().map((e) => e.record.id).toSet(), {'id-001', 'id-002'});
    final quarantined = results.whereType<RecordQuarantined>().single;
    expect(quarantined.destination, isNotNull);
    expect(quarantined.destination!.name, 'id-corrupt');
    // The corrupt record was moved aside into the sibling quarantine folder.
    expect(Directory('${activeDir.path}/id-corrupt').existsSync(), isFalse);
    expect(File('${tempRoot.path}/quarantine/id-corrupt/record.json').existsSync(), isTrue);
  });
}
