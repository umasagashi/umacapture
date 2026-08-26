// One record id belongs to one store.
//
// The record zip packs every record under `chara_detail/active/<id>/` whatever
// store it was exported from, so re-importing a zip taken from the archive view
// used to write a second copy of an archived record into `active/` — reported as
// a plain success, with the archived copy still in place. From then on the id
// existed in two stores at once, which `storage.dart` states elsewhere is
// impossible, and inheritance write-back resolved to whichever copy it happened
// to find.
//
// These tests pin the invariant itself ("no id in two stores"), the refusal that
// upholds it at the layer that owns publishing — so it covers live harvest and
// regeneration too, not only zip import — and the negative controls that stop a
// "refuse everything" or "abort the whole zip" implementation from passing.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_id_collision_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/record_zip.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/web_record_persistence.dart';
import 'package:umacapture/src/core/fs/web_record_write_transaction.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/web_like_fs_backend.dart';

void main() {
  late Directory tempRoot;
  late DirectoryPath storageDir;
  late DirectoryPath dataRoot;
  late FsBackend originalBackend;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_record_id_collision');
    storageDir = DirectoryPath(tempRoot.path) / 'storage';
    dataRoot = storageDir / 'chara_detail';
    originalBackend = fsBackend;
    // The publish is an OPFS write on web, so it runs against `WebLikeFsBackend`:
    // a sync FS call added here fails on the VM instead of breaking only on web.
    // That pins OPFS's *synchronous* prohibition and nothing else -- see
    // `support/web_like_fs_backend.dart` for what this backend does not model.
    fsBackend = WebLikeFsBackend(originalBackend);
  });

  tearDown(() {
    fsBackend = originalBackend;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  Future<void> seedArchived(String id) async {
    final dir = dataRoot / 'archive' / id;
    await dir.create(recursive: true);
    await dir.filePath('record.json').writeAsBytes(_recordJson(id));
    await dir.filePath('trainee.jpg').writeAsBytes(Uint8List.fromList([9, 9, 9]));
  }

  group('publish refuses an id another store already holds', () {
    test('an archived record is not republished into active', () async {
      await seedArchived('record-1');

      final result = await WebRecordWriteTransaction().publish(dataRoot, 'record-1', [
        (relativeSegments: ['record.json'], bytes: _recordJson('record-1')),
      ]);

      expect(result, WebRecordWriteResult.blockedByOtherStore);
      expect(result.isCommitted, isFalse);
      expect(await (dataRoot / 'active' / 'record-1').exists(), isFalse);
      // Refused before anything is staged: no slot is left to be recovered.
      expect(await (dataRoot / WebRecordWriteTransaction.transactionRootName).exists(), isFalse);
      // The copy that already existed is untouched, byte for byte.
      expect(await (dataRoot / 'archive' / 'record-1').filePath('record.json').readAsBytes(), _recordJson('record-1'));
      expect(await (dataRoot / 'archive' / 'record-1').filePath('trainee.jpg').readAsBytes(), [9, 9, 9]);
      await expectNoIdInTwoStores(dataRoot);
    });

    // Positive control for the assertion above: the same publish, with no other
    // store holding the id, still writes the record. Without this a transaction
    // that refused everything would pass.
    test('positive control: the same publish succeeds when no other store holds the id', () async {
      final result = await WebRecordWriteTransaction().publish(dataRoot, 'record-1', [
        (relativeSegments: ['record.json'], bytes: _recordJson('record-1')),
      ]);

      expect(result, WebRecordWriteResult.completed);
      expect(await (dataRoot / 'active' / 'record-1').filePath('record.json').readAsBytes(), _recordJson('record-1'));
      await expectNoIdInTwoStores(dataRoot);
    });

    test('the refusal reaches the caller with its reason, not as a silent skip', () async {
      await seedArchived('record-1');

      final result = await WebRecordPersistence().persistFiles(storageDir, [
        (recordId: 'record-1', relativeSegments: ['record.json'], bytes: _recordJson('record-1')),
      ]);

      expect(result.committed('record-1'), isFalse);
      expect(result.statuses['record-1'], WebRecordPersistenceStatus.failed);
      expect(result.failures['record-1'], WebRecordWriteResult.blockedByOtherStore);
    });
  });

  group('archive-sourced zip import', () {
    // The V-exec B3 construction: a zip produced from the archive view carries
    // `chara_detail/active/<id>/`, because the `active/` segment is a fixed part
    // of the interchange format.
    test('does not create a second copy of an archived record', () async {
      await seedArchived('record-1');

      final result = await RecordZipService.import(
        _zip({
          'chara_detail/active/record-1/record.json': _recordJson('record-1'),
          'chara_detail/active/record-1/trainee.jpg': Uint8List.fromList([1, 2, 3]),
        }),
        storageDir,
      );

      expect(result.recordIds, isEmpty);
      expect(await (dataRoot / 'active' / 'record-1').exists(), isFalse);
      expect(await (dataRoot / 'archive' / 'record-1').filePath('trainee.jpg').readAsBytes(), [9, 9, 9]);
      await expectNoIdInTwoStores(dataRoot);
    });

    // V-exec's own negative control: a zip whose records really are active
    // imports exactly as before. This is what a "refuse every import" fix fails.
    test('negative control: an active-sourced zip still imports', () async {
      final result = await RecordZipService.import(
        _zip({'chara_detail/active/record-2/record.json': _recordJson('record-2')}),
        storageDir,
      );

      expect(result.recordIds, {'record-2'});
      expect(await (dataRoot / 'active' / 'record-2').filePath('record.json').readAsBytes(), _recordJson('record-2'));
      await expectNoIdInTwoStores(dataRoot);
    });

    // One colliding record must not cost the user the rest of the zip. This is
    // what an implementation that threw and aborted the whole import fails.
    test('a mixed zip imports the records that do not collide', () async {
      await seedArchived('record-1');

      final result = await RecordZipService.import(
        _zip({
          'chara_detail/active/record-1/record.json': _recordJson('record-1'),
          'chara_detail/active/record-2/record.json': _recordJson('record-2'),
        }),
        storageDir,
      );

      expect(result.recordIds, {'record-2'});
      expect(await (dataRoot / 'active' / 'record-1').exists(), isFalse);
      expect(await (dataRoot / 'active' / 'record-2').exists(), isTrue);
      await expectNoIdInTwoStores(dataRoot);
    });
  });

  test('the store set the checks enumerate contains the store they publish into', () {
    // Both checks skip `activeStoreName` while iterating `recordStoreNames`; if
    // the two ever stopped agreeing the guard would refuse every publish.
    // (The recovery side's use of the same helper is pinned by
    // `web_record_write_repair_test.dart`.)
    expect(WebRecordWriteTransaction.recordStoreNames, contains(WebRecordWriteTransaction.activeStoreName));
    expect(WebRecordWriteTransaction.recordStoreNames.length, greaterThan(1));
  });
}

/// The invariant itself: no record id appears in more than one record store.
///
/// Enumerates the stores from [WebRecordWriteTransaction.recordStoreNames]
/// rather than naming `active` and `archive`, so a store added there is checked
/// here without editing this assertion.
Future<void> expectNoIdInTwoStores(DirectoryPath dataRoot) async {
  final seen = <String, String>{};
  for (final store in WebRecordWriteTransaction.recordStoreNames) {
    final dir = dataRoot / store;
    if (!await dir.exists()) continue;
    await for (final entry in dir.list(recursive: false, followLinks: false)) {
      if (await entry.isFile()) continue;
      final id = entry.asDirectoryPath.name;
      final other = seen[id];
      expect(other, isNull, reason: 'record "$id" exists in both the $other and $store stores');
      seen[id] = store;
    }
  }
}

Uint8List _recordJson(String id) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'metadata': {
        'record_id': {'self': id},
      },
    }),
  ),
);

Uint8List _zip(Map<String, Uint8List> entries) {
  final archive = Archive();
  entries.forEach((name, bytes) => archive.addFile(ArchiveFile(name, bytes.length, bytes)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
