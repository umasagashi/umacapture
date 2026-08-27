// Verifies StorageBox.ensureOpened(reset: true) actually clears persisted data.
//
// Regression: the reset branch deleted boxes with an explicit `path:` argument.
// In the native-default branch that path is relative (appName/settings) while
// Hive resolves it under the documents dir, so the delete targeted the wrong
// folder and silently no-op'd. The fix drops the explicit path so the delete
// uses Hive's initialized home. This test exercises the absolute-`directory`
// branch (the native-default branch needs path_provider, unavailable in a plain
// unit test), pinning the round-trip: seed -> reopen-with-reset -> value gone.
//
// Lives in its own file so re-invoking ensureOpened (which re-registers Hive
// adapters, now guarded to be idempotent) stays isolated from other Hive tests.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/storage_box_reset_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/hive.dart';

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('umacapture_storagebox_reset_test'));
  // The fixture teardown from `support/hive.dart`, called directly: this suite opens Hive itself
  // (that is its subject) but owes the same cleanup, and the ordering between a failed close and a
  // failed removal is stated once, there. Written as two bare statements, a throwing `Hive.close()`
  // skipped the removal outright and left a scratch directory under `%TEMP%` that nothing sweeps.
  tearDown(() => closeHiveAndRemove(tempDir));

  test('ensureOpened(reset: true) wipes previously persisted values', () async {
    await StorageBox.ensureOpened(directory: tempDir.path);
    StorageBox(StorageBoxKey.settings).push<int>('k', 42);
    expect(StorageBox(StorageBoxKey.settings).pull<int>('k'), 42);
    await Hive.close();

    // Reopen with reset: the box must be gone from disk, not carried over.
    await StorageBox.ensureOpened(directory: tempDir.path, reset: true);
    expect(StorageBox(StorageBoxKey.settings).pull<int>('k'), isNull);
  });

  test('ensureOpened(reset: false) keeps previously persisted values', () async {
    await StorageBox.ensureOpened(directory: tempDir.path);
    StorageBox(StorageBoxKey.settings).push<int>('k', 7);
    await Hive.close();

    // Control case: without reset the value survives the reopen, proving the
    // wipe above is the reset flag's doing and not an unconditional clear.
    await StorageBox.ensureOpened(directory: tempDir.path);
    expect(StorageBox(StorageBoxKey.settings).pull<int>('k'), 7);
  });
}
