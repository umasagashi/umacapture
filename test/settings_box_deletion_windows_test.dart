// The stage-0 measurement the settings-group delete had to wait on: what
// actually happens when something tries to remove a settings box's `.hive`/`.lock` files
// on Windows (Dart VM) while `StorageBox.ensureOpened` still holds them open.
//
// The storage-management view's delete action for the "settings" group has to
// pick one of two shapes: "close Hive, then delete the files" or "delete the
// files directly and let a still-open box re-create them". Which one is safe
// is not a design choice, it is a fact about `hive_ce-2.19.3`'s VM backend
// (`StorageBackendVm.open()` — pub-cache
// hive_ce-2.19.3/lib/src/backend/vm/storage_backend_vm.dart:85-87 — opens the
// `.hive` file with plain `File.open()`/`File.open(mode: FileMode.writeOnlyAppend)`,
// and `dart:io`'s `File.open` does not pass `FILE_SHARE_DELETE`), and this
// suite measures that fact directly instead of assuming it.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/settings_box_deletion_windows_test.dart
//
// Findings pinned here -- this suite is the writeup:
//  * A raw delete of `settings.hive` while the box is open fails immediately
//    with a `PathAccessException` (a `FileSystemException` subtype) whose
//    `osError.errorCode` is 32 (`ERROR_SHARING_VIOLATION`). Same for the `.lock`
//    file, opened separately in `StorageBackendVm.initialize()`.
//  * Closing the box first (`Box.close()`) lets the same delete succeed --
//    that is the positive control that gives the failure above discriminating
//    power: it proves the harness *can* delete these files, so the sharing
//    violation is a fact about the open handle, not about how this test drives
//    Hive.
//  * `Hive.deleteBoxFromDisk(name)` called on a box that is *still open*
//    succeeds without throwing, because `HiveImpl.deleteBoxFromDisk` detects the
//    box is already registered (pub-cache hive_ce-2.19.3/lib/src/hive_impl.dart:270-282)
//    and calls `box.deleteFromDisk()` on it directly, which closes the file
//    handles itself before deleting (`StorageBackendVm._closeInternal` then
//    `_file.delete()` -- storage_backend_vm.dart:269-288). So the app does not
//    need to call `Hive.close()`/`markHiveClosed()` by hand before
//    deleting a settings box; going through Hive's own API is sufficient and
//    already does the close-then-delete sequencing atomically.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/hive.dart';

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('umacapture_settings_deletion_test'));
  // Best-effort: most tests below close every box themselves along the way, so by
  // teardown time there is nothing left for Hive.close() to do beyond the ones
  // that stayed open till the end. See support/hive.dart for why the ordering
  // (close failure over removal failure) matters.
  tearDown(() => closeHiveAndRemove(tempDir));

  test('positive control: with the box closed first, deleting the files succeeds', () async {
    await StorageBox.ensureOpened(directory: tempDir.path);
    final hiveFile = File(p.join(tempDir.path, 'settings.hive'));
    final lockFile = File(p.join(tempDir.path, 'settings.lock'));
    expect(hiveFile.existsSync(), isTrue, reason: 'ensureOpened must have created settings.hive');
    expect(lockFile.existsSync(), isTrue, reason: 'ensureOpened must have created settings.lock');

    await Hive.box('settings').close();
    // Box.close() already deletes the lock file itself (StorageBackendVm._closeInternal,
    // storage_backend_vm.dart:269-275), so only the .hive file is still there to remove.
    expect(lockFile.existsSync(), isFalse, reason: 'closing the box deletes its own .lock file');

    hiveFile.deleteSync();
    expect(hiveFile.existsSync(), isFalse, reason: 'a raw delete after close() must succeed -- this is the control');
  });

  test('a raw delete of the open .hive file fails with a Windows sharing violation', () async {
    await StorageBox.ensureOpened(directory: tempDir.path);
    final hiveFile = File(p.join(tempDir.path, 'settings.hive'));
    expect(hiveFile.existsSync(), isTrue);

    Object? caught;
    try {
      hiveFile.deleteSync();
    } catch (error) {
      caught = error;
    }

    // ignore: avoid_print
    print('[settings.hive delete while open] caught=${caught?.runtimeType} $caught');

    expect(
      caught,
      isNotNull,
      reason:
          'the box is still open (StorageBox.ensureOpened never closed it), so a raw delete must not silently '
          'succeed -- if it does, the whole premise of the "close first" design for the settings delete is '
          'wrong and this print line is the evidence',
    );
    expect(caught, isA<FileSystemException>());
    final fse = caught as FileSystemException;
    expect(fse.osError, isNotNull, reason: 'a Windows sharing violation must carry an OSError with a Win32 code');
    expect(
      fse.osError!.errorCode,
      32,
      reason:
          'ERROR_SHARING_VIOLATION (32) is what a delete against a handle opened without FILE_SHARE_DELETE '
          'produces; observed code was ${fse.osError!.errorCode} ("${fse.osError!.message}")',
    );

    // The file must still be there -- the failed delete must not have partially
    // succeeded or left the box's own view of the world inconsistent.
    expect(hiveFile.existsSync(), isTrue);
    expect(StorageBox(StorageBoxKey.settings).pull<int>('untouched'), isNull);
    StorageBox(StorageBoxKey.settings).push<int>('untouched', 1);
    expect(
      StorageBox(StorageBoxKey.settings).pull<int>('untouched'),
      1,
      reason: 'the box itself is unaffected by the failed delete attempt',
    );
  });

  test('a raw delete of the open .lock file fails the same way', () async {
    await StorageBox.ensureOpened(directory: tempDir.path);
    final lockFile = File(p.join(tempDir.path, 'settings.lock'));
    expect(lockFile.existsSync(), isTrue);

    Object? caught;
    try {
      lockFile.deleteSync();
    } catch (error) {
      caught = error;
    }

    // ignore: avoid_print
    print('[settings.lock delete while open] caught=${caught?.runtimeType} $caught');

    expect(caught, isNotNull, reason: 'the lock file is held open by StorageBackendVm.initialize()\'s lockRaf');
    expect(caught, isA<FileSystemException>());
    final fse = caught as FileSystemException;
    expect(fse.osError, isNotNull);
    expect(
      fse.osError!.errorCode,
      32,
      reason: 'observed code was ${fse.osError!.errorCode} ("${fse.osError!.message}")',
    );
  });

  test('Hive.deleteBoxFromDisk on a still-open box succeeds without a prior Hive.close() -- '
      'the API already closes the handles itself before deleting', () async {
    await StorageBox.ensureOpened(directory: tempDir.path);
    final hiveFile = File(p.join(tempDir.path, 'settings.hive'));
    final lockFile = File(p.join(tempDir.path, 'settings.lock'));
    expect(hiveFile.existsSync(), isTrue);
    expect(lockFile.existsSync(), isTrue);

    // No Box.close() / Hive.close() / StorageBox.markHiveClosed() call
    // here on purpose: the box is exactly as open as it is during a live app
    // session (ensureOpened's own Hive.openBox never closes it).
    await Hive.deleteBoxFromDisk('settings');

    expect(hiveFile.existsSync(), isFalse, reason: 'deleteBoxFromDisk must have closed the handle before deleting');
    expect(lockFile.existsSync(), isFalse);

    // Re-opening a fresh box under the same key must not resurrect the deleted
    // data -- it must come back empty, i.e. the delete was real, not a facade
    // in front of a file the box quietly recreated underneath it.
    final reopened = await Hive.openBox('settings');
    expect(reopened.isEmpty, isTrue);
    await reopened.close();
  });
}
