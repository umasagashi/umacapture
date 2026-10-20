// Verifies that a record whose `record.json` cannot be decoded is moved aside
// into a sibling `quarantine/` folder instead of being deleted, so its images
// and json survive for later inspection or recovery.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_quarantine_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/record_quarantine_ledger.dart';
import 'package:umacapture/src/core/fs/record_loader.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/long_read_declarations.dart';
import 'support/records.dart';

void main() {
  setUpAll(initializeMappers);

  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_quarantine_test');
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  // Seeds a record at <root>/active/<id>/ with the given record.json content and
  // a dummy image, mirroring the on-disk layout the loader scans.
  DirectoryPath seedRecord(String id, String recordJson) {
    final dir = Directory('${tempRoot.path}/active/$id')..createSync(recursive: true);
    File('${dir.path}/record.json').writeAsStringSync(recordJson);
    File('${dir.path}/trainee.jpg').writeAsStringSync('image-bytes');
    return DirectoryPath(dir);
  }

  test('record missing required fields is quarantined, not deleted', () {
    // `{}` lacks every required field, so the strict dart_mappable decoder
    // throws — the same failure mode a legacy/older-format record can hit.
    final dir = seedRecord('id-001', '{}');

    final result = CharaDetailRecord.load(dir);

    expect(result, isA<RecordQuarantined>());
    // The original active directory is gone (moved, not lingering)...
    expect(Directory(dir.path).existsSync(), isFalse);
    // ...and its contents are preserved under sibling quarantine/<id>.
    final quarantined = Directory('${tempRoot.path}/quarantine/id-001');
    expect(quarantined.existsSync(), isTrue);
    expect(File('${quarantined.path}/record.json').existsSync(), isTrue);
    expect(File('${quarantined.path}/trainee.jpg').readAsStringSync(), 'image-bytes');
    final destination = (result as RecordQuarantined).destination;
    expect(destination, isNotNull);
    expect(destination!.name, 'id-001');
    expect(destination.toDirectory().existsSync(), isTrue);
  });

  test('malformed json is quarantined', () {
    final dir = seedRecord('id-002', 'not valid json');

    expect(CharaDetailRecord.load(dir), isA<RecordQuarantined>());
    expect(Directory('${tempRoot.path}/quarantine/id-002').existsSync(), isTrue);
  });

  test('quarantine is outside the scanned active tree', () {
    final dir = seedRecord('id-003', '{}');

    final destination = CharaDetailRecord.quarantine(dir);

    expect(destination, isNotNull);
    // active/ holds the records the loader scans; quarantine/ is its sibling, so
    // a quarantined record is never re-loaded and re-quarantined on restart.
    expect(destination!.parent.name, 'quarantine');
    expect(dir.parent.name, 'active');
    expect(destination.parent.parent.path, dir.parent.parent.path);
  });

  test('quarantine resolves id collisions with a numeric suffix', () {
    // A record with this id was already quarantined in a previous run.
    Directory('${tempRoot.path}/quarantine/id-004').createSync(recursive: true);
    final dir = seedRecord('id-004', '{}');

    final destination = CharaDetailRecord.quarantine(dir);

    expect(destination, isNotNull);
    expect(destination!.name, 'id-004_1');
    expect(Directory('${tempRoot.path}/quarantine/id-004_1').existsSync(), isTrue);
    expect(Directory(dir.path).existsSync(), isFalse);
  });
  group('C3: a quarantined record is kept by id across a restart, and comes back once it reads again', () {
    late DirectoryPath active;
    late DirectoryPath shelf;

    setUp(() {
      active = DirectoryPath('${tempRoot.path}/storage/chara_detail/active');
      shelf = DirectoryPath('${tempRoot.path}/storage/chara_detail/quarantine');
    });

    Future<List<String>> scanIds() async {
      final scan = await loadRecordsUnder(active, declaration: undeclaredInTest);
      return [
        for (final result in scan.results)
          if (result case RecordLoaded(:final record)) record.id,
      ];
    }

    String body(String id) => jsonEncode(makeRecord(id: id, card: 1).toMap());

    test('quarantined by a scan, noted, still noted after a restart, put back by the scan after the repair', () async {
      for (final id in ['broken', 'fine']) {
        File('${(active / id).path}/record.json')
          ..createSync(recursive: true)
          ..writeAsStringSync(id == 'broken' ? '{' : body(id));
      }

      expect(await scanIds(), ['fine']);
      final noted = (await readQuarantineLedger(shelf)).kept;
      expect(
        [for (final record in noted) (record.id, record.store, record.directory.name)],
        [('broken', 'active', 'broken')],
      );

      // A restart: nothing of the session survives but the files, and the shelf is read from them alone.
      expect([for (final record in (await readQuarantineLedger(shelf)).kept) record.id], ['broken']);
      expect(await scanIds(), ['fine'], reason: 'a record still unreadable stays on the shelf');
      expect([for (final record in (await readQuarantineLedger(shelf)).kept) record.id], ['broken']);

      File('${(shelf / 'broken').path}/record.json').writeAsStringSync(body('broken'));
      expect((await scanIds())..sort(), ['broken', 'fine']);
      expect((await readQuarantineLedger(shelf)).kept, isEmpty);
      expect(File('${(active / 'broken').path}/$quarantineOriginName').existsSync(), isFalse);
    });
  });
}
