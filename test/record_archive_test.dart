// Verifies the per-record archive file operation: recognition PNGs are dropped
// or replaced with JPEGs, the record directory is moved from active/ to
// archive/, and record.json / trainee.jpg survive. The large prediction.json is
// always dropped; the geometry *.json is rescaled to the downscaled JPEG when
// images are kept and dropped when images are dropped. A one-time migration
// brings already-archived records into the same state. Metadata stored outside
// the record tree is untouched.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_archive_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/path_entity.dart';

void main() {
  late Directory tempRoot;
  late Directory activeDir;
  late Directory archiveDir;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_archive_test');
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

  test('resizedJpeg replaces PNGs with JPEGs and moves the record', () {
    seedRecord('id-jpeg');

    final ok = archiveRecordInIsolate(argsFor('id-jpeg', ArchiveImageOption.resizedJpeg));

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
    // resolveImagePath prefers the archived JPEG.
    expect(resolveImagePath(dst, CharaDetailRecordImageMode.skillPlain)!.name, 'skill.jpg');
  });

  test('none drops all images and moves the record', () {
    seedRecord('id-none');

    final ok = archiveRecordInIsolate(argsFor('id-none', ArchiveImageOption.none));

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
    expect(resolveImagePath(dst, CharaDetailRecordImageMode.skillPlain), isNull);
  });

  test('archiving leaves id-keyed metadata outside the record tree untouched', () {
    seedRecord('id-meta');
    final ratingDir = Directory('${tempRoot.path}/metadata/rating')..createSync(recursive: true);
    final rating = File('${ratingDir.path}/ratings.json')..writeAsStringSync('{"id-meta":5}');

    archiveRecordInIsolate(argsFor('id-meta', ArchiveImageOption.none));

    expect(rating.readAsStringSync(), '{"id-meta":5}');
  });

  test('returns false when the source directory is missing', () {
    expect(archiveRecordInIsolate(argsFor('does-not-exist', ArchiveImageOption.none)), isFalse);
  });

  test('returns false and leaves the source intact when the destination already exists', () {
    // A leftover archive/<id> (e.g. from an interrupted prior archive) must not
    // be silently merged into or clobbered; the record stays in active/.
    seedRecord('id-dup');
    Directory('${archiveDir.path}/id-dup').createSync(recursive: true);

    final ok = archiveRecordInIsolate(argsFor('id-dup', ArchiveImageOption.none));

    expect(ok, isFalse);
    // Source untouched: its PNGs are still present (not stripped) and not moved.
    expect(File('${activeDir.path}/id-dup/skill.png').existsSync(), isTrue);
    expect(File('${activeDir.path}/id-dup/record.json').existsSync(), isTrue);
  });

  test('batch archives every record in one call, results aligned with input order', () {
    // Mix a present record, a missing one, and another present one so the result
    // bools must line up by index (true, false, true), not just by count.
    seedRecord('id-a');
    seedRecord('id-c');
    final items = [
      argsFor('id-a', ArchiveImageOption.none),
      argsFor('id-missing', ArchiveImageOption.none),
      argsFor('id-c', ArchiveImageOption.resizedJpeg),
    ];

    final results = archiveRecordsInIsolate(ArchiveBatchArgs(items));

    expect(results, [true, false, true]);
    expect(Directory('${archiveDir.path}/id-a').existsSync(), isTrue);
    expect(Directory('${archiveDir.path}/id-c').existsSync(), isTrue);
    expect(Directory('${activeDir.path}/id-a').existsSync(), isFalse);
    // Per-record option is honored within the batch.
    expect(
      resolveImagePath(DirectoryPath('${archiveDir.path}/id-c'), CharaDetailRecordImageMode.skillPlain)!.name,
      'skill.jpg',
    );
  });

  // Seeds archive/<id>/ as a record archived before geometry json was kept in sync:
  // downscaled JPEGs, stale full-size geometry json, and a leftover prediction.json.
  String seedStaleArchive(String id) {
    final dir = Directory('${archiveDir.path}/$id')..createSync(recursive: true);
    File('${dir.path}/record.json').writeAsStringSync('{"id":"$id"}');
    File('${dir.path}/trainee.jpg').writeAsBytesSync(jpgBytes(60, 60));
    File('${dir.path}/prediction.json').writeAsStringSync('{"status_header":[]}');
    for (final name in ['skill', 'factor', 'campaign']) {
      File('${dir.path}/$name.jpg').writeAsBytesSync(jpgBytes(720, 1280));
      File('${dir.path}/$name.json').writeAsStringSync(intersectionJson(743, 1321));
    }
    return dir.path;
  }

  test('migration rescales stale geometry json to the archived JPEG and drops prediction.json', () {
    final dst = seedStaleArchive('id-stale');

    final count = migrateArchivedRecordsInIsolate(archiveDir.path);

    expect(count, 1);
    expect(File('$dst/prediction.json').existsSync(), isFalse);
    for (final name in ['skill', 'factor', 'campaign']) {
      expect(File('$dst/$name.jpg').existsSync(), isTrue);
      expect(intersectionSizeOf('$dst/$name.json'), (width: 720, height: 1280));
    }
    // Retained files untouched.
    expect(File('$dst/record.json').readAsStringSync(), '{"id":"id-stale"}');
    expect(File('$dst/trainee.jpg').existsSync(), isTrue);
  });

  test('migration drops geometry json for an image-less archived record', () {
    // An older "none" archive: geometry json present but no image of any kind.
    final dir = Directory('${archiveDir.path}/id-imageless')..createSync(recursive: true);
    File('${dir.path}/record.json').writeAsStringSync('{"id":"id-imageless"}');
    File('${dir.path}/prediction.json').writeAsStringSync('{"status_header":[]}');
    for (final name in ['skill', 'factor', 'campaign']) {
      File('${dir.path}/$name.json').writeAsStringSync(intersectionJson(743, 1321));
    }

    migrateArchivedRecordsInIsolate(archiveDir.path);

    expect(File('${dir.path}/prediction.json').existsSync(), isFalse);
    for (final name in ['skill', 'factor', 'campaign']) {
      expect(File('${dir.path}/$name.json').existsSync(), isFalse);
    }
    expect(File('${dir.path}/record.json').existsSync(), isTrue);
  });

  test('migration is idempotent: a second run leaves an already-correct record unchanged', () {
    final dst = seedStaleArchive('id-twice');

    migrateArchivedRecordsInIsolate(archiveDir.path);
    final afterFirst = {
      for (final n in ['skill', 'factor', 'campaign']) n: File('$dst/$n.json').readAsStringSync(),
    };
    migrateArchivedRecordsInIsolate(archiveDir.path);

    for (final name in ['skill', 'factor', 'campaign']) {
      expect(File('$dst/$name.json').readAsStringSync(), afterFirst[name]);
      expect(intersectionSizeOf('$dst/$name.json'), (width: 720, height: 1280));
    }
  });
}
