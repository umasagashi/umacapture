// Shared Hive setup for tests that exercise Hive-backed storage.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:recase/recase.dart';
import 'package:umacapture/src/preference/storage_box.dart';

/// Registers a Hive fixture for the enclosing group: [boxes] are open for every
/// test in it, and the temp directory is removed after the last one.
///
/// Call this from the group (or `main`) body — not from inside a `setUpAll`.
/// This is the form to reach for, because it owns both halves of the fixture:
/// a `setUpAll` that fails before the fixture exists cannot make the teardown
/// throw a second, unrelated error on top of the real one. Callers that need a
/// clean box per test can `Hive.box(name).clear()` in `setUp`.
///
/// **One live registration at a time — never nested.** None of these fixtures is
/// scoped to the boxes it opened, because Hive gives them nothing to scope to:
/// the teardown is `Hive.close()`, which closes `_boxes.values` — every box in
/// the process — and `Hive.init` assigns one process-wide `homePath`
/// (`hive_ce/src/hive_impl.dart`). So a second registration inside the extent of
/// a first — a nested `group`, or a `main`-body call plus a group-level one, and
/// in any mix of [useHiveForTest], [useHiveForEachTest] and
/// [useStorageBoxForTest] — closes the *outer* group's boxes at the inner one's
/// teardown, and the inner `Hive.init` has by then repointed `homePath` at a
/// directory that same teardown removes. Every test declared after the inner
/// group fails with `HiveError: Box not found. Did you forget to call
/// Hive.openBox()?` — measured, and a message that names Hive rather than this
/// file, which is why it is written down here instead of being left to be
/// diagnosed.
///
/// Sibling groups are not nesting and are fine: `package:test` awaits a group's
/// `tearDownAll` before the next group's `setUpAll`
/// (`test_core/src/runner/engine.dart`, `_runGroup`), so two extents never
/// overlap — that is the shape of every file that registers this twice today.
/// One call per file, or one per leaf group, never both.
///
/// See [_openInMemory] for what these boxes can and cannot do.
void useHiveForTest(List<String> boxes) => _useFixture(setUpAll, tearDownAll, () => _initHiveForTest(boxes));

/// The per-test counterpart of [useHiveForTest]: a fresh temp directory and a
/// fresh set of empty boxes for every test in the enclosing group.
///
/// Use it only where a test would otherwise have to undo the previous one's
/// writes; [useHiveForTest] plus `Hive.box(name).clear()` in a `setUp` is the
/// cheaper form and the common one.
///
/// The no-nesting rule on [useHiveForTest] applies here too, and across the two:
/// this teardown is the same process-global `Hive.close()`.
void useHiveForEachTest(List<String> boxes) => _useFixture(setUp, tearDown, () => _initHiveForTest(boxes));

/// The [StorageBox] counterpart of [useHiveForTest].
///
/// Use it when the code under test reaches Hive through `StorageBox` rather
/// than through named boxes: `ensureOpened` registers the Hive adapters and
/// opens every `StorageBoxKey` box, neither of which [useHiveForTest] does.
///
/// The no-nesting rule on [useHiveForTest] applies here too, and across the two:
/// this teardown is the same process-global `Hive.close()`.
void useStorageBoxForTest() => _useFixture(setUpAll, tearDownAll, _openStorageBoxForTest);

/// Registers both halves of a fixture, so that no suite has to hold the close
/// callback itself.
///
/// That the callback is unreachable from outside this file is the point: a
/// suite that stored it in a `late` variable would, whenever its setup failed
/// before the assignment, answer the teardown with a LateInitializationError
/// that buries the failure that actually happened. Here it is a nullable local
/// instead, so a fixture that never opened is simply not closed — and nothing
/// leaks, because `_hiveInTempDir` removes the directory on that path itself.
void _useFixture(
  void Function(dynamic Function()) registerSetUp,
  void Function(dynamic Function()) registerTearDown,
  Future<Future<void> Function()> Function() open,
) {
  Future<void> Function()? close;
  registerSetUp(() async => close = await open());
  registerTearDown(() async {
    await close?.call();
    close = null;
  });
}

