import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/record_archive_state.dart';
import 'package:umacapture/src/chara_detail/record_body.dart';
import 'package:umacapture/src/chara_detail/record_zip.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/value_write_time.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/long_read_declarations.dart';
import 'support/record_binding_seed.dart';
import 'support/records.dart';
import 'support/web_like_fs_backend.dart';

/// A ref over a container whose record stores are never built, for an export that has no stores to update.
RefBase _refWithoutStores() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container.read(containerRefProvider);
}

void main() {
  late Directory tempRoot;
  late DirectoryPath storageDir;
  late FsBackend originalBackend;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_record_zip_test');
    storageDir = DirectoryPath(tempRoot.path) / 'storage';
    originalBackend = fsBackend;
    // Import/export is shared, but the OPFS write is the risky half, so it runs
    // against `WebLikeFsBackend`: a sync FS call added here fails on the VM
    // instead of passing CI and breaking only on web. That pins OPFS's
    // *synchronous* prohibition and nothing else -- see
    // `support/web_like_fs_backend.dart` for what this backend does not model.
    fsBackend = WebLikeFsBackend(originalBackend);
  });
  tearDown(() {
    fsBackend = originalBackend;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  test('imports valid active records transactionally', () async {
    final result = await RecordZipService.import(
      _zip({
        'chara_detail/active/uuid-1/record.json': _recordJson('uuid-1'),
        'chara_detail/active/uuid-1/trainee.jpg': Uint8List.fromList([1, 2, 3]),
        'chara_detail/active/uuid-2/record.json': _recordJson('uuid-2'),
      }),
      storageDir,
    );
    final active = _active(storageDir);
    expect(result.recordIds, {'uuid-1', 'uuid-2'});
    expect(result.skippedEntries, 0);
    expect(await (active / 'uuid-1').filePath('record.json').readAsBytes(), _recordJson('uuid-1'));
    expect(await (active / 'uuid-1').filePath('trainee.jpg').readAsBytes(), [1, 2, 3]);
  });

  test('upgrades a record an older build exported as it imports it', () async {
    // The same capture as a major-1 recognizer wrote it, and in the current format.
    initializeMappers();
    const id = '9a1e0d66-0654-4416-aa11-5613e7a9f05e';
    final v1 = File('test/fixtures/chara_detail_record_v1.json').readAsBytesSync();
    final current = File('test/fixtures/chara_detail_record.json').readAsStringSync();

    valueWriteClock = () => 1700000000000;
    addTearDown(() => valueWriteClock = () => DateTime.now().millisecondsSinceEpoch);

    final result = await RecordZipService.import(_zip({'chara_detail/active/$id/record.json': v1}), storageDir);

    expect(result.recordIds, {id});
    final stored = await (_active(storageDir) / id).filePath('record.json').readAsString();
    // A record no store held is written at the time of the import, as a capture is.
    expect(CharaDetailRecordMapper.fromJson(stored), composeBodyWrite(null, CharaDetailRecordMapper.fromJson(current)));
  });

  test('counts skipped directory entries', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.directory('chara_detail/active/uuid-1/'))
      ..addFile(
        ArchiveFile('chara_detail/active/uuid-1/record.json', _recordJson('uuid-1').length, _recordJson('uuid-1')),
      );

    final result = await RecordZipService.import(Uint8List.fromList(ZipEncoder().encode(archive)), storageDir);

    expect(result.recordIds, {'uuid-1'});
    expect(result.skippedEntries, 1);
  });

  test('rejects zip-slip before writing any accepted entry', () async {
    final zip = _zip({
      'chara_detail/active/good/record.json': _recordJson('good'),
      'chara_detail/active/../../evil.txt': Uint8List.fromList([1]),
    });
    await expectLater(RecordZipService.import(zip, storageDir), throwsFormatException);
    expect(await (_active(storageDir) / 'good').exists(), isFalse);
    expect(await File('${tempRoot.path}/evil.txt').exists(), isFalse);
  });

  test('replaces only supplied files for a colliding record id', () async {
    await RecordZipService.import(
      _zip({
        'chara_detail/active/dup/record.json': _recordJson('dup'),
        'chara_detail/active/dup/value.bin': Uint8List.fromList([1]),
        'chara_detail/active/dup/keep.bin': Uint8List.fromList([7]),
      }),
      storageDir,
    );
    await RecordZipService.import(
      _zip({
        'chara_detail/active/dup/record.json': _recordJson('dup'),
        'chara_detail/active/dup/value.bin': Uint8List.fromList([2]),
      }),
      storageDir,
    );
    final record = _active(storageDir) / 'dup';
    expect(await record.filePath('value.bin').readAsBytes(), [2]);
    expect(await record.filePath('keep.bin').readAsBytes(), [7]);
  });

  test('rejects total size over the injected limit, writing nothing', () async {
    final zip = _zip({
      'chara_detail/active/uuid-1/record.json': _recordJson('uuid-1'),
      'chara_detail/active/uuid-1/trainee.jpg': Uint8List.fromList(List.filled(50, 1)),
      'chara_detail/active/uuid-2/record.json': _recordJson('uuid-2'),
      'chara_detail/active/uuid-2/trainee.jpg': Uint8List.fromList(List.filled(50, 1)),
    });
    await expectLater(
      RecordZipService.import(zip, storageDir, maxTotalUncompressedBytes: 100),
      throwsA(isA<RecordZipTooLargeException>()),
    );
    expect(await (_active(storageDir) / 'uuid-1').exists(), isFalse);
    expect(await (_active(storageDir) / 'uuid-2').exists(), isFalse);
  });

  test('rejects entry count over the injected limit, writing nothing', () async {
    final zip = _zip({
      'chara_detail/active/uuid-1/record.json': _recordJson('uuid-1'),
      'chara_detail/active/uuid-2/record.json': _recordJson('uuid-2'),
    });
    await expectLater(
      RecordZipService.import(zip, storageDir, maxEntryCount: 1),
      throwsA(isA<RecordZipTooLargeException>()),
    );
    expect(await (_active(storageDir) / 'uuid-1').exists(), isFalse);
    expect(await (_active(storageDir) / 'uuid-2').exists(), isFalse);
  });

  test('rejects a single entry over the injected limit, writing nothing', () async {
    final zip = _zip({
      'chara_detail/active/uuid-1/record.json': _recordJson('uuid-1'),
      'chara_detail/active/uuid-1/trainee.jpg': Uint8List.fromList(List.filled(50, 1)),
    });
    await expectLater(
      RecordZipService.import(zip, storageDir, maxEntryUncompressedBytes: 10),
      throwsA(isA<RecordZipTooLargeException>()),
    );
    expect(await (_active(storageDir) / 'uuid-1').exists(), isFalse);
  });

  test('imports normally when within the injected limits', () async {
    final zip = _zip({
      'chara_detail/active/uuid-1/record.json': _recordJson('uuid-1'),
      'chara_detail/active/uuid-1/trainee.jpg': Uint8List.fromList(List.filled(50, 1)),
    });
    final result = await RecordZipService.import(
      zip,
      storageDir,
      maxTotalUncompressedBytes: 1000,
      maxEntryCount: 10,
      maxEntryUncompressedBytes: 100,
    );
    expect(result.recordIds, {'uuid-1'});
    expect(await (_active(storageDir) / 'uuid-1').filePath('trainee.jpg').readAsBytes(), List.filled(50, 1));
  });

  test('rejects a lying per-entry declared size once the real bytes exceed the limit', () async {
    // The header declares 50 bytes (well within any of the limits below), but
    // the entry actually deflates 2,000,000 zero bytes -- reproducing the
    // "declared size understates reality" attack that a header-only guard
    // would miss (see _BoundedOutputStream's doc in record_zip.dart).
    final zip = _zipWithLyingSizes([
      (name: 'chara_detail/active/uuid-1/big.bin', declaredUncompressedSize: 50, realUncompressedLength: 2000000),
    ]);
    await expectLater(
      RecordZipService.import(zip, storageDir, maxEntryUncompressedBytes: 1000),
      throwsA(isA<RecordZipTooLargeException>()),
    );
    expect(await (_active(storageDir) / 'uuid-1').exists(), isFalse);
  });

  test('rejects a lying declared size once the real cumulative bytes exceed the total limit', () async {
    // Both entries declare 50 bytes and individually stay under the
    // (generous) per-entry limit once inflated, but their combined real size
    // exceeds the small total limit injected here.
    final zip = _zipWithLyingSizes([
      (name: 'chara_detail/active/uuid-1/big1.bin', declaredUncompressedSize: 50, realUncompressedLength: 700),
      (name: 'chara_detail/active/uuid-2/big2.bin', declaredUncompressedSize: 50, realUncompressedLength: 700),
    ]);
    await expectLater(
      RecordZipService.import(zip, storageDir, maxEntryUncompressedBytes: 1000, maxTotalUncompressedBytes: 1000),
      throwsA(isA<RecordZipTooLargeException>()),
    );
    expect(await (_active(storageDir) / 'uuid-1').exists(), isFalse);
    expect(await (_active(storageDir) / 'uuid-2').exists(), isFalse);
  });

  test('exports STORED entries that round-trip through transactional import', () async {
    final active = _active(storageDir);
    await (active / 'uuid-a').create(recursive: true);
    await (active / 'uuid-b').create(recursive: true);
    await (active / 'uuid-a').filePath('record.json').writeAsBytes(_recordJson('uuid-a'));
    await (active / 'uuid-a').filePath('trainee.jpg').writeAsBytes([9, 8, 7]);
    await (active / 'uuid-b').filePath('record.json').writeAsBytes(_recordJson('uuid-b'));
    final bytes = await RecordZipService.export(
      [active / 'uuid-a', active / 'uuid-b'],
      ref: _refWithoutStores(),
      declaration: undeclaredInTest,
    );
    final archive = ZipDecoder().decodeBytes(bytes);
    expect(archive.files.map((entry) => entry.name).toSet(), {
      'chara_detail/active/uuid-a/record.json',
      'chara_detail/active/uuid-a/trainee.jpg',
      'chara_detail/active/uuid-b/record.json',
    });
    expect(archive.files.map((entry) => entry.compression), everyElement(CompressionType.none));

    final fresh = Directory.systemTemp.createTempSync('umacapture_record_zip_roundtrip');
    addTearDown(() => fresh.deleteSync(recursive: true));
    final freshStorage = DirectoryPath(fresh.path) / 'storage';
    expect((await RecordZipService.import(bytes, freshStorage)).recordIds, {'uuid-a', 'uuid-b'});
    expect(await (_active(freshStorage) / 'uuid-a').filePath('record.json').readAsBytes(), _recordJson('uuid-a'));
    expect(await (_active(freshStorage) / 'uuid-a').filePath('trainee.jpg').readAsBytes(), [9, 8, 7]);
  });

  group("an import makes the record the zip's", () {
    const id = 'record-1';
    const importedAt = 1800000000000;
    const localBodyAt = 1700000000000;
    late DirectoryPath chara;

    setUp(() {
      initializeMappers();
      chara = storageDir / 'chara_detail';
      valueWriteClock = () => importedAt;
    });
    tearDown(() => valueWriteClock = () => DateTime.now().millisecondsSinceEpoch);

    // The device's record: [card] tells one capture's reading from another's.
    Future<DirectoryPath> seedLocal({
      String store = 'active',
      int card = 1,
      RecordBinding? binding,
      ({String? parent1, String? parent2}) parents = (parent1: null, parent2: null),
      int? relationBonus,
      Map<String, Uint8List> pngs = const {},
      bool trainee = true,
      Map<String, Object?>? note,
    }) async {
      final dir = chara / store / id;
      await dir.create(recursive: true);
      await dir
          .filePath('record.json')
          .writeAsBytes(
            _body(
              _record(card, parents: parents, binding: binding, relationBonus: relationBonus),
              writtenAt: localBodyAt,
            ),
          );
      for (final MapEntry(:key, :value) in pngs.entries) {
        await dir.filePath('$key.png').writeAsBytes(value);
      }
      if (trainee) await dir.filePath('trainee.jpg').writeAsBytes([7, 7, 7]);
      await dir.filePath('merged_ids.json').writeAsBytes(utf8.encode(jsonEncode(['absorbed-local'])));
      if (note != null) await dir.filePath('archive.json').writeAsBytes(utf8.encode(jsonEncode(note)));
      return dir;
    }

    Future<RecordImportResult> importZip(Map<String, List<int>> files) => RecordZipService.import(
      _zip({for (final e in files.entries) 'chara_detail/active/$id/${e.key}': Uint8List.fromList(e.value)}),
      storageDir,
    );

    Future<CharaDetailRecord> stored(String store) async =>
        CharaDetailRecord.fromRecordJson(await (chara / store / id).filePath('record.json').readAsString());

    List<String> namesIn(String store) =>
        (Directory((chara / store / id).path).listSync().map((e) => e.uri.pathSegments.last).toList()..sort());

    group('C1', () {
      test("a zip of another capture without images takes the device's images and trainee.jpg off", () async {
        final pngs = bindingImagePngs();
        await seedLocal(binding: expectedBinding(pngs), pngs: pngs);

        final result = await importZip({'record.json': _body(_record(2, binding: expectedBinding(_otherPngs())))});

        expect(result.recordIds, {id});
        expect(namesIn('active'), ['record.json']);
        final record = await stored('active');
        expect(record.trainee.card, 2);
        expect(record.metadata.bodyWrittenAt, importedAt);
      });

      test('the ratings, memos and dismissed pairs of the id stay as they were', () async {
        await seedLocal(pngs: bindingImagePngs());
        final metadata = chara / 'metadata';
        final rating = metadata / 'rating';
        final memo = metadata / 'memo';
        await rating.create(recursive: true);
        await memo.create(recursive: true);
        final ratingBytes = utf8.encode(
          jsonEncode({
            'title': 'r',
            'data': {id: 3.0},
            'writtenAt': {id: 5},
          }),
        );
        final memoBytes = utf8.encode(
          jsonEncode({
            'title': 'm',
            'data': {id: 'note'},
            'writtenAt': {id: 6},
          }),
        );
        final dismissedBytes = utf8.encode(jsonEncode(['$id+other']));
        await rating.filePath('r.json').writeAsBytes(ratingBytes);
        await memo.filePath('m.json').writeAsBytes(memoBytes);
        await metadata.filePath('enhancement_dismissed.json').writeAsBytes(dismissedBytes);

        await importZip({'record.json': _body(_record(2))});

        expect(await rating.filePath('r.json').readAsBytes(), ratingBytes);
        expect(await memo.filePath('m.json').readAsBytes(), memoBytes);
        expect(await metadata.filePath('enhancement_dismissed.json').readAsBytes(), dismissedBytes);
      });

      test("merged_ids.json is the zip's, and is gone where the zip carries none", () async {
        await seedLocal();
        final zipped = utf8.encode(jsonEncode(['absorbed-zip']));

        await importZip({'record.json': _body(_record(1)), 'merged_ids.json': zipped});
        expect(await (chara / 'active' / id).filePath('merged_ids.json').readAsBytes(), zipped);

        await importZip({'record.json': _body(_record(1))});
        expect(await (chara / 'active' / id).filePath('merged_ids.json').exists(), isFalse);
      });

      group('the binding written', () {
        test("is the zip's binding", () async {
          await seedLocal(binding: expectedBinding(bindingImagePngs()), pngs: bindingImagePngs());
          final carried = expectedBinding(_otherPngs());

          await importZip({'record.json': _body(_record(2, binding: carried))});

          expect((await stored('active')).metadata.binding, carried);
        });

        test('is worked out from the images of a zip of an older build', () async {
          await seedLocal(pngs: bindingImagePngs());
          final other = _otherPngs();

          await importZip({
            'record.json': _body(_record(2)),
            for (final MapEntry(:key, :value) in other.entries) '$key.png': value,
          });

          expect((await stored('active')).metadata.binding, expectedBinding(other));
          for (final MapEntry(:key, :value) in other.entries) {
            expect(await (chara / 'active' / id).filePath('$key.png').readAsBytes(), value);
          }
        });

        test('is none for a zip of an older build that carries no image', () async {
          await seedLocal(pngs: bindingImagePngs());

          await importZip({'record.json': _body(_record(2))});

          expect((await stored('active')).metadata.binding, isNull);
          expect(namesIn('active'), ['record.json']);
        });
      });

      test(
        "a zip of another capture that carries images takes the device's other images and trainee.jpg off",
        () async {
          final pngs = bindingImagePngs();
          await seedLocal(binding: expectedBinding(pngs), pngs: pngs);
          final other = _otherPngs();

          await importZip({
            'record.json': _body(_record(2, binding: expectedBinding(other))),
            'skill.png': other['skill']!,
          });

          expect(namesIn('active'), ['record.json', 'skill.png']);
          expect(await (chara / 'active' / id).filePath('skill.png').readAsBytes(), other['skill']);
        },
      );

      test('a zip of the same capture keeps the images', () async {
        final pngs = bindingImagePngs();
        await seedLocal(binding: expectedBinding(pngs), pngs: pngs);

        await importZip({'record.json': _body(_record(1, binding: expectedBinding(pngs)))});

        expect(namesIn('active'), ['campaign.png', 'factor.png', 'record.json', 'skill.png', 'trainee.jpg']);
        expect((await stored('active')).metadata.bodyWrittenAt, localBodyAt);
      });

      test('a zip of another reading whose binding names the images keeps them', () async {
        final pngs = bindingImagePngs();
        await seedLocal(pngs: pngs);

        await importZip({'record.json': _body(_record(2, binding: expectedBinding(pngs)))});

        expect(namesIn('active'), ['campaign.png', 'factor.png', 'record.json', 'skill.png', 'trainee.jpg']);
        expect((await stored('active')).metadata.bodyWrittenAt, importedAt);
      });

      test('a zip without images takes the images its binding names from another record of the device', () async {
        // The device's other record holds the images the zip's body was read from, under another body: a merge left
        // them there, and a re-recognition by a newer module read them as something else since.
        final pngs = bindingImagePngs();
        final donor = chara / 'active' / 'record-0';
        await donor.create(recursive: true);
        final donorRecord = placeOnRecord(makeRecord(id: 'record-0', card: 3), binding: expectedBinding(pngs));
        await donor.filePath('record.json').writeAsBytes(_body(donorRecord));
        for (final MapEntry(:key, :value) in pngs.entries) {
          await donor.filePath('$key.png').writeAsBytes(value);
        }
        await donor.filePath('trainee.jpg').writeAsBytes([7, 7, 7]);
        List<String> donorNames() =>
            Directory(donor.path).listSync().map((e) => e.uri.pathSegments.last).toList()..sort();
        final donorBefore = donorNames();

        await importZip({'record.json': _body(_record(2, binding: expectedBinding(pngs)))});

        expect(namesIn('active'), [
          'archive.json',
          'campaign.png',
          'factor.png',
          'record.json',
          'skill.png',
          'trainee.jpg',
        ]);
        for (final MapEntry(:key, :value) in pngs.entries) {
          expect(await (chara / 'active' / id).filePath('$key.png').readAsBytes(), value);
        }
        expect(await (chara / 'active' / id).filePath('trainee.jpg').readAsBytes(), [7, 7, 7]);
        expect(donorNames(), donorBefore);
      });
    });

    group('C2', () {
      test('an archived zip is not refused, and lands in the archive store', () async {
        await seedLocal(pngs: bindingImagePngs());

        final result = await importZip({
          'record.json': _body(_record(1)),
          'archive.json': utf8.encode(
            jsonEncode({
              'archived': {'state': 'none'},
            }),
          ),
        });

        expect(result.recordIds, {id});
        expect(result.refusals, isEmpty);
        expect(await (chara / 'active' / id).exists(), isFalse);
        expect(await readRecordArchiveState(chara / 'archive' / id, archiveStore: true), (
          state: RecordArchiveState.none,
          writtenAt: importedAt,
        ));
        expect(namesIn('archive').where((name) => name.endsWith('.png')), isEmpty);
      });

      test("a zip archived with no images takes a reduced-JPEG record's JPEGs and trainee.jpg off", () async {
        final dir = await seedLocal(
          store: 'archive',
          note: {
            'archived': {'state': 'jpeg', 'written_at': localBodyAt},
          },
        );
        for (final image in ['skill', 'factor', 'campaign']) {
          await dir.filePath('$image.jpg').writeAsBytes([1, 2, 3]);
        }

        await importZip({
          'record.json': _body(_record(1)),
          'archive.json': utf8.encode(
            jsonEncode({
              'archived': {'state': 'none'},
            }),
          ),
        });

        expect(namesIn('archive'), ['archive.json', 'record.json']);
      });

      test(
        'a record archived before notes were kept goes out archived, and comes back into the archive store',
        () async {
          final dir = await seedLocal(store: 'archive');
          expect(await dir.filePath('archive.json').exists(), isFalse);

          final zip = await RecordZipService.export([dir], ref: _refWithoutStores(), declaration: undeclaredInTest);
          await dir.delete(recursive: true);
          await RecordZipService.import(zip, storageDir);

          expect(await (chara / 'active' / id).exists(), isFalse);
          expect(
            (await readRecordArchiveState(chara / 'archive' / id, archiveStore: true)).state,
            RecordArchiveState.jpeg,
          );
        },
      );

      test("a zip of a directory on the quarantine shelf leaves the shelf's note of it behind", () async {
        await importZip({'record.json': _body(_record(1)), 'quarantine_origin.json': utf8.encode('{"id":"$id"}')});

        expect(namesIn('active'), isNot(contains('quarantine_origin.json')));
      });

      test('a normal zip makes an archived record normal, at the time of the import', () async {
        await seedLocal(
          store: 'archive',
          note: {
            'normal_written_at': 10,
            'archived': {'state': 'jpeg', 'written_at': localBodyAt},
          },
        );

        await importZip({'record.json': _body(_record(1))});

        expect(await (chara / 'archive' / id).exists(), isFalse);
        expect(await readRecordArchiveState(chara / 'active' / id, archiveStore: false), (
          state: RecordArchiveState.normal,
          writtenAt: importedAt,
        ));
      });

      test('a zip of the body and state the device holds moves no time', () async {
        await seedLocal(note: {'normal_written_at': 10});
        final noteBefore = await (chara / 'active' / id).filePath('archive.json').readAsBytes();

        await importZip({'record.json': _body(_record(1))});

        expect((await stored('active')).metadata.bodyWrittenAt, localBodyAt);
        expect(await (chara / 'active' / id).filePath('archive.json').readAsBytes(), noteBefore);
      });

      test("a zip of the device's body with other parents places them, moving no time", () async {
        await seedLocal(parents: (parent1: 'p-local', parent2: null));

        await importZip({'record.json': _body(_record(1, parents: (parent1: 'p-zip', parent2: 'q-zip')))});

        final metadata = (await stored('active')).metadata;
        expect((metadata.recordId.parent1, metadata.recordId.parent2), ('p-zip', 'q-zip'));
        expect(metadata.bodyWrittenAt, localBodyAt);
      });
    });

    group('C3', () {
      test('a zip v0.3.0 exported reads as an older record', () async {
        final legacy = File(UnboundRecord.legacy.fixture).readAsBytesSync();
        final legacyId = UnboundRecord.legacy.id;
        final pngs = bindingImagePngs();

        final result = await RecordZipService.import(
          _zip({
            '$legacyId/record.json': legacy,
            for (final MapEntry(:key, :value) in pngs.entries) '$legacyId/$key.png': value,
            'labels.json': Uint8List.fromList(utf8.encode('{}')),
          }),
          storageDir,
        );

        expect(result.recordIds, {legacyId});
        final record = CharaDetailRecord.fromRecordJson(
          await (chara / 'active' / legacyId).filePath('record.json').readAsString(),
        );
        expect(record.metadata.binding, expectedBinding(pngs));
        expect(await readRecordArchiveState(chara / 'active' / legacyId, archiveStore: false), (
          state: RecordArchiveState.normal,
          writtenAt: importedAt,
        ));
      });

      test('a value an older build left for an id it deleted shows, with no time, once the id is back', () async {
        final rating = chara / 'metadata' / 'rating';
        await rating.create(recursive: true);
        await rating
            .filePath('r.json')
            .writeAsBytes(
              utf8.encode(
                jsonEncode({
                  'title': 'r',
                  'data': {id: 3.0},
                }),
              ),
            );

        await importZip({'record.json': _body(_record(1))});

        final data = RatingDataMapper.fromJson(await rating.filePath('r.json').readAsString());
        expect(data.data[id], 3.0);
        expect(data.writtenAt.containsKey(id), isFalse);
      });
    });

    test("the device's relation bonus stays, and the zip's is not read", () async {
      await seedLocal(relationBonus: 5);

      await importZip({'record.json': _body(_record(2, relationBonus: 9))});
      expect((await stored('active')).metadata.relationBonus, 5);

      await (chara / 'active' / id).delete(recursive: true);
      await importZip({'record.json': _body(_record(2, relationBonus: 9))});
      expect((await stored('active')).metadata.relationBonus, isNull);
    });
  });
}

