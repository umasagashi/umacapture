// Shared Hive setup for tests that exercise Hive-backed storage.
import 'dart:io';
import 'dart:typed_data';

import 'package:hive_ce/hive.dart';
import 'package:recase/recase.dart';
import 'package:umacapture/src/preference/storage_box.dart';

/// Initializes Hive against a throwaway temp directory and opens [boxes].
///
/// Returns a teardown callback that closes Hive and removes the temp directory;
/// register it with `addTearDown` or invoke it in `tearDownAll`. Callers that
/// need a clean box per test can `Hive.box(name).clear()` in `setUp`.
Future<Future<void> Function()> initHiveForTest(List<String> boxes) {
  return _hiveInTempDir((_) => _openInMemory(boxes));
}

/// Opens the app's [StorageBox] boxes against a throwaway temp directory.
///
/// The `StorageBox` counterpart of [initHiveForTest], with the same teardown
/// contract. Use it when the code under test reaches Hive through `StorageBox`
/// rather than through named boxes: `ensureOpened` registers the Hive adapters
/// and opens every `StorageBoxKey` box, neither of which [initHiveForTest] does.
Future<Future<void> Function()> openStorageBoxForTest() {
  return _hiveInTempDir((dir) async {
    // Opened first, and in memory, so that `ensureOpened` finds them already
    // open and its own `Hive.openBox` calls hand back these instead of creating
    // files. Derived from `StorageBoxKey.values` rather than listed, so a new
    // key cannot be left behind on disk. Mirrors `StorageBox`'s own naming.
    await _openInMemory(StorageBoxKey.values.map((e) => e.name.snakeCase).toList());
    // Still called, because it is what registers the adapters and is the path
    // the app itself takes; only its box creation is pre-empted above.
    await StorageBox.ensureOpened(directory: dir.path);
  });
}

/// Opens each of [boxes] as a memory-backed box.
///
/// Tests want an empty box, not a database: a box opened with `bytes` uses
/// `StorageBackendMemory`, which writes no file and holds no handle. That is not
/// only cheaper, it is the only form that can be torn down reliably here. A
/// disk-backed box serializes its writes behind a lock, and a write issued from
/// inside a `testWidgets` fake-async zone leaves a continuation that only that
/// (now discarded) zone could run — so `Hive.close()` waits on the lock forever,
/// the box file stays open, and on Windows deleting the directory under it fails
/// with a sharing violation. Measured: nine widget suites hung in `tearDownAll`
/// on `Hive.close()` and then failed the delete with errno 32.
Future<void> _openInMemory(List<String> boxes) async {
  for (final box in boxes) {
    await Hive.openBox(box, bytes: Uint8List(0));
  }
}

/// Creates the temp directory, runs [open] against it, and returns its teardown.
///
/// The directory is Hive's `homePath`: nothing is written there while every box
/// is memory-backed, but it keeps a box that is opened some other way pointed at
/// a disposable location instead of the developer's real settings directory.
///
/// The directory has exactly one owner, and it is the returned callback. When
/// [open] throws, the caller never receives that callback, so the removal has to
/// happen here or the directory is stranded in the system temp dir with no
/// reference left anywhere that could delete it.
Future<Future<void> Function()> _hiveInTempDir(Future<void> Function(Directory) open) async {
  final dir = Directory.systemTemp.createTempSync('umacapture_hive_test');
  Hive.init(dir.path);
  try {
    await open(dir);
  } catch (_) {
    // Hive may be only half initialized, so closing is best effort — but the
    // removal is not, since swallowing a failure there is the very leak this
    // helper exists to prevent.
    try {
      await Hive.close();
    } catch (_) {
      // Fall through to the removal; a close failure must not strand the directory.
    }
    _remove(dir);
    rethrow;
  }
  return () async {
    await Hive.close();
    _remove(dir);
  };
}

void _remove(Directory dir) {
  if (dir.existsSync()) {
    dir.deleteSync(recursive: true);
  }
}