/// Initializes Hive against a throwaway temp directory and opens [boxes].
///
/// Returns a teardown callback that closes Hive and removes the temp directory.
/// Private on purpose — see [_useFixture].
///
/// The boxes are memory-backed: see [_openInMemory] for what that costs.
Future<Future<void> Function()> _initHiveForTest(List<String> boxes) {
  return _hiveInTempDir((_) => _openInMemory(boxes));
}

/// Opens the app's [StorageBox] boxes against a throwaway temp directory.
///
/// The `StorageBox` counterpart of [_initHiveForTest], with the same teardown
/// contract, and private for the same reason.
Future<Future<void> Function()> _openStorageBoxForTest() {
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
/// with a sharing violation. Measured while writing this helper: adding a plain
/// `Hive.close()` + `deleteSync` teardown to the disk-backed fixtures left nine
/// widget suites reporting "(tearDownAll) did not complete", with the probe
/// logging `TimeoutException` from the close and `PathAccessException … errno =
/// 32` from the delete.
///
/// What it costs, and why it is affordable here: a memory box's `writeFrames` is
/// a no-op, so **a value put into one of these boxes is never encoded** — no
/// `TypeAdapter` runs, and `Box.put` cannot fail on a missing one. `readValue`,
/// `compact` and `deleteFromDisk` throw `UnsupportedError`, so
/// `StorageBox.ensureOpened(reset: true)` cannot be exercised against them. None
/// of that is a loss for the suites that use this fixture: they store primitives
/// and JSON strings and read them back within the same process, so Hive is
/// their fixture and not their subject. A suite that wants to assert Hive's
/// serialization or its on-disk reset must open a disk box itself, as
/// `storage_box_reset_test.dart` and `storage_box_test.dart` do.
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
    try {
      _remove(dir);
    } catch (error, stackTrace) {
      // The same precedence [closeHiveAndRemove] applies on the success path, for
      // the same reason: an unguarded `_remove` here throws *instead of* reaching
      // the `rethrow` below, so the setup failure the caller has to read is
      // replaced by its own consequence. When [open] fails after Hive has taken a
      // handle inside `dir`, those handles are what defeat `deleteSync`, and the
      // developer is shown `PathAccessException … errno = 32` naming a temp
      // directory instead of the error that broke the fixture.
      printOnFailure('failed to remove ${dir.path} after the Hive fixture failed to open: $error\n$stackTrace');
    }
    rethrow;
  }
  // Same asymmetry as above, and for the same reason: `Hive.close()` closes
  // every box in the process, including a disk-backed one some test opened for
  // itself, so it can genuinely throw here.
  return () => closeHiveAndRemove(dir);
}

/// Closes Hive and removes [dir], with a close failure taking precedence over a
/// removal failure.
///
/// Both halves have to happen: a close that throws must not strand the
/// directory, and the removal must not replace the close error with its own.
/// `try { close } finally { remove }` buys the first and loses the second — an
/// exception raised inside a `finally` *replaces* the one already in flight —
/// and the two failures are not independent. When the close fails because boxes
/// are still open (the only variant either form has ever been observed on; see
/// [_openInMemory]), the same handles defeat `deleteSync`, so the removal's
/// `PathAccessException … errno = 32` **always** buried the close's
/// `TimeoutException`: the symptom always buried the cause.
Future<void> closeHiveAndRemove(Directory dir) async {
  ({Object error, StackTrace stackTrace})? closeFailure;
  try {
    await Hive.close();
  } catch (error, stackTrace) {
    closeFailure = (error: error, stackTrace: stackTrace);
  }
  try {
    _remove(dir);
  } catch (error, stackTrace) {
    if (closeFailure == null) {
      // Nothing else went wrong, so a directory left behind is the failure worth
      // reporting, and swallowing it is the very leak this helper exists to stop.
      rethrow;
    }
    // Reported rather than thrown: it is the close failure's own consequence,
    // and the close failure is the one the caller needs to read.
    printOnFailure('failed to remove ${dir.path} after Hive.close() threw: $error\n$stackTrace');
  }
  if (closeFailure case final failure?) {
    Error.throwWithStackTrace(failure.error, failure.stackTrace);
  }
}

void _remove(Directory dir) {
  if (dir.existsSync()) {
    dir.deleteSync(recursive: true);
  }
}
