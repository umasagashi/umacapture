import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_directory_transaction.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/root_storage_maintenance.dart';
import 'package:umacapture/src/core/fs/root_storage_maintenance_shared.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/web_like_fs_backend.dart';

void main() {
  late Directory root;
  late FsBackend originalBackend;

  setUp(() {
    originalBackend = fsBackend;
    fsBackend = WebLikeFsBackend(originalBackend);
    root = Directory.systemTemp.createTempSync('umacapture_recovery_cleanup_lock');
  });

  tearDown(() {
    fsBackend = originalBackend;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  // The claim is about the pass production actually runs: `JournalRootStorageMaintenance`
  // takes the root lock once and calls the unlocked recovery and the deferred
  // image cleanup inside it. `root_storage_maintenance_test.dart` asserts that
  // ordering against stubs; this case asserts it against a real journal slot, so
  // the cleanup observed inside the lock is a real file deletion.
  test('recovered archive cleanup remains inside the root lock the startup sweep takes', () async {
    const id = 'cleanup-lock';
    final source = Directory('${root.path}/active/$id')..createSync(recursive: true);
    File('${source.path}/record.json').writeAsStringSync('{"id":"$id"}');
    File('${source.path}/prediction.json').writeAsStringSync('{}');
    final destination = DirectoryPath('${root.path}/archive/$id');
    final transaction = RecordDirectoryTransaction(
      onCheckpoint: (checkpoint) async {
        if (checkpoint == RecordTransactionCheckpoint.beforeCleanup) {
          throw StateError('leave a completed publish for startup recovery');
        }
      },
    );
    final spec = RecordDirectoryTransactionSpec(
      recordId: id,
      source: DirectoryPath(source.path),
      destination: destination,
      metadata: const {'imageOption': 'none'},
    );
    expect(await transaction.execute(spec), RecordTransactionResult.cleanupPending);
    expect(await destination.filePath('prediction.json').exists(), isTrue);

    var rootLocked = false;
    var rootLockCalls = 0;
    var cleanupObservedInsideLock = false;
    final lock = RecordMutationLock((name, mode, action) async {
      expect(name, contains(':root'));
      expect(mode, RecordMutationLockMode.exclusive);
      rootLockCalls++;
      rootLocked = true;
      try {
        return await action();
      } finally {
        rootLocked = false;
      }
    });
    fsBackend = _ObserveDeleteBackend(originalBackend, (path) {
      if (path.endsWith('prediction.json')) {
        cleanupObservedInsideLock = rootLocked;
      }
    });

    await JournalRootStorageMaintenance.bothJournals(mutationLock: lock).run(
      RootStorageMaintenanceRequest(recordDataRoot: DirectoryPath(root.path), reason: RootMaintenanceReason.readyToUse),
    );

    expect(rootLockCalls, 1);
    expect(cleanupObservedInsideLock, isTrue);
    expect(await destination.filePath('prediction.json').exists(), isFalse);
  });
}

final class _ObserveDeleteBackend extends WebLikeFsBackend {
  _ObserveDeleteBackend(super.inner, this.onDelete);

  final void Function(String path) onDelete;

  @override
  Future<void> delete(String path, {bool recursive = false}) {
    onDelete(path);
    return super.delete(path, recursive: recursive);
  }
}
