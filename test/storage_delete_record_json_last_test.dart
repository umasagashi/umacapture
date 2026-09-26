// A delete that fails partway must leave a record, not a casualty.
//
// The record erasure was one recursive delete. A recursive delete keeps whatever it has already
// erased erased, so a failure after `record.json` went first left a directory with no `record.json`
// in it. The user was told the delete failed and the row stayed in the table -- and then the next
// launch scanned that directory, failed to decode it, and moved it aside as unreadable. A delete
// that failed turned into a record reported as broken.
//
// Erasing every other entry first means a stop at any point leaves a directory that still decodes.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/storage_delete_record_json_last_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/web_like_fs_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeMappers);

  late Directory tempRoot;
  late FsBackend originalBackend;
  late String fixtureJson;
  late String fixtureId;

  setUpAll(() {
    fixtureJson = File('test/fixtures/chara_detail_record.json').readAsStringSync();
    fixtureId = CharaDetailRecordMapper.fromJson(fixtureJson).id;
  });

  setUp(() {
    originalBackend = fsBackend;
    tempRoot = Directory.systemTemp.createTempSync('umacapture_delete_order');
  });
  tearDown(() {
    fsBackend = originalBackend;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  // A real record directory: the decodable `record.json` plus two of the images that sit beside it.
  DirectoryPath seed() {
    final dir = Directory('${tempRoot.path}/active/$fixtureId')..createSync(recursive: true);
    File('${dir.path}/record.json').writeAsStringSync(fixtureJson);
    File('${dir.path}/trainee.jpg').writeAsBytesSync([1, 2, 3]);
    File('${dir.path}/skill.png').writeAsBytesSync([4, 5, 6]);
    return DirectoryPath(dir.path);
  }

  test('a failed erasure leaves a directory that still decodes as its own record', () async {
    final dir = seed();
    fsBackend = _FailDeleteBackend(originalBackend, (path) => path.endsWith('skill.png'));

    await expectLater(deleteRecordDirectoryVerifiedAsync(dir), throwsA(isA<FileSystemException>()));

    // What the next scan will find: the record is still there, still claims this directory's id,
    // so it loads as a record rather than being quarantined as unreadable.
    final json = dir.filePath('record.json');
    expect(await json.exists(), isTrue);
    final record = CharaDetailRecordMapper.fromJson(await json.readAsString());
    expect(() => CharaDetailRecord.validateDirectoryId(dir, record), returnsNormally);
  });

  test('erases record.json after every other entry', () async {
    final dir = seed();
    final order = <String>[];
    fsBackend = _RecordDeleteOrderBackend(originalBackend, order);

    await deleteRecordDirectoryVerifiedAsync(dir);

    final files = order.where((path) => path.endsWith('.json') || path.endsWith('.jpg') || path.endsWith('.png'));
    expect(files.last, endsWith('record.json'));
  });

  // Negative control: an erasure that meets no failure still erases the whole record.
  test('still deletes the record directory when nothing fails', () async {
    final dir = seed();

    await deleteRecordDirectoryVerifiedAsync(dir);

    expect(await dir.exists(), isFalse);
  });

  // Negative control: "already gone" stays a success, which is what keeps a row deletable after
  // something outside this app removed the directory.
  test('still treats an absent directory as deleted', () async {
    final dir = DirectoryPath('${tempRoot.path}/active/never-existed');
    await expectLater(deleteRecordDirectoryVerifiedAsync(dir), completes);
  });
}

class _FailDeleteBackend extends WebLikeFsBackend {
  _FailDeleteBackend(super.inner, this.shouldFail);

  final bool Function(String path) shouldFail;

  @override
  Future<void> delete(String path, {bool recursive = false}) {
    if (shouldFail(path)) {
      throw FileSystemException('Synthetic delete failure', path);
    }
    return super.delete(path, recursive: recursive);
  }
}

class _RecordDeleteOrderBackend extends WebLikeFsBackend {
  _RecordDeleteOrderBackend(super.inner, this.order);

  final List<String> order;

  @override
  Future<void> delete(String path, {bool recursive = false}) {
    order.add(path);
    return super.delete(path, recursive: recursive);
  }
}