DirectoryPath _active(DirectoryPath storage) => storage / 'chara_detail' / 'active';

Uint8List _zip(Map<String, Uint8List> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
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

/// Builds a zip, by hand, whose local file headers *and* central directory
/// entries declare `declaredUncompressedSize` for each entry while the entry
/// actually deflates `realUncompressedLength` zero bytes.
///
/// `ArchiveFile.size`/`entry.size` reads straight from the central directory
/// header's declared uncompressed-size field with no cross-check against
/// what inflate actually produces, so a hand-built zip can lie about it. This
/// can't be produced through `package:archive`'s own `ZipEncoder` (which
/// always writes the true size), so the zip bytes are assembled directly per
/// the ZIP local/central-directory/EOCD layout, using `archive`'s public
/// `Deflate` class (raw deflate, no zlib wrapper) for the entry payloads.
Uint8List _zipWithLyingSizes(List<({String name, int declaredUncompressedSize, int realUncompressedLength})> entries) {
  final localSections = <Uint8List>[];
  final centralSections = <Uint8List>[];
  final localOffsets = <int>[];
  var offset = 0;

  for (final entry in entries) {
    final deflated = Deflate(Uint8List(entry.realUncompressedLength), level: DeflateLevel.bestCompression).getBytes();
    final nameBytes = utf8.encode(entry.name);

    final local = BytesBuilder();
    _writeU32(local, 0x04034b50); // local file header signature
    _writeU16(local, 20); // version needed to extract
    _writeU16(local, 0); // general purpose flag
    _writeU16(local, 8); // compression method = deflate
    _writeU16(local, 0); // last mod file time
    _writeU16(local, 0); // last mod file date
    _writeU32(local, 0); // crc-32 (unverified by RecordZipService.import)
    _writeU32(local, deflated.length); // compressed size (true)
    _writeU32(local, entry.declaredUncompressedSize); // uncompressed size (the lie)
    _writeU16(local, nameBytes.length);
    _writeU16(local, 0); // extra field length
    local.add(nameBytes);
    local.add(deflated);
    final localBytes = local.toBytes();

    localOffsets.add(offset);
    localSections.add(localBytes);
    offset += localBytes.length;

    final central = BytesBuilder();
    _writeU32(central, 0x02014b50); // central directory file header signature
    _writeU16(central, 20); // version made by
    _writeU16(central, 20); // version needed to extract
    _writeU16(central, 0); // general purpose flag
    _writeU16(central, 8); // compression method = deflate
    _writeU16(central, 0); // last mod file time
    _writeU16(central, 0); // last mod file date
    _writeU32(central, 0); // crc-32
    _writeU32(central, deflated.length); // compressed size (true)
    _writeU32(central, entry.declaredUncompressedSize); // uncompressed size (the lie)
    _writeU16(central, nameBytes.length);
    _writeU16(central, 0); // extra field length
    _writeU16(central, 0); // file comment length
    _writeU16(central, 0); // disk number start
    _writeU16(central, 0); // internal file attributes
    _writeU32(central, 0); // external file attributes
    _writeU32(central, localOffsets.last); // relative offset of local header
    central.add(nameBytes);
    centralSections.add(central.toBytes());
  }

  final centralDirectoryOffset = offset;
  final centralBytes = centralSections.fold(<int>[], (bytes, section) => bytes..addAll(section));

  final eocd = BytesBuilder();
  _writeU32(eocd, 0x06054b50); // end of central directory signature
  _writeU16(eocd, 0); // disk number
  _writeU16(eocd, 0); // disk with the start of the central directory
  _writeU16(eocd, entries.length); // entries on this disk
  _writeU16(eocd, entries.length); // total entries
  _writeU32(eocd, centralBytes.length); // size of the central directory
  _writeU32(eocd, centralDirectoryOffset); // offset of the central directory
  _writeU16(eocd, 0); // comment length

  return Uint8List.fromList([for (final section in localSections) ...section, ...centralBytes, ...eocd.toBytes()]);
}

void _writeU16(BytesBuilder builder, int value) {
  builder.addByte(value & 0xff);
  builder.addByte((value >> 8) & 0xff);
}

void _writeU32(BytesBuilder builder, int value) {
  builder.addByte(value & 0xff);
  builder.addByte((value >> 8) & 0xff);
  builder.addByte((value >> 16) & 0xff);
  builder.addByte((value >> 24) & 0xff);
}

/// [card] tells one capture's reading from another's.
CharaDetailRecord _record(
  int card, {
  ({String? parent1, String? parent2}) parents = (parent1: null, parent2: null),
  RecordBinding? binding,
  int? relationBonus,
}) => placeOnRecord(
  makeRecord(id: 'record-1', card: card, parent1Id: parents.parent1, parent2Id: parents.parent2),
  relationBonus: (value: relationBonus),
  binding: binding,
);

/// [record] as `record.json`, its body written at [writtenAt] where given.
Uint8List _body(CharaDetailRecord record, {int? writtenAt}) {
  final map = record.toMap();
  if (writtenAt != null) (map['metadata'] as Map<String, dynamic>)['body_written_at'] = writtenAt;
  return utf8.encode(const JsonEncoder.withIndent('    ').convert(map));
}

/// Images of another capture than [bindingImagePngs]'.
Map<String, Uint8List> _otherPngs() => {
  for (final (index, name) in ['skill', 'factor', 'campaign'].indexed)
    name: img.encodePng(img.Image(width: 64, height: 96)..clear(img.ColorRgb8(200, 10 + 30 * index, 60))),
};
