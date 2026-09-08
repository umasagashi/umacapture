// Verifies the data-root migration guard in StorageBox: once Hive is closed for
// a migration, every box operation must no-op instead of throwing on a closed
// box, so the many non-interactive writers that may still fire before the forced
// restart cannot crash.
//
// NOTE: StorageBox.markHiveClosed() flips a process-global, one-way flag.
// This lives in its own test file so the flag never leaks into other Hive-backed
// tests (flutter test isolates each file).
//
// Run: .fvm/flutter_sdk/bin/flutter test test/storage_box_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/hive.dart';

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('umacapture_storagebox_test'));
  // The fixture teardown from `support/hive.dart`, called directly, for the same reason as in
  // `storage_box_reset_test.dart`: this suite opens disk boxes itself, so a case that fails before
  // its own `Hive.close()` leaves eight of them open, and a bare `deleteSync` then raises
  // `PathAccessException … errno = 32` on top of the real failure and strands the directory.
  tearDown(() => closeHiveAndRemove(tempDir));

  test('box operations no-op after markHiveClosed instead of throwing', () async {
    await StorageBox.ensureOpened(directory: tempDir.path);

    // A long-lived instance holding the open box, like WindowStateBox does.
    final box = StorageBox(StorageBoxKey.settings);
    box.push<int>('k', 1);
    expect(box.pull<int>('k'), 1);

    StorageBox.markHiveClosed();
    await Hive.close();

    // The long-lived instance keeps a reference to the now-closed box: writes and
    // reads must be neutralized rather than throw.
    expect(() => box.push<int>('k', 2), returnsNormally);
    expect(() => box.delete('k'), returnsNormally);
    expect(box.pull<int>('k'), isNull);

    // A freshly-constructed instance must not throw either (Hive.box would
    // otherwise throw on a closed box).
    expect(() => StorageBox(StorageBoxKey.windowState), returnsNormally);
    expect(StorageBox(StorageBoxKey.windowState).pull<int>('missing'), isNull);
  });
}
