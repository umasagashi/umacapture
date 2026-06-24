// Verifies the per-record archive file operation: recognition PNGs are dropped
// or replaced with JPEGs, the record directory is moved from active/ to
// archive/, and the retained files (record.json, trainee.jpg, geometry *.json)
// survive byte-for-byte. Metadata stored outside the record tree is untouched.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_archive_test.dart
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

  // Seeds active/<id>/ with the full set of files a captured record carries.
  String seedRecord(String id) {
    final dir = Directory('${activeDir.path}/$id')..createSync(recursive: true);
    File('${dir.path}/record.json').writeAsStringSync('{"id":"$id"}');
    File('${dir.path}/trainee.jpg').writeAsBytesSync(pngBytes(60, 60));
    for (final name in ['skill', 'factor', 'campaign']) {
      File('${dir.path}/$name.png').writeAsBytesSync(pngBytes(1000, 1500));
      File('${dir.path}/$name.json').writeAsStringSync('{"intersection":{}}');
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
    // Retained files preserved byte-for-byte.
    expect(File('${dst.path}/record.json').readAsStringSync(), '{"id":"id-jpeg"}');
    expect(File('${dst.path}/trainee.jpg').existsSync(), isTrue);
    expect(File('${dst.path}/skill.json').existsSync(), isTrue);
    // PNGs replaced with JPEGs.
    for (final name in ['skill', 'factor', 'campaign']) {
      expect(File('${dst.path}/$name.png').existsSync(), isFalse);
      expect(File('${dst.path}/$name.jpg').existsSync(), isTrue);
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
    for (final name in ['skill', 'factor', 'campaign']) {
      expect(File('${dst.path}/$name.png').existsSync(), isFalse);
      expect(File('${dst.path}/$name.jpg').existsSync(), isFalse);
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
}
