// Verifies the async (web / OPFS) record loader quarantines a record whose
// `record.json` cannot be decoded: the directory is moved aside into a sibling
// `quarantine/` folder (preserving its files), disappears from the scanned
// `active/` tree, and the failure surfaces as data (RecordQuarantined) rather
// than a thrown exception. Also covers DirectoryPath.moveAsyncSafe directly.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_quarantine_async_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/web_like_fs_backend.dart';

void main() {
  setUpAll(initializeMappers);

  late Directory tempRoot;
  late FsBackend originalBackend;

  setUp(() {
    originalBackend = fsBackend;
    tempRoot = Directory.systemTemp.createTempSync('umacapture_quarantine_async_test');
    // ON THE WEB-LIKE BACKEND, which is what makes this file about the loader it names. Every
    // synchronous FsBackend method throws here, exactly as `WebFsBackend` does, so a shared path
    // that reaches for `existsSync` / `isFileSync` -- the branch `copyTreeInto`'s doc warns about --
    // fails on the VM instead of quietly working. Without it the three cases below ran on io, where
    // the sync surface works, and the one invariant this suite exists to hold was unobserved. The
    // sibling web-record suites all install it in `setUp`; this one only did so in its fourth case.
    fsBackend = WebLikeFsBackend(originalBackend);
  });

  tearDown(() {
    fsBackend = originalBackend;
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

  test('loadAsync quarantines an undecodable record instead of deleting it', () async {
    // `{}` lacks every required field, so the strict dart_mappable decoder throws.
    final dir = seedRecord('id-001', '{}');

    final result = await CharaDetailRecord.loadAsync(dir);

    expect(result, isA<RecordQuarantined>());
    // (a) The contents are preserved under the sibling quarantine/<id>.
    final quarantined = Directory('${tempRoot.path}/quarantine/id-001');
    expect(quarantined.existsSync(), isTrue);
    expect(File('${quarantined.path}/record.json').existsSync(), isTrue);
    expect(File('${quarantined.path}/trainee.jpg').readAsStringSync(), 'image-bytes');
    // (b) The original active directory is gone (moved, not lingering).
    expect(Directory(dir.path).existsSync(), isFalse);
    final destination = (result as RecordQuarantined).destination;
    expect(destination, isNotNull);
    expect(destination!.name, 'id-001');
  });

  test('loadAsync returns the failure as data and never rethrows', () async {
    final dir = seedRecord('id-002', 'not valid json');

    // (c) The decode failure completes with RecordQuarantined, not an exception.
    await expectLater(CharaDetailRecord.loadAsync(dir), completion(isA<RecordQuarantined>()));
    expect(Directory('${tempRoot.path}/quarantine/id-002').existsSync(), isTrue);
  });

  test('quarantineAsyncUnlocked resolves id collisions with a numeric suffix', () async {
    // A record with this id was already quarantined in a previous run.
    Directory('${tempRoot.path}/quarantine/id-003').createSync(recursive: true);
    final dir = seedRecord('id-003', '{}');

    final destination = await CharaDetailRecord.quarantineAsyncUnlocked(dir);

    expect(destination, isNotNull);
    expect(destination!.name, 'id-003_1');
    expect(Directory('${tempRoot.path}/quarantine/id-003_1').existsSync(), isTrue);
    expect(Directory(dir.path).existsSync(), isFalse);
  });

  test('an interrupted quarantine loses nothing, and the next scan finishes it', () async {
    // The copy fails part-way. Nothing is committed and nothing is lost: the
    // record is still whole under `active/`, the partial destination is not
    // left standing, and the retry is an ordinary second attempt rather than a
    // torn slot somebody has to repair.
    const id = 'torn-copy';
    final dir = seedRecord(id, '{}');
    fsBackend = _FailImageCopyBackend(originalBackend);

    expect(await CharaDetailRecord.quarantineAsyncUnlocked(dir), isNull);
    expect(Directory(dir.path).existsSync(), isTrue);
    expect(File('${dir.path}/record.json').readAsStringSync(), '{}');

    fsBackend = WebLikeFsBackend(originalBackend);
    final destination = await CharaDetailRecord.quarantineAsyncUnlocked(dir);

    expect(destination, isNotNull);
    expect(Directory(dir.path).existsSync(), isFalse);
    expect(File('${destination!.path}/trainee.jpg').readAsStringSync(), 'image-bytes');
  });

  test('quarantines a record that lives in archive/, not only one in active/', () async {
    // `CharaDetailArchiveStorage.build` scans `archive/` and quarantines what it
    // cannot decode, so the async path has to take an archived source as well.
    // The destination is derived from the source's grandparent, so an archived
    // record must land in the same sibling `quarantine/` an active one does --
    // not in `archive/quarantine/`.
    const id = 'archived-id';
    final dir = Directory('${tempRoot.path}/archive/$id')..createSync(recursive: true);
    File('${dir.path}/record.json').writeAsStringSync('{}');
    File('${dir.path}/trainee.jpg').writeAsStringSync('archived-bytes');

    final result = await CharaDetailRecord.loadAsync(DirectoryPath(dir));

    expect(result, isA<RecordQuarantined>());
    expect((result as RecordQuarantined).destination?.name, id);
    expect(File('${tempRoot.path}/quarantine/$id/trainee.jpg').readAsStringSync(), 'archived-bytes');
    expect(Directory('${tempRoot.path}/archive/quarantine').existsSync(), isFalse);
    expect(dir.existsSync(), isFalse);
  });

  test('moveAsyncSafe moves a directory tree and removes the source', () async {
    final src = Directory('${tempRoot.path}/src')..createSync(recursive: true);
    File('${src.path}/a.txt').writeAsStringSync('alpha');
    Directory('${src.path}/sub').createSync(recursive: true);
    File('${src.path}/sub/b.txt').writeAsStringSync('beta');

    final destination = await DirectoryPath(src).moveAsyncSafe(DirectoryPath('${tempRoot.path}/dst'));

    expect(destination, isNotNull);
    // The source is gone and the whole tree (nested file included) landed intact.
    expect(Directory(src.path).existsSync(), isFalse);
    expect(File('${tempRoot.path}/dst/a.txt').readAsStringSync(), 'alpha');
    expect(File('${tempRoot.path}/dst/sub/b.txt').readAsStringSync(), 'beta');
  });
}

/// Fails the copy of one file in the middle of the tree, leaving the rest of it
/// already written.
final class _FailImageCopyBackend extends WebLikeFsBackend {
  _FailImageCopyBackend(super.inner);

  @override
  Future<void> copyFile(String source, String destination) {
    if (destination.endsWith('trainee.jpg')) {
      throw FileSystemException('Synthetic copy failure', destination);
    }
    return super.copyFile(source, destination);
  }
}
