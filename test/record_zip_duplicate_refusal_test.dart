// A zip must not add a record the store already holds under a different id.
//
// The importer addressed records by id alone. An id collision is an overwrite, which is the
// interchange format's own rule -- but nothing asked whether the *contents* were already in the
// table. So a record exported, captured again on another machine, and imported back arrived as a
// second row of the same trainee, which the capture path would have refused outright.
//
// The question is answered with the store's own duplicate rule (`duplicateCharaIdIn`, over
// `isSameChara`), not with a second idea of sameness invented here.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_zip_duplicate_refusal_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/record_zip.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/records.dart';
import 'support/web_like_fs_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeMappers);

  late Directory tempRoot;
  late DirectoryPath storageDir;
  late FsBackend originalBackend;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_zip_duplicate');
    storageDir = DirectoryPath(tempRoot.path) / 'storage';
    originalBackend = fsBackend;
    fsBackend = WebLikeFsBackend(originalBackend);
  });
  tearDown(() {
    fsBackend = originalBackend;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  // The record already in the store, and a zip copy of it under a fresh id -- the shape an export,
  // a re-capture elsewhere and an import back produces.
  final owned = makeRecord(id: 'owned', card: 100, self: const [Factor(5, 3)]);
  final sameCharaNewId = makeRecord(id: 'arrived', card: 100, self: const [Factor(5, 3)]);
  final otherChara = makeRecord(id: 'other', card: 200, self: const [Factor(7, 1)]);

  /// The store's duplicate rule, asked of what the store holds and of what this import has
  /// already admitted. The same call the import control makes, so this test cannot pass on a
  /// predicate that only exists here.
  bool isDuplicate(CharaDetailRecord record, Iterable<CharaDetailRecord> admitted) =>
      duplicateCharaIdIn([owned], record) != null || duplicateCharaIdIn(admitted, record) != null;

  DirectoryPath active() => storageDir / 'chara_detail' / 'active';

  test('refuses a record whose contents the store already holds under another id', () async {
    final result = await RecordZipService.import(
      _zip({
        'chara_detail/active/arrived/record.json': _json(sameCharaNewId),
        'chara_detail/active/arrived/trainee.jpg': Uint8List.fromList([1, 2, 3]),
        'chara_detail/active/other/record.json': _json(otherChara),
      }),
      storageDir,
      isDuplicate: isDuplicate,
    );

    expect(result.recordIds, {'other'});
    expect(result.refusals['arrived'], RecordImportRefusal.duplicateOfExisting);
    // Withheld whole, not just its record.json: no half a record is left on disk.
    expect(await (active() / 'arrived').exists(), isFalse);
    expect(await (active() / 'other').filePath('record.json').exists(), isTrue);
  });

  // Negative control: a record the store does not hold is imported exactly as before.
  test('still imports a record that duplicates nothing', () async {
    final result = await RecordZipService.import(
      _zip({'chara_detail/active/other/record.json': _json(otherChara)}),
      storageDir,
      isDuplicate: isDuplicate,
    );

    expect(result.recordIds, {'other'});
    expect(result.refusals, isEmpty);
  });

  // Negative control: an id already in the store is an overwrite, not a duplicate. Re-importing the
  // very record the store holds must keep working.
  test('still imports a record that collides by id with the one it duplicates', () async {
    final result = await RecordZipService.import(
      _zip({'chara_detail/active/owned/record.json': _json(owned)}),
      storageDir,
      isDuplicate: isDuplicate,
    );

    expect(result.recordIds, {'owned'});
    expect(result.refusals, isEmpty);
  });

  // Negative control: with no duplicate rule supplied the importer behaves as it always did, so
  // every caller that does not pass one is untouched by this check.
  test('imports everything when no duplicate rule is given', () async {
    final result = await RecordZipService.import(
      _zip({
        'chara_detail/active/arrived/record.json': _json(sameCharaNewId),
        'chara_detail/active/other/record.json': _json(otherChara),
      }),
      storageDir,
    );

    expect(result.recordIds, {'arrived', 'other'});
    expect(result.refusals, isEmpty);
  });

  test('refuses the second copy of a chara one zip carries twice', () async {
    final twin = makeRecord(id: 'twin', card: 200, self: const [Factor(7, 1)]);
    expect(twin.isSameChara(otherChara), isTrue, reason: 'precondition: the zip carries one chara twice');

    final result = await RecordZipService.import(
      _zip({
        'chara_detail/active/other/record.json': _json(otherChara),
        'chara_detail/active/twin/record.json': _json(twin),
      }),
      storageDir,
      isDuplicate: isDuplicate,
    );

    // The store holds neither of them, so only the zip's own contents can refuse one.
    expect(result.recordIds, {'other'});
    expect(result.refusals['twin'], RecordImportRefusal.duplicateOfExisting);
    expect(await (active() / 'twin').exists(), isFalse);
  });

  // Negative control for the check above: two records that are *not* the same chara both arrive,
  // so the in-zip comparison refuses on sameness and not merely on being second.
  test('still imports two different charas carried by one zip', () async {
    final result = await RecordZipService.import(
      _zip({
        'chara_detail/active/other/record.json': _json(otherChara),
        'chara_detail/active/third/record.json': _json(makeRecord(id: 'third', card: 300, self: const [Factor(8, 2)])),
      }),
      storageDir,
      isDuplicate: isDuplicate,
    );

    expect(result.recordIds, {'other', 'third'});
    expect(result.refusals, isEmpty);
  });

  test('reports the records it committed so the next zip of a selection can be weighed against them', () async {
    final result = await RecordZipService.import(
      _zip({'chara_detail/active/other/record.json': _json(otherChara)}),
      storageDir,
      isDuplicate: isDuplicate,
    );

    expect(result.acceptedRecords.map((e) => e.id), ['other']);
    // What the import control then does with them: a second zip carrying the same chara under a
    // fresh id is refused by the records the first one left behind.
    final twin = makeRecord(id: 'twin', card: 200, self: const [Factor(7, 1)]);
    expect(duplicateCharaIdIn(result.acceptedRecords, twin), 'other');
  });

  // Negative control: a body the duplicate rule cannot be asked about is left to the store, which
  // refuses it on its own terms rather than as a duplicate.
  test('leaves a record whose record.json does not decode to the store', () async {
    // The store's own rejection of an undecodable body, reaching the caller unchanged: the
    // duplicate rule was never asked, so it neither refused this record nor hid the real reason.
    await expectLater(
      RecordZipService.import(
        _zip({'chara_detail/active/arrived/record.json': Uint8List.fromList(utf8.encode('not json'))}),
        storageDir,
        isDuplicate: isDuplicate,
      ),
      throwsFormatException,
    );
  });

  // The zip is validated whole before any of it is written, so the record ahead of an unreadable
  // one is not left on disk with nothing naming it. On disk and absent from the result is the worst
  // of both: the table never shows it, the count never mentions it, and the next zip of the same
  // selection weighs its own records against a store that does not show it -- so the chara it
  // carries arrives a second time.
  //
  // The unreadable id sorts after the good one as well as arriving after it, so this is failed by a
  // validation that runs per record in *either* order -- the zip's, or the sorted one the record
  // locks are taken in.
  test('writes no record at all when a later one in the zip carries an unreadable record.json', () async {
    await expectLater(
      RecordZipService.import(
        _zip({
          'chara_detail/active/other/record.json': _json(otherChara),
          'chara_detail/active/unreadable/record.json': Uint8List.fromList(utf8.encode('not json')),
        }),
        storageDir,
        isDuplicate: isDuplicate,
      ),
      throwsFormatException,
    );

    expect(await (active() / 'other').exists(), isFalse);
    expect(await (active() / 'unreadable').exists(), isFalse);
  });

  // A record only this run admitted is not yet in any store, so it cannot be the reason a later
  // copy is turned away: the store may still refuse it. The pair below is exactly that -- the
  // enhanced copy of a chara whose pre-enhancement version sits in `archive/`, and a second
  // enhanced copy under its own id. The first is refused by the archive's hold on its id; the
  // second is the only importable copy there is, and has to arrive.
  test('imports the second copy of a chara whose first copy the store refuses', () async {
    final enhancedA = makeRecord(id: 'enhanced-a', card: 400, self: const [Factor(9, 3)]);
    final enhancedB = makeRecord(id: 'enhanced-b', card: 400, self: const [Factor(9, 3)]);
    expect(enhancedA.isSameChara(enhancedB), isTrue, reason: 'precondition: the zip carries one chara twice');
    // The pre-enhancement copy, under the same id the zip's first record carries, in the other store.
    final archived = makeRecord(id: 'enhanced-a', card: 400, self: const [Factor(9, 1)]);
    final archivedDir = Directory((storageDir / 'chara_detail' / 'archive' / 'enhanced-a').path)
      ..createSync(recursive: true);
    File('${archivedDir.path}/record.json').writeAsBytesSync(_json(archived));

    final result = await RecordZipService.import(
      _zip({
        'chara_detail/active/enhanced-a/record.json': _json(enhancedA),
        'chara_detail/active/enhanced-b/record.json': _json(enhancedB),
      }),
      storageDir,
      isDuplicate: isDuplicate,
    );

    expect(result.refusals['enhanced-a'], RecordImportRefusal.alreadyArchived);
    expect(result.recordIds, {'enhanced-b'});
    expect(result.refusals.containsKey('enhanced-b'), isFalse);
    expect(await (active() / 'enhanced-b').filePath('record.json').exists(), isTrue);
    // The refused copy left nothing behind, and the archived one is untouched.
    expect(await (active() / 'enhanced-a').exists(), isFalse);
    expect(File('${archivedDir.path}/record.json').readAsBytesSync(), _json(archived));
  });

  // Negative control for the test above: with nothing in `archive/` the first copy commits, and it
  // is then the one that refuses the second. The duplicate rule is still asked, and still refuses.
  test('still refuses the second copy when the first one commits', () async {
    final enhancedA = makeRecord(id: 'enhanced-a', card: 400, self: const [Factor(9, 3)]);
    final enhancedB = makeRecord(id: 'enhanced-b', card: 400, self: const [Factor(9, 3)]);

    final result = await RecordZipService.import(
      _zip({
        'chara_detail/active/enhanced-a/record.json': _json(enhancedA),
        'chara_detail/active/enhanced-b/record.json': _json(enhancedB),
      }),
      storageDir,
      isDuplicate: isDuplicate,
    );

    expect(result.recordIds, {'enhanced-a'});
    expect(result.refusals['enhanced-b'], RecordImportRefusal.duplicateOfExisting);
  });

  // An id collision is an overwrite, but the overwrite's new contents are still weighed against
  // every *other* record the store holds, so a zip cannot turn a stored record into a copy of
  // another one -- the pair the add-time check keeps out.
  group('overwriting a stored id', () {
    final stored = [owned, otherChara];
    bool isDuplicateOfStored(CharaDetailRecord record, Iterable<CharaDetailRecord> admitted) =>
        duplicateCharaIdIn(stored, record) != null || duplicateCharaIdIn(admitted, record) != null;

    late Map<String, List<int>> before;
    setUp(() async {
      for (final record in stored) {
        final dir = Directory((active() / record.id).path)..createSync(recursive: true);
        File('${dir.path}/record.json').writeAsBytesSync(_json(record));
      }
      before = {for (final r in stored) r.id: File('${(active() / r.id).path}/record.json').readAsBytesSync()};
    });

    Future<RecordImportResult> importOver(String id, CharaDetailRecord content) => RecordZipService.import(
      _zip({'chara_detail/active/$id/record.json': _json(content)}),
      storageDir,
      isDuplicate: isDuplicateOfStored,
    );

    List<int> onDisk(String id) => File('${(active() / id).path}/record.json').readAsBytesSync();

    test('refuses an overwrite whose contents are another stored record', () async {
      final ownedAsOther = makeRecord(id: 'other', card: 100, self: const [Factor(5, 3)]);
      expect(ownedAsOther.isSameChara(owned), isTrue, reason: 'precondition: the overwrite copies owned');

      final result = await importOver('other', ownedAsOther);

      expect(result.recordIds, isEmpty);
      expect(result.refusals['other'], RecordImportRefusal.duplicateOfExisting);
      // The store is untouched on disk: both records keep the bytes they had.
      expect(onDisk('other'), before['other']);
      expect(onDisk('owned'), before['owned']);
    });

    // Negative control: an overwrite with contents no other record holds lands.
    test('still overwrites a stored id with contents that duplicate nothing', () async {
      final fresh = makeRecord(id: 'other', card: 300, self: const [Factor(8, 2)]);

      final result = await importOver('other', fresh);

      expect(result.recordIds, {'other'});
      expect(result.refusals, isEmpty);
      expect(onDisk('other'), _json(fresh));
      expect(onDisk('owned'), before['owned']);
    });

    // Negative control: re-importing a stored record's own contents under its own id is the
    // overwrite the format promises, and the record it replaces is not a duplicate of itself.
    test('still overwrites a stored id with its own contents', () async {
      final result = await importOver('owned', owned);

      expect(result.recordIds, {'owned'});
      expect(result.refusals, isEmpty);
      expect(onDisk('owned'), before['owned']);
      expect(onDisk('other'), before['other']);
    });
  });
}

Uint8List _json(CharaDetailRecord record) => Uint8List.fromList(utf8.encode(jsonEncode(record.toMap())));

Uint8List _zip(Map<String, Uint8List> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
