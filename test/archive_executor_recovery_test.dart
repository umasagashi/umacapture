import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/archive_executor.dart';
import 'package:umacapture/src/chara_detail/archive_executor_shared.dart';
import 'package:umacapture/src/core/fs/record_directory_transaction.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';

import 'support/web_like_fs_backend.dart';

void main() {
  late Directory tempRoot;
  late FsBackend originalBackend;

  setUp(() {
    originalBackend = fsBackend;
    tempRoot = Directory.systemTemp.createTempSync('umacapture_archive_recovery');
  });

  tearDown(() {
    fsBackend = originalBackend;
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  Directory seed(String id) {
    final dir = Directory('${tempRoot.path}/active/$id')..createSync(recursive: true);
    File('${dir.path}/record.json').writeAsStringSync('{"id":"$id"}');
    File('${dir.path}/trainee.jpg').writeAsBytesSync([1, 2, 3]);
    File('${dir.path}/skill.png').writeAsBytesSync([4, 5, 6]);
    return dir;
  }

  ArchiveRecordArgs args(String id) =>
      ArchiveRecordArgs('${tempRoot.path}/active/$id', '${tempRoot.path}/archive/$id', ArchiveImageOption.none);

  test('source delete failure is unsuccessful and an identical retry completes safely', () async {
    seed('retry');
    fsBackend = _FailSourceDeleteBackend(originalBackend, (path) => path.endsWith('${Platform.pathSeparator}retry'));

    expect(await archiveRecordAsync(args('retry')), isFalse);
    // The copy is kept for recovery, but the active source remains authoritative
    // until its deletion succeeds, so the controller must not remove it in memory.
    expect(Directory('${tempRoot.path}/active/retry').existsSync(), isTrue);
    expect(Directory('${tempRoot.path}/archive/retry').existsSync(), isTrue);

    fsBackend = originalBackend;
    expect(await archiveRecordAsync(args('retry')), isTrue);
    expect(Directory('${tempRoot.path}/active/retry').existsSync(), isFalse);
    expect(Directory('${tempRoot.path}/archive/retry').existsSync(), isTrue);
  });

  test('committed archive remains successful while manifest cleanup is pending', () async {
    const id = 'manifest-pending';
    final source = seed(id);
    File('${source.path}/prediction.json').writeAsStringSync('{}');
    fsBackend = _FailManifestWriteAfterSourceDeleteBackend(originalBackend, source.path);

    expect(await archiveRecordAsync(args(id)), isTrue);
    expect(source.existsSync(), isFalse);
    expect(Directory('${tempRoot.path}/archive/$id').existsSync(), isTrue);
    expect(File('${tempRoot.path}/archive/$id/prediction.json').existsSync(), isTrue);

    fsBackend = originalBackend;
    // The two entry points the web startup sweep runs, in the order it runs
    // them; `JournalRootStorageMaintenance` supplies the root lock around both.
    final recovered = await recoverArchiveTransactionsUnlocked(DirectoryPath(tempRoot.path));
    await cleanupRecoveredArchiveTransactionsUnlocked(recovered);
    expect(recovered.single.result, RecordTransactionResult.completed);
    expect(File('${tempRoot.path}/archive/$id/prediction.json').existsSync(), isFalse);
  });

  test('partial or divergent existing destination is left untouched', () async {
    final source = seed('partial');
    final destination = Directory('${tempRoot.path}/archive/partial')..createSync(recursive: true);
    // A plausible interrupted copy, but not a complete duplicate.
    File('${destination.path}/record.json').writeAsStringSync('{"id":"partial"}');

    expect(await archiveRecordAsync(args('partial')), isFalse);
    expect(source.existsSync(), isTrue);
    expect(File('${source.path}/skill.png').existsSync(), isTrue);
    expect(File('${destination.path}/record.json').readAsStringSync(), '{"id":"partial"}');
    expect(File('${destination.path}/skill.png').existsSync(), isFalse);
  });

  test('copy failure leaves the source and cleans the new partial destination', () async {
    final source = seed('copy-fail');
    fsBackend = _FailCopyBackend(originalBackend, (path) => path.endsWith('skill.png'));

    expect(await archiveRecordAsync(args('copy-fail')), isFalse);
    expect(source.existsSync(), isTrue);
    expect(Directory('${tempRoot.path}/archive/copy-fail').existsSync(), isFalse);
  });
  test('batch continues in order when one copied source cannot be deleted', () async {
    seed('a');
    seed('b');
    seed('c');
    fsBackend = _FailSourceDeleteBackend(originalBackend, (path) => path.endsWith('${Platform.pathSeparator}b'));

    final results = await archiveRecordsAsync(ArchiveBatchArgs([args('a'), args('b'), args('c')]));

    expect(results, [true, false, true]);
    expect(Directory('${tempRoot.path}/active/a').existsSync(), isFalse);
    expect(Directory('${tempRoot.path}/active/b').existsSync(), isTrue);
    expect(Directory('${tempRoot.path}/active/c').existsSync(), isFalse);
    expect(Directory('${tempRoot.path}/archive/a').existsSync(), isTrue);
    expect(Directory('${tempRoot.path}/archive/b').existsSync(), isTrue);
    expect(Directory('${tempRoot.path}/archive/c').existsSync(), isTrue);
  });
}

class _FailSourceDeleteBackend extends WebLikeFsBackend {
  _FailSourceDeleteBackend(super.inner, this.shouldFail);

  final bool Function(String path) shouldFail;

  @override
  Future<void> delete(String path, {bool recursive = false}) {
    if (recursive && shouldFail(path)) {
      throw FileSystemException('Synthetic source delete failure', path);
    }
    return super.delete(path, recursive: recursive);
  }
}

class _FailCopyBackend extends WebLikeFsBackend {
  _FailCopyBackend(super.inner, this.shouldFail);

  final bool Function(String path) shouldFail;

  @override
  Future<void> copyFile(String source, String destination) {
    if (shouldFail(source)) {
      throw FileSystemException('Synthetic copy failure', source);
    }
    return super.copyFile(source, destination);
  }
}

class _FailManifestWriteAfterSourceDeleteBackend extends WebLikeFsBackend {
  _FailManifestWriteAfterSourceDeleteBackend(super.inner, this.sourcePath);

  final String sourcePath;

  @override
  Future<void> writeString(String path, String contents) {
    if (path.endsWith('manifest.json') && !Directory(sourcePath).existsSync()) {
      throw FileSystemException('Synthetic manifest transition failure', path);
    }
    return super.writeString(path, contents);
  }
}
