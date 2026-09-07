// The settings group's removal path (stage 6e): `deleteSettingsStores`.
//
//   .fvm/flutter_sdk/bin/flutter test test/settings_store_delete_test.dart
//
// Stage 0 already measured *which API is safe* (`settings_box_deletion_windows_test.dart`
// and `settings_box_deletion_web_test.dart`: raw file deletes fail on Windows and
// hang on web, `Hive.deleteBoxFromDisk` on a still-open store succeeds on both).
// What is pinned here is the layer above that: that the app's own function
// removes **every** store, reports what happened per store instead of throwing,
// and leaves the process in the state the forced restart exists for -- every
// store unregistered, whether or not its removal succeeded.
//
// ORDER MATTERS IN THIS FILE, and it is not incidental. `StorageBox.markHiveClosed()`
// flips a one-way process global, and `deleteSettingsStores` sets it by design.
// So the "nothing is initialised" case runs first, while the guard is still
// unset, and everything after it is written to hold with the guard already on —
// which is also why the second test observes the closed state through `Hive.box`
// directly rather than through `StorageBox`.
//
// WHAT THIS SUITE DOES NOT REACH. The refusal the failure-reporting path was
// written for — a store the
// platform will not remove — is not reproducible through this path on Windows:
// `Hive.deleteBoxFromDisk` closes the handles before deleting, which is exactly
// why stage 0 chose it, so the sharing violation cannot be provoked from here.
// The failure exercised below is a real one (the API refuses when Hive has no
// home directory) but it is not that one. Nothing here runs on web either: the
// IndexedDB backend needs a browser, and `settings_box_deletion_web_test.dart` is
// where that platform is measured.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;
import 'package:umacapture/src/core/storage/settings_boxes.dart';
import 'package:umacapture/src/core/storage/settings_store_delete.dart';
import 'package:umacapture/src/core/storage/storage_delete_report.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/hive.dart';

/// Every file the eight stores occupy on a native filesystem.
List<File> _storeFiles(Directory dir) => [
  for (final name in storageBoxNames)
    for (final suffix in ['.hive', '.lock']) File(p.join(dir.path, '$name$suffix')),
];

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('umacapture_settings_store_delete'));
  tearDown(() => closeHiveAndRemove(tempDir));

  test('a store that cannot be removed is reported, not thrown and not counted as deleted', () async {
    // Hive has no home directory here, so every removal is refused before it
    // touches anything. A synthetic cause, deliberately: what is being asserted
    // is that one store's refusal neither aborts the other seven nor arrives as
    // an exception the UI would have to interpret.
    final report = await deleteSettingsStores();

    expect(report.deletedCount, 0);
    // Named as stores rather than as paths, and each carrying the translation key
    // its row is labelled with: that key is what the failure panel renders, so a
    // refusal reported here cannot reach the screen as `column_spec`.
    expect(report.failed.map((failure) => failure.subject), [
      for (final key in StorageBoxKey.values)
        StorageDeleteStoreSubject(name: storageBoxNameOf(key), labelKey: storageBoxLabelKey(key)),
    ]);
    expect(report.isComplete, isFalse, reason: 'a report with eight refusals must not read as a success');
    for (final failure in report.failed) {
      // The failure panel shows this text to the user, and it is the only thing that
      // distinguishes one refusal from another.
      expect(failure.detail, isNotEmpty, reason: '${failure.subject} was refused with nothing to say about it');
    }
  });

  test('every store goes, and the process is left with no settings at all', () async {
    await StorageBox.ensureOpened(directory: tempDir.path);
    // Read through Hive and not through `StorageBox`: the test above has already
    // flipped the one-way guard, so a `StorageBox` read would answer null here
    // whether or not the store held anything.
    await Hive.box('settings').put('kept', 1);
    for (final file in _storeFiles(tempDir)) {
      expect(file.existsSync(), isTrue, reason: 'ensureOpened must have created ${p.basename(file.path)}');
    }

    final report = await deleteSettingsStores();

    // Counted by the machine on both sides: the report names exactly the stores
    // the enum declares, so a ninth key would have to be deleted for this to pass.
    expect(report.deleted.map((subject) => subject.toString()), storageBoxNames);
    expect(report.isComplete, isTrue);
    for (final file in _storeFiles(tempDir)) {
      expect(file.existsSync(), isFalse, reason: '${p.basename(file.path)} survived the delete');
    }

    // The state the forced restart exists for, and the reason it is not offered
    // as a choice: the stores are not merely empty, they are unregistered, so
    // the app's own accessor would throw inside an unrelated widget build if the
    // guard below were not set. Asserted directly, because "the guard is
    // necessary" was only ever a hypothesis until this stage confirmed it.
    expect(() => Hive.box('settings'), throwsA(isA<HiveError>()));
    // And the guard is what turns that into silence. A read answers null and a
    // write is dropped, instead of the exception above.
    expect(StorageBox(StorageBoxKey.settings).pull<int>('kept'), isNull);
    StorageBox(StorageBoxKey.settings).push<int>('kept', 2);
    expect(StorageBox(StorageBoxKey.settings).pull<int>('kept'), isNull);

    // Re-opening a store gives an empty one: the delete was real, not a view over
    // a file something quietly recreated.
    final reopened = await Hive.openBox('settings');
    expect(reopened.isEmpty, isTrue);
  });
}
