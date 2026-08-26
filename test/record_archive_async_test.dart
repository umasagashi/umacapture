// Verifies the async (web / OPFS) per-record archive path used on the main
// isolate: recognition PNGs are dropped or replaced with JPEGs, the record
// directory is moved from active/ to archive/, record.json / trainee.jpg survive,
// the large prediction.json is always dropped, and the geometry *.json is rescaled
// to the downscaled JPEG (kept) or dropped (imageless). Mirrors record_archive_test
// for the sync isolate path, exercising archiveRecordAsync / archiveRecordsAsync
// instead. The async FS surface runs on the VM's io backend here, so no web host
// is required.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_archive_async_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:umacapture/src/chara_detail/archive_executor_shared.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/record_directory_transaction.dart';
import 'package:umacapture/src/core/path_entity.dart';

void main() {
  late Directory tempRoot;
  late Directory activeDir;
  late Directory archiveDir;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_archive_async_test');
    activeDir = Directory('${tempRoot.path}/active')..createSync(recursive: true);
    archiveDir = Directory('${tempRoot.path}/archive')..createSync(recursive: true);
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  Uint8List pngBytes(int width, int height) => img.encodePng(img.Image(width: width, height: height));

  Uint8List jpgBytes(int width, int height) => img.encodeJpg(img.Image(width: width, height: height));

  // A geometry json with an intersection spanning (0,0)..(width,height).
  String intersectionJson(int width, int height) => jsonEncode({
    "intersection": {
      "top_left": {
        "x": 0,
        "y": 0,
        "anchor": {"h": "ScreenStart", "v": "ScreenStart"},
      },
      "bottom_right": {
        "x": width,
        "y": height,
        "anchor": {"h": "ScreenStart", "v": "ScreenStart"},
      },
    },
  });

  // The intersection's bottom-right corner (its pixel size, given a (0,0) origin).
  ({int width, int height}) intersectionSizeOf(String path) {
    final br = (jsonDecode(File(path).readAsStringSync())["intersection"]["bottom_right"]) as Map;
    return (width: br["x"] as int, height: br["y"] as int);
  }

  // Seeds active/<id>/ with the full set of files a captured record carries.
  String seedRecord(String id) {
    final dir = Directory('${activeDir.path}/$id')..createSync(recursive: true);
    File('${dir.path}/record.json').writeAsStringSync('{"id":"$id"}');
    File('${dir.path}/trainee.jpg').writeAsBytesSync(jpgBytes(60, 60));
    File('${dir.path}/prediction.json').writeAsStringSync('{"status_header":[]}');
    for (final name in ['skill', 'factor', 'campaign']) {
      File('${dir.path}/$name.png').writeAsBytesSync(pngBytes(1000, 1500));
      File('${dir.path}/$name.json').writeAsStringSync(intersectionJson(1000, 1500));
    }
    return dir.path;
  }

  ArchiveRecordArgs argsFor(String id, ArchiveImageOption option) {
    return ArchiveRecordArgs('${activeDir.path}/$id', '${archiveDir.path}/$id', option);
  }

  // Whether any transaction slot survived the archive. A slot is removed only
  // when its manifest reaches `completed`.
  bool transactionSlotsRemain() {
    final slotRoot = Directory('${tempRoot.path}/.umacapture-transactions/v1');
    return slotRoot.existsSync() && slotRoot.listSync().isNotEmpty;
  }

  // The recovery the web record-lock gate runs before every acquisition of a
  // record's lock (record_recovery_gate_web._ensureRecordReady), reduced to what
  // it could not finish.
  //
  // The gate no longer refuses a record for anything in this list -- an
  // unfinishable slot is quarantined where it is owned, not paid for with the
  // record. What the callers below assert is narrower and still worth having:
  // that a *failed archive of a record the app rejected* leaves no slot behind
  // at all, so nothing is re-attempted on every later acquisition.
  Future<List<RecordTransactionResult>> unfinishedSlotsFor(String id) async {
    final recoveries = await recoverRecordDirectoryTransactionsUnlocked(
      DirectoryPath(tempRoot.path),
      id,
      beforeCommittedCleanup: (spec) => cleanupCommittedArchiveTransactionUnlocked(spec, failOnError: true),
    );
    return recoveries
        .map((recovery) => recovery.result)
        .where((result) => result != RecordTransactionResult.completed)
        .toList();
  }

  test('resizedJpeg replaces PNGs with JPEGs and moves the record', () async {
    seedRecord('id-jpeg');

    final ok = await archiveRecordAsync(argsFor('id-jpeg', ArchiveImageOption.resizedJpeg));

    expect(ok, isTrue);
    // Source gone, destination present.
    expect(Directory('${activeDir.path}/id-jpeg').existsSync(), isFalse);
    final dst = DirectoryPath('${archiveDir.path}/id-jpeg');
    expect(dst.toDirectory().existsSync(), isTrue);
    // Retained files preserved.
    expect(File('${dst.path}/record.json').readAsStringSync(), '{"id":"id-jpeg"}');
    expect(File('${dst.path}/trainee.jpg').existsSync(), isTrue);
    // The large overlay data is always dropped.
    expect(File('${dst.path}/prediction.json').existsSync(), isFalse);
    // PNGs replaced with JPEGs; the geometry json is rescaled to the JPEG's size
    // (1000 wide clamped to 720; height 1500 * 720 / 1000 = 1080).
    for (final name in ['skill', 'factor', 'campaign']) {
      expect(File('${dst.path}/$name.png').existsSync(), isFalse);
      expect(File('${dst.path}/$name.jpg').existsSync(), isTrue);
      expect(File('${dst.path}/$name.json').existsSync(), isTrue);
      expect(intersectionSizeOf('${dst.path}/$name.json'), (width: 720, height: 1080));
    }
    // resolveImagePathSync prefers the archived JPEG.
    expect(resolveImagePathSync(dst, CharaDetailRecordImageMode.skillPlain)!.name, 'skill.jpg');
  });

  test('none drops all images and moves the record', () async {
    seedRecord('id-none');

    final ok = await archiveRecordAsync(argsFor('id-none', ArchiveImageOption.none));

    expect(ok, isTrue);
    final dst = DirectoryPath('${archiveDir.path}/id-none');
    expect(File('${dst.path}/record.json').readAsStringSync(), '{"id":"id-none"}');
    expect(File('${dst.path}/trainee.jpg').existsSync(), isTrue);
    // The overlay data is always dropped.
    expect(File('${dst.path}/prediction.json').existsSync(), isFalse);
    for (final name in ['skill', 'factor', 'campaign']) {
      expect(File('${dst.path}/$name.png').existsSync(), isFalse);
      expect(File('${dst.path}/$name.jpg').existsSync(), isFalse);
      // The geometry json is useless without its image, so it is dropped too.
      expect(File('${dst.path}/$name.json').existsSync(), isFalse);
    }
    // No image of any kind for an image-less archive.
    expect(resolveImagePathSync(dst, CharaDetailRecordImageMode.skillPlain), isNull);
  });

  test('archiving leaves id-keyed metadata outside the record tree untouched', () async {
    seedRecord('id-meta');
    final ratingDir = Directory('${tempRoot.path}/metadata/rating')..createSync(recursive: true);
    final rating = File('${ratingDir.path}/ratings.json')..writeAsStringSync('{"id-meta":5}');

    await archiveRecordAsync(argsFor('id-meta', ArchiveImageOption.none));

    expect(rating.readAsStringSync(), '{"id-meta":5}');
  });

  test('returns false when the source directory is missing', () async {
    expect(await archiveRecordAsync(argsFor('does-not-exist', ArchiveImageOption.none)), isFalse);
  });

  test('returns false and leaves the source intact when the destination already exists', () async {
    // A leftover archive/<id> (e.g. from an interrupted prior archive) must not
    // be silently merged into or clobbered; the record stays in active/.
    seedRecord('id-dup');
    Directory('${archiveDir.path}/id-dup').createSync(recursive: true);

    final ok = await archiveRecordAsync(argsFor('id-dup', ArchiveImageOption.none));

    expect(ok, isFalse);
    // Source untouched: its PNGs are still present (not stripped) and not moved.
    expect(File('${activeDir.path}/id-dup/skill.png').existsSync(), isTrue);
    expect(File('${activeDir.path}/id-dup/record.json').existsSync(), isTrue);
  });

  test('batch archives every record in one call, results aligned with input order', () async {
    // Mix a present record, a missing one, and another present one so the result
    // bools must line up by index (true, false, true), not just by count.
    seedRecord('id-a');
    seedRecord('id-c');
    final items = [
      argsFor('id-a', ArchiveImageOption.none),
      argsFor('id-missing', ArchiveImageOption.none),
      argsFor('id-c', ArchiveImageOption.resizedJpeg),
    ];

    final results = await archiveRecordsAsync(ArchiveBatchArgs(items));

    expect(results, [true, false, true]);
    expect(Directory('${archiveDir.path}/id-a').existsSync(), isTrue);
    expect(Directory('${archiveDir.path}/id-c').existsSync(), isTrue);
    expect(Directory('${activeDir.path}/id-a').existsSync(), isFalse);
    // A failed item leaves its source intact.
    expect(Directory('${activeDir.path}/id-missing').existsSync(), isFalse);
    // Per-record option is honored within the batch.
    expect(
      resolveImagePathSync(DirectoryPath('${archiveDir.path}/id-c'), CharaDetailRecordImageMode.skillPlain)!.name,
      'skill.jpg',
    );
  });

  test('a failed conversion keeps the original PNG rather than losing the image', () async {
    // A corrupt "PNG" cannot be decoded, so no JPEG is produced; the original must
    // survive rather than being deleted, and the record is still archived (image
    // disposition is best-effort once the move succeeds).
    final dir = Directory('${activeDir.path}/id-bad')..createSync(recursive: true);
    File('${dir.path}/record.json').writeAsStringSync('{"id":"id-bad"}');
    File('${dir.path}/skill.png').writeAsBytesSync(Uint8List.fromList([1, 2, 3, 4]));
    File('${dir.path}/skill.json').writeAsStringSync(intersectionJson(1000, 1500));

    final ok = await archiveRecordAsync(argsFor('id-bad', ArchiveImageOption.resizedJpeg));

    expect(ok, isTrue);
    final dst = DirectoryPath('${archiveDir.path}/id-bad');
    // The undecodable original is retained; no JPEG was written.
    expect(File('${dst.path}/skill.png').existsSync(), isTrue);
    expect(File('${dst.path}/skill.jpg').existsSync(), isFalse);
    // Its geometry json is left at the original size (no rescale without a result).
    expect(intersectionSizeOf('${dst.path}/skill.json'), (width: 1000, height: 1500));
    // ...and the transaction is finished, not parked. An undecodable PNG fails
    // identically on every retry, so a slot left at `cleaning` would never clear:
    // the web gate re-runs this cleanup before every acquisition of the record's
    // lock and would fail the same way every time.
    expect(transactionSlotsRemain(), isFalse);
    expect(await unfinishedSlotsFor('id-bad'), isEmpty);
  });

  test('an unreadable image disposition does not park the archive slot', () async {
    // The third member of the same family. `imageOption` is written once, when the
    // slot is created, and never rewritten -- so a value that does not map to an
    // ArchiveImageOption will not map on any retry either. Escalating it under
    // failOnError left the manifest at `cleaning` for good, and the web gate
    // re-runs this cleanup before every acquisition of the record's lock.
    const id = 'id-badoption';
    final destination = Directory('${archiveDir.path}/$id')..createSync(recursive: true);
    File('${destination.path}/record.json').writeAsStringSync('{"id":"$id"}');
    File('${destination.path}/skill.png').writeAsBytesSync(pngBytes(10, 10));
    final slot = Directory('${tempRoot.path}/.umacapture-transactions/v1/${_archiveSlotName(id)}')
      ..createSync(recursive: true);
    final payload = Directory('${slot.path}/payload')..createSync(recursive: true);
    File('${payload.path}/record.json').writeAsStringSync('{"id":"$id"}');
    File('${payload.path}/skill.png').writeAsBytesSync(pngBytes(10, 10));
    File('${slot.path}/manifest.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'transactionId': '123e4567-e89b-42d3-a456-426614174000',
        'operation': 'archive',
        'recordId': id,
        'sourcePath': '${activeDir.path}/$id',
        'destinationPath': destination.path,
        'state': 'cleaning',
        'metadata': {'imageOption': 'no-such-option'},
      }),
    );

    // Finished, not parked, and retried forever.
    expect(await unfinishedSlotsFor(id), isEmpty);
    expect(transactionSlotsRemain(), isFalse);
    // The conservative direction: an unreadable disposition keeps the images
    // rather than guessing which of "drop" or "downscale" was meant.
    expect(File('${destination.path}/skill.png').existsSync(), isTrue);
  });

  test('an unparsable geometry json does not wedge the archive transaction', () async {
    // The other half of the same hazard: the geometry rewrite is driven by record
    // content too, so a corrupt *.json must not make the (already committed)
    // transaction unfinishable either.
    final dir = Directory('${activeDir.path}/id-badjson')..createSync(recursive: true);
    File('${dir.path}/record.json').writeAsStringSync('{"id":"id-badjson"}');
    File('${dir.path}/skill.png').writeAsBytesSync(pngBytes(1000, 1500));
    File('${dir.path}/skill.json').writeAsStringSync('} not json {');

    final ok = await archiveRecordAsync(argsFor('id-badjson', ArchiveImageOption.resizedJpeg));

    expect(ok, isTrue);
    final dst = DirectoryPath('${archiveDir.path}/id-badjson');
    // The convertible image is still replaced; only its rescale was skipped.
    expect(File('${dst.path}/skill.jpg').existsSync(), isTrue);
    expect(File('${dst.path}/skill.png').existsSync(), isFalse);
    expect(transactionSlotsRemain(), isFalse);
    expect(await unfinishedSlotsFor('id-badjson'), isEmpty);
  });
}

String _archiveSlotName(String id) => base64Url.encode(utf8.encode('archive:$id')).replaceAll('=', '');
