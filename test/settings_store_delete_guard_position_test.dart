// WHERE `markHiveClosed()` sits inside `deleteSettingsStores`.
//
//   .fvm/flutter_sdk/bin/flutter test test/settings_store_delete_guard_position_test.dart
//
// `settings_store_delete_test.dart` pins what the guard *does* — after the eight
// removals, a `StorageBox` read answers null instead of throwing. It cannot pin
// where the guard is set, and an independent review measured that: moving the
// call below the loop left that suite, and every other storage suite, green.
//
// The position is not a detail. `BoxBaseImpl.deleteFromDisk` calls
// `hive.unregisterBox(name)` *before* `backend.deleteFromDisk()` (hive_ce
// `box/box_base_impl.dart`), so from the moment the first store goes,
// `Hive.box('window_state')` throws `HiveError: Box not found` — and the app has
// many non-interactive writers (window move/resize, preference notifiers, sentry
// counters, version checks) that can fire during the eight awaits this function
// takes. With the guard first they are silently dropped; with the guard last, one
// of them takes a `HiveError` up through an unrelated widget build, and the user
// sees "the app crashed when I deleted my settings".
//
// SO THIS IS A BEHAVIOURAL TEST, NOT A STRUCTURAL ONE. It does not read the
// source or count lines; it fires a real `StorageBox` writer repeatedly while a
// real `deleteSettingsStores` runs against real disk-backed stores, and asserts
// that none of those writes threw. A test that asserted the *order of statements*
// would stop meaning anything the moment the function was rewritten, and would
// pass against any rewrite that kept the shape while losing the property.
//
// THIS FILE HOLDS EXACTLY ONE TEST, AND IT HAS TO. `markHiveClosed` flips a
// one-way process global with no reset, so the second test in any file has the
// guard already set and could not tell the two positions apart -- which is
// precisely why the existing suite could not carry this assertion.
//
// WHAT IT DOES NOT REACH. Only the Windows/VM backend: web's IndexedDB removal is
// a different backend, and `unregisterBox` is in the shared `BoxBaseImpl` above
// it, so the ordering is the same by construction but is not measured here. And
// the writer is `StorageBox`, the app's own accessor -- a writer that reached
// `Hive.box` directly would still throw, and nothing here or in the app protects
// one that did.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/core/storage/settings_store_delete.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/hive.dart';

/// One firing of a non-interactive writer, and what the app's accessor did.
typedef _Firing = ({bool anyStoreGone, Object? error});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('umacapture_guard_position'));
  tearDown(() => closeHiveAndRemove(tempDir));

  test('a background writer that fires mid-delete is silenced, not thrown at', () async {
    await StorageBox.ensureOpened(directory: tempDir.path);

    // Stands in for the writers that fire on their own schedule: a window move,
    // a preference notifier, a version check. `windowState` because that is the
    // one that fires most often and is the second store removed, so it is
    // unregistered early in the loop and stays that way for the rest of it.
    final firings = <_Firing>[];
    void fire() {
      final gone = storageBoxNames.any((name) => !Hive.isBoxOpen(name));
      try {
        StorageBox(StorageBoxKey.windowState).push<int>('left', firings.length);
        firings.add((anyStoreGone: gone, error: null));
      } catch (error) {
        firings.add((anyStoreGone: gone, error: error));
      }
    }

    // Every turn of the event loop for as long as the delete runs. The delete
    // awaits real file IO eight times, so this samples the window between the
    // first removal and the last one rather than hoping to land in it.
    final timer = Timer.periodic(Duration.zero, (_) => fire());
    final report = await deleteSettingsStores();
    timer.cancel();

    // The delete itself did what it was asked, so a failure below is about the
    // guard and not about a removal that never happened.
    expect(report.deleted.map((subject) => subject.toString()), storageBoxNames);

    // The precondition, asserted separately so that "the writer never landed
    // mid-flight" reads as its own failure rather than as a passing gate.
    expect(
      firings.where((firing) => firing.anyStoreGone),
      isNotEmpty,
      reason: 'no writer fired after a store had been unregistered, so nothing was measured',
    );

    // The claim. With the guard set before the loop every firing is a no-op;
    // with it set after, the ones that landed after the first removal throw
    // `HiveError: Box not found` out of `StorageBox`'s constructor.
    expect(
      firings.where((firing) => firing.error != null).map((firing) => firing.error.toString()),
      isEmpty,
      reason: 'a non-interactive writer threw while the stores were being removed',
    );
  });
}
