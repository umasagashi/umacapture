// Verifies the bulk record loader that fans record decoding out across worker
// isolates: every record directory is loaded (regardless of how it is split
// into chunks), non-directory entries in the root are skipped rather than
// quarantined, a corrupt record yields a RecordQuarantined alongside the
// successfully loaded ones, and a record stored in an older format is upgraded
// on disk.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_bulk_load_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/web_record_write_transaction.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/riverpod.dart';

Character _chara(int card) => Character(0, 0, card, 0, null);

Parent _parent(int card) => Parent(_chara(card), _chara(0), _chara(0), null);

// Builds a decodable record with the given id; everything else is dummy.
// Mirrors the minimal builder in factor_probe_match_test.dart.
CharaDetailRecord makeRecord({required String id}) {
  final metadata = Metadata(
    recordFormatVersion,
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

    final (:results, :unavailable) = await loadAllCharaDetailRecord(
      ProviderContainer.test().read(containerRefProvider),
      activeDir,
    );

    final loadedIds = results.whereType<RecordLoaded>().map((e) => e.record.id).toSet();
    expect(loadedIds, ids.toSet());
    expect(results.whereType<RecordQuarantined>(), isEmpty);
    // The desktop scan takes no record lock, so it can never refuse a record.
    expect(unavailable, isEmpty);
  });

  test('skips non-directory entries in the root instead of quarantining them', () async {
    seedValidRecord('id-001');
    File('${activeDir.path}/desktop.ini').writeAsStringSync('[.ShellClassInfo]');

    final (:results, :unavailable) = await loadAllCharaDetailRecord(
      ProviderContainer.test().read(containerRefProvider),
      activeDir,
    );

    expect(results, hasLength(1));
    expect(results.single, isA<RecordLoaded>());
    expect(unavailable, isEmpty);
    // The stray file is left in place, not moved into a quarantine folder.
    expect(File('${activeDir.path}/desktop.ini').existsSync(), isTrue);
    expect(Directory('${tempRoot.path}/quarantine').existsSync(), isFalse);
  });

  test('returns empty when the root holds no directories', () async {
    File('${activeDir.path}/desktop.ini').writeAsStringSync('[.ShellClassInfo]');

    final (:results, :unavailable) = await loadAllCharaDetailRecord(
      ProviderContainer.test().read(containerRefProvider),
      activeDir,
    );
    expect(results, isEmpty);
    expect(unavailable, isEmpty);
  });

  test('a corrupt record is quarantined without affecting the valid ones', () async {
    seedValidRecord('id-001');
    seedValidRecord('id-002');
    seedRecordJson('id-corrupt', 'not valid json');

    final (:results, :unavailable) = await loadAllCharaDetailRecord(
      ProviderContainer.test().read(containerRefProvider),
      activeDir,
    );

    expect(results, hasLength(3));
    expect(results.whereType<RecordLoaded>().map((e) => e.record.id).toSet(), {'id-001', 'id-002'});
    // A record that cannot be decoded is quarantined, never reported unavailable.
    expect(unavailable, isEmpty);
    final quarantined = results.whereType<RecordQuarantined>().single;
    expect(quarantined.destination, isNotNull);
    expect(quarantined.destination!.name, 'id-corrupt');
    // The corrupt record was moved aside into the sibling quarantine folder.
    expect(Directory('${activeDir.path}/id-corrupt').existsSync(), isFalse);
    expect(File('${tempRoot.path}/quarantine/id-corrupt/record.json').existsSync(), isTrue);
  });

  // A major-1 record (the recognizer stored skill levels and support card ranks one above what the game
  // shows) is upgraded on disk by the scan that finds it. `chara_detail_record_v1.json` is such a record as a
  // major-1 recognizer wrote it; `chara_detail_record.json` is the same capture in the current format.
  group('a record stored in an older format', () {
    const id = '9a1e0d66-0654-4416-aa11-5613e7a9f05e';
    final v1Json = File('test/fixtures/chara_detail_record_v1.json').readAsStringSync();
    final current = File('test/fixtures/chara_detail_record.json').readAsStringSync();
    late DirectoryPath charaDetailDir;

    setUp(() => charaDetailDir = DirectoryPath(tempRoot.path) / 'storage' / 'chara_detail');

    File recordJsonOf(String store) => File('${(charaDetailDir / store / id).path}/record.json');

    void seed(String store, String recordJson) {
      final dir = Directory((charaDetailDir / store / id).path)..createSync(recursive: true);
      File('${dir.path}/record.json').writeAsStringSync(recordJson);
      File('${dir.path}/skill.png').writeAsBytesSync([1, 2, 3]);
    }

    Future<List<CharaDetailRecord>> scan(String store) async {
      final (:results, :unavailable) = await loadAllCharaDetailRecord(
        ProviderContainer.test().read(containerRefProvider),
        charaDetailDir / store,
      );
      expect(unavailable, isEmpty);
      return results.whereType<RecordLoaded>().map((e) => e.record).toList();
    }

    CharaDetailRecord onDisk(String store) => CharaDetailRecordMapper.fromJson(recordJsonOf(store).readAsStringSync());

    test('is upgraded on disk by the scan, with its other files kept', () async {
      seed('active', v1Json);

      final loaded = await scan('active');

      final expected = CharaDetailRecordMapper.fromJson(current);
      expect(loaded, [expected]);
      expect(onDisk('active'), expected);
      expect(onDisk('active').skills.first.level, 5);
      expect(onDisk('active').supportCards.map((c) => c.rank), [4, 4, 2, 4, 4, 4]);
      expect(File('${(charaDetailDir / 'active' / id).path}/skill.png').readAsBytesSync(), [1, 2, 3]);
      // Only record.json was replaced: no staging file beside it and no transaction under the store.
      final names = Directory((charaDetailDir / 'active' / id).path).listSync().map((e) => e.uri.pathSegments.last);
      expect(names, unorderedEquals(['record.json', 'skill.png']));
      expect(
        Directory('${charaDetailDir.path}/${WebRecordWriteTransaction.transactionRootName}').existsSync(),
        isFalse,
      );
    });

    test('takes over the staging file an interrupted upgrade left', () async {
      seed('active', v1Json);
      final staging = File('${(charaDetailDir / 'active' / id).path}/${CharaDetailRecord.recordJsonReplacementName}');
      staging.writeAsStringSync('{"torn');

      final loaded = await scan('active');

      expect(loaded, [CharaDetailRecordMapper.fromJson(current)]);
      expect(onDisk('active'), CharaDetailRecordMapper.fromJson(current));
      expect(staging.existsSync(), isFalse);
    });

    test('in the current format is left byte for byte', () async {
      seed('active', current);
      final before = recordJsonOf('active').readAsBytesSync();

      await scan('active');

      expect(recordJsonOf('active').readAsBytesSync(), before);
    });

    test('is not taken down a second time by a second scan', () async {
      seed('active', v1Json);

      await scan('active');
      final loaded = await scan('active');

      final expected = CharaDetailRecordMapper.fromJson(current);
      expect(loaded, [expected]);
      expect(onDisk('active'), expected);
    });

    test('in the archive store is upgraded by the archive scan', () async {
      seed('archive', v1Json);

      await scan('archive');

      expect(onDisk('archive'), CharaDetailRecordMapper.fromJson(current));
    });

    test('keeps rank 0 on the cards the recognizer never read', () async {
      // The recognizer zeroes all six cards when it cannot find the support card area, without adding one.
      final map = jsonDecode(v1Json) as Map<String, dynamic>;
      map['support_cards'] = [
        for (var i = 0; i < 6; i++) {'id': 0, 'rank': 0, 'level': 0},
      ];
      seed('active', jsonEncode(map));

      await scan('active');

      expect(onDisk('active').supportCards.map((c) => c.rank), everyElement(0));
      expect(onDisk('active').metadata.formatVersion, recordFormatVersion);
    });
  });
}
