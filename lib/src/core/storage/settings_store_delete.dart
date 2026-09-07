/// Removing the settings stores, which are the one thing on this view that
/// is not a file (stage 6e).
///
/// **Why this is not `storage_delete.dart`'s job.** That library deletes paths
/// under an exclusion, and the settings group has no paths: on Windows the stores
/// are `.hive`/`.lock` pairs the view deliberately never shows, and on web they are
/// IndexedDB databases with no filesystem existence at all. What it shares
/// with the path deletes is everything after the removal — the confirmation, the
/// counts, the sentence — so it answers in the same [StorageDeleteReport] and is
/// finished by the same `runStorageDelete`.
///
/// **Hive's own API, never the files.** Stage 0 measured both platforms
/// (`settings_box_deletion_windows_test.dart`, `settings_box_deletion_web_test.dart`):
/// removing an open store's files directly fails with `ERROR_SHARING_VIOLATION`
/// on Windows and hangs on `blocked` forever on web, while
/// `Hive.deleteBoxFromDisk(name)` on that same still-open store succeeds on both,
/// because `HiveImpl.deleteBoxFromDisk` hands an open box to
/// `BoxBaseImpl.deleteFromDisk`, which closes it first. So there is no
/// "close Hive by hand, then delete" stage here, and no raw file operation
/// anywhere — the raw path is the one that is known to break.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';

import '/src/core/utils.dart';
import '/src/preference/storage_box.dart';

import 'settings_boxes.dart';
import 'storage_delete_report.dart';

/// How the settings stores are removed, so a test can watch the outcome travel
/// without a Hive of its own.
///
/// A provider for the reason `storageLockGateProvider` is one: the claim
/// "a failed delete is not announced as a success" is about what the
/// UI does with a report, and the only way to hand it a *failed* report is to
/// substitute the thing that produces it. Removing eight real stores proves the
/// removal works and says nothing about the announcement.
typedef SettingsStoreDeleter = Future<StorageDeleteReport> Function();

final settingsStoreDeleteProvider = Provider<SettingsStoreDeleter>((_) => deleteSettingsStores);

/// Removes every settings store, and neutralises what is left of Hive.
///
/// **The stores are counted by the machine.** The loop is over
/// [StorageBoxKey.values] itself — the same enumeration `ensureOpened` opens and
/// the view lists — so a ninth key is deleted here without an edit, and
/// [storageBoxLabelKey]'s exhaustive switch stops this file compiling until that
/// ninth store has a name a user can read. A literal list would be the one place
/// that silently kept deleting eight.
///
/// **Reports per store rather than throwing.** A store that could not be removed
/// is a state the user has to be told about — the app never claims a delete it
/// did not make — and one refusal must not
/// abandon the other seven — the alternative is a settings directory holding an
/// arbitrary subset with nothing on screen saying which.
///
/// **The guard is set first, and not conditioned on the outcome.**
/// [StorageBox.markHiveClosed] is what stops the app's many non-interactive
/// writers from touching a store that is gone. It has to be set *before* the
/// first removal, because `BoxBaseImpl.deleteFromDisk` unregisters the box before
/// it touches the disk (hive_ce `box/box_base_impl.dart`) — so from the moment
/// store one goes, `Hive.box('settings')` throws `HiveError('Box not found')`,
/// and a writer firing between store one and store eight would take that
/// exception into an unrelated widget build. That same ordering is why the guard
/// is not conditional on success: a *failed* removal has already unregistered the
/// box, so there is no outcome of this function that leaves the stores usable.
/// It is also why a restart is demanded whether or not the delete worked — after
/// this call the session has no settings either way, and the restart is the only
/// thing that gives it any.
Future<StorageDeleteReport> deleteSettingsStores() async {
  StorageBox.markHiveClosed();
  final deleted = <StorageDeleteSubject>[];
  final failed = <StorageDeleteFailure>[];
  for (final key in StorageBoxKey.values) {
    final name = storageBoxNameOf(key);
    // A store, not a path — the distinction the report carries so that the panel
    // the delete report opens can name this the way the tree names it. It has no path on
    // either platform, and inventing one (`<settings>/x.hive`) would put on
    // screen the implementation detail this view deliberately keeps off it, and would be a
    // fiction on web besides.
    final subject = StorageDeleteStoreSubject(name: name, labelKey: storageBoxLabelKey(key));
    try {
      await Hive.deleteBoxFromDisk(name);
      deleted.add(subject);
    } catch (error, stackTrace) {
      logger.w('A settings store could not be removed: $name', error, stackTrace);
      failed.add(
        StorageDeleteFailure(
          subject: subject,
          // Refused by the platform, which is the only kind of failure reachable
          // here: this delete takes no lock, so neither lock reason can arise.
          reason: StorageDeleteFailureReason.refused,
          detail: error.toString(),
        ),
      );
    }
  }
  return StorageDeleteReport(deleted: deleted, failed: failed);
}
