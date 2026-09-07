/// Business logic for relocating the user-configurable data root.
///
/// This layer is deliberately free of any Flutter widget concerns so the
/// data-loss-critical parts (the per-directory atomic swap and its rollback) can
/// be unit-tested against real temp directories. The dialog in
/// `gui/storage_settings.dart` owns only the UI state and delegates here.
library;

import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:path/path.dart' as p;

import '/src/core/app_restart.dart';
import '/src/core/bootstrap.dart';
import '/src/core/fs/record_mutation_lock.dart';
import '/src/core/fs/record_recovery_gate.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/utils.dart';
import '/src/preference/storage_box.dart';

/// How a chosen target relates to the current data, deciding the dialog content.
enum MigrationKind { sameLocation, invalid, empty, hasData }

/// How a [DataRootMigrationController.migrate] attempt ended.
///
/// Success and failure are not the distinction the UI needs. Once Hive has been
/// closed the session can no longer read its settings, so quitting or
/// relaunching is the only safe exit — and that is true of a *success* as much
/// as of a failure halfway through the copy. A refusal that happens before the
/// close is the opposite case: nothing moved, nothing closed, the app is intact,
/// and retrying in a moment is the whole remedy. [sessionUsable] is that fact,
/// carried out of here rather than re-derived from a success flag.
enum MigrationOutcome {
  /// Every directory swapped and the override was persisted. Hive is closed.
  succeeded,

  /// Refused before anything irreversible: the root record scope was held by
  /// another party (a bulk scan, an archive repair), or there is no relocatable
  /// data root on this platform at all. Nothing was moved, Hive is still open.
  refusedSessionIntact,

  /// Failed after Hive was closed. The data is rolled back to the old location,
  /// but this session cannot read settings again.
  failedAfterClose;

  bool get isSuccess => this == MigrationOutcome.succeeded;

  /// Whether the running session survived the attempt, i.e. whether closing the
  /// dialog and carrying on is safe.
  ///
  /// Written as an exhaustive switch on purpose: a future outcome has to be
  /// classified here, and will not default into "safe to close".
  bool get sessionUsable => switch (this) {
    MigrationOutcome.succeeded => false,
    MigrationOutcome.refusedSessionIntact => true,
    MigrationOutcome.failedAfterClose => false,
  };
}

/// What a relocation driven by [controller] announces to the long-read registry.
///
/// **Its roots are read off [DataRootMigrationController.movedRoots], not
/// written out here.** The claim has to hold what the copy moves, and the only
/// way to keep those two answers equal when a fourth tree is added to the
/// migration is to derive them from one enumeration; a list repeated at the
/// claim would be the same defect `record_scan_claim.dart` documents.
///
/// **Three roots is not a list that could have been one.** `storage/` is not an
/// ancestor of the other two, and the storage view offers a delete over each of
/// them separately (`StorageGroupId.modules`, `StorageGroupId.settings`), so a
/// claim over `storage/` alone would leave two live delete buttons over
/// directories being renamed away. The comment this replaced asserted the
/// opposite — that moving `storage/` covers "every path any delete surface can
/// name" — and the group table says otherwise.
LongReadDeclaration dataRootRelocationLongReadDeclaration(RefBase ref, DataRootMigrationController controller) {
  return LongReadDeclaration.claim(
    registry: ref.read(longReadRegistryProvider.notifier),
    kind: LongReadKind.relocate,
    paths: controller.movedRoots,
  );
}

/// Drives a data-root relocation: classification, the file migration, and the
/// process control (quit / relaunch) that must follow it on Windows.
///
/// Constructed with the current [source] layout. Pure classification needs
/// nothing more; [migrate] receives the runtime capture state so this class
/// stays independent of Riverpod and remains testable.
class DataRootMigrationController {
  /// The current (pre-migration) path layout.
  final PathInfo source;

  const DataRootMigrationController({required this.source});

  /// The directories copied during a migration, paired source → destination.
  ///
  /// The transient `temp` directory is intentionally excluded; only the durable
  /// `storage` / `modules` / `settings` trees are moved.
  List<({DirectoryPath src, DirectoryPath dst})> pairs(PathInfo target) => [
    for (final tree in _movedTrees) (src: tree(source), dst: tree(target)),
  ];

  /// The trees a relocation moves, as accessors rather than as directories, so
  /// [pairs] and [movedRoots] read the *same* enumeration.
  ///
  /// Written this way because there are now two derivations of "what does a
  /// relocation move": the copy itself, and the long-read claim that has to hold
  /// every one of them for the copy's length. A second literal list would be
  /// free to disagree with the first, and the disagreement would be a delete
  /// button offered over a directory being renamed away.
  static final List<DirectoryPath Function(PathInfo)> _movedTrees = [
    (info) => info.storageDir,
    (info) => info.modulesDir,
    (info) => info.settingsDir,
  ];

  /// The current locations of the trees [migrate] will move.
  ///
  /// Three roots and not one: with no data-root override in force these do not
  /// share a parent at all (`storage/` and the settings box sit under the
  /// documents directory, `modules/` under the support directory), so there is
  /// no single ancestor a claim could name instead.
  List<DirectoryPath> get movedRoots => [for (final tree in _movedTrees) tree(source)];

  /// Classifies a chosen [root] (`null` = reset to native defaults).
  MigrationKind classify(DirectoryPath? root) {
    // Classify on the resolved source/destination directories, not on the
    // `dataRoot` token: a chosen root can make some directories land back on the
    // current ones (e.g. picking the app's own documents folder while no
    // override is set), which the token comparison would miss and the overwrite
    // path would then destroy by deleting the source before copying.
    final target = source.withDataRoot(root);
    final ps = pairs(target);
    final collisions = ps.where((e) => p.equals(e.src.path, e.dst.path)).length;
    if (collisions == ps.length) {
      return MigrationKind.sameLocation;
    }
    if (collisions > 0 || (root != null && !_isValidTarget(root))) {
      return MigrationKind.invalid;
    }
    final hasData = ps.any((e) => e.dst.existsSync() && e.dst.listSync().isNotEmpty);
    return hasData ? MigrationKind.hasData : MigrationKind.empty;
  }

  /// Rejects a target that is the same as, or nested inside, the current data or
  /// the executable directory — copying a tree into its own subdirectory would
  /// corrupt it.
  bool _isValidTarget(DirectoryPath root) {
    final path = root.path;
    if (!p.isAbsolute(path)) return false;
    final forbidden = [source.storageDir, source.modulesDir, source.settingsDir, source.executableDir];
    return !forbidden.any((dir) => p.equals(path, dir.path) || p.isWithin(dir.path, path));
  }

  /// Migrates the data to [targetRoot] (`null` = reset to native defaults).
  ///
  /// Stops capture and closes Hive to release native file handles, swaps each
  /// directory into place (see [swapDirectories]), then persists the override so
  /// the next launch resolves paths under the new root. Leaves the override
  /// unchanged if any step fails; the source data is never touched, so a failed
  /// migration is fully recoverable by restarting.
  ///
  /// The [MigrationOutcome] distinguishes a failure that closed Hive from one
  /// refused before it, because only the caller can act on that and only it
  /// knows there is a user waiting on a dialog with no way out.
  /// `blockedBy` is which registered long reader, if any, is holding one of the
  /// trees this relocation would rename away — a value read at the call site, for
  /// the same reason `isCapturing` is one: this class is deliberately free of
  /// Riverpod (see the class doc) and a registry is only reachable through a ref.
  ///
  /// **`isCapturing` is not the other half of that question, and a video import
  /// is not missing from it.** It is a live *capture* session and nothing else —
  /// the flag exists so [stopCapture] can be called, not so a relocation can be
  /// refused — and `capturingStateProvider` is false throughout a video import.
  /// What refuses an import is `blockedBy`: the import announces its session as
  /// [LongReadKind.videoImport] over the record store, and `movedRoots` contains
  /// `storage/`, which contains it. So the registry is where that collision is
  /// written down, exactly as it is for a zip, an archive and a scan, and there
  /// is nothing for this parameter to say about it.
  ///
  /// **A live capture now announces itself too, and the caller subtracts it from
  /// `blockedBy` rather than this method ignoring it.** Since
  /// [LongReadKind.liveCapture] exists, the registry carries the same fact
  /// `isCapturing` does — but the two seams want opposite things done with it:
  /// every other surface withholds a control for a holder, while this one has a
  /// remedy of its own and takes it. Handing that decision to `blockedBy`'s
  /// producer keeps this method's rule the simple one it was ("a holder is a
  /// refusal") and leaves the exception written at the site that owns the
  /// remedy, where `stopCapture` is passed in the same call.
  ///
  /// **Why that refusal is here and not on the dialog's confirm button.** The root
  /// record scope below already refuses a relocation that collides with a *scope
  /// holder* — a bulk scan, an archive repair — and that refusal is inside this
  /// method, where every caller reaches it. But the scope is not what a long
  /// reader takes: `StorageZipProgress.begin` and
  /// `CharaDetailRecordRegenerationController._claimBatch` both claim the registry
  /// directly, with no gate and therefore no lock, so a relocation begun while a
  /// zip is bundling `storage/` acquires the scope with nothing in its way and
  /// renames the directory out from under the reader. The registry is the only
  /// place that collision is written down, so the question belongs beside the
  /// acquisition that answers the other half of it.
  ///
  /// **And it answers the wait, not only the collision.** For a holder that *does*
  /// take the scope, the acquisition below waits out its whole timeout before
  /// reporting [MigrationOutcome.refusedSessionIntact] — a progress dialog saying
  /// 「データを移行しています」 for as long as that takes, while nothing is being
  /// moved. Asked first, the same outcome is reached at once.
  ///
  /// **A refusal and not a withheld button, which is the one place this diverges
  /// from the record surfaces.** Those grey their confirm and put the reason in
  /// the dialog body. Here the dialog already ships a sentence for exactly this
  /// outcome (`pages.storage.dialog.refused`, whose first clause is 「他の処理が
  /// レコードを使用中のため、移行を開始できませんでした」), reached through
  /// [MigrationOutcome.sessionUsable] with the back/close buttons that go with it;
  /// withholding the button instead would need a second sentence saying the same
  /// thing, and a button greyed without one is the defect this whole seam exists
  /// to remove.
  Future<MigrationOutcome> migrate(
    DirectoryPath? targetRoot, {
    required bool isCapturing,
    required LongReadDeclaration declaration,
    required LongReadKind? blockedBy,
    Future<void> Function()? stopCapture,
    RecordRecoveryGate? recoveryGate,
  }) async {
    // There is no relocatable data root on web (OPFS is the storage root), and
    // the migration relies on desktop-only process/window control. The UI entry
    // (DataRootTile) is hidden on web; this guard makes the controller inert
    // even if it is ever reached.
    if (kIsWeb) return MigrationOutcome.refusedSessionIntact;
    // Before anything is acquired, closed or copied: see the doc above for why a
    // registered long reader is a refusal the root record scope cannot answer.
    if (blockedBy != null) {
      logger.i("Data root migration declined: ${blockedBy.name} is holding a tree it would move.");
      return MigrationOutcome.refusedSessionIntact;
    }
    // Moving `storage/` moves every record directory at once, so this is the
    // widest record mutation the app performs and it takes the same exclusive
    // root scope the bulk scan and the archive geometry repair take — acquired
    // here, on the UI isolate, and held across the whole relocation. Without it
    // a store scan still running (its worker isolates decode, and quarantine, out
    // of `storage/chara_detail/...`) would be reading directories this method is
    // renaming away, which is reachable because the settings page is live while
    // the startup scans are.
    //
    // Acquired *before* Hive is closed, so a refusal leaves the session intact
    // and the old location authoritative — the same contract every other early
    // failure below keeps.
    final gate = recoveryGate ?? platformRecordRecoveryGate;
    try {
      final swapped = await gate.runForRoot(
        source.storageDir,
        (_) => _migrateLocked(targetRoot, isCapturing, stopCapture),
        // **The widest long reader there is, and it now announces itself.**
        // Passed in rather than built here because this class is deliberately
        // free of Riverpod (see the class doc) and a registry is only reachable
        // through a ref; what it has to be is
        // [dataRootRelocationLongReadDeclaration], which reads its paths off
        // [movedRoots] so the claim cannot name a different set from the copy.
        //
        // **A refusal is inside the claim too, and that is the point of putting
        // it here rather than around `_migrateLocked`.** The claim opens before
        // the acquisition below and closes after it, so the window covers the
        // wait for the root scope as well as the copy — which is the half a
        // caller cannot see, because a relocation queued behind a startup scan
        // is holding nothing yet and is still an operation the user is waiting
        // on. The release is `LongReadRegistry.hold`'s `finally`, so both the
        // refusal path and the success path give it back with nothing written
        // here.
        declaration: declaration,
        // Desktop-only (the `kIsWeb` guard above returns before this), so no
        // recovery hook is installed for the reason to select between. It is
        // [RootMaintenanceReason.readyToUse] on its merits too: the relocation
        // moves `storage/` whole, journals included, and removes nothing.
        reason: RootMaintenanceReason.readyToUse,
        beforeMaintenance: const BeforeRootMaintenance.none(
          reason: 'the relocation moves the store whole and removes nothing, so no set of entries has to be fixed',
        ),
      );
      // Every failure _migrateLocked can report happens after StorageBox was
      // neutralized and Hive.close() was attempted, so there is no third case
      // to distinguish here.
      return swapped ? MigrationOutcome.succeeded : MigrationOutcome.failedAfterClose;
    } catch (error, stackTrace) {
      if (error is! RecordMutationLockBusy && error is! RecordMutationLockUnavailable) {
        rethrow;
      }
      // Nothing was moved, nothing was closed, and the override is untouched, so
      // retrying once the store is idle is the whole remedy — which the caller
      // can only offer if it can tell this apart from a failure mid-copy.
      logger.e("Data root migration could not take the root record lock; nothing was moved.", error, stackTrace);
      return MigrationOutcome.refusedSessionIntact;
    }
  }

  /// The relocation itself, running under the exclusive root record scope.
  Future<bool> _migrateLocked(DirectoryPath? targetRoot, bool isCapturing, Future<void> Function()? stopCapture) async {
    final target = source.withDataRoot(targetRoot);
    // Release native file handles so storage/modules can be copied on Windows.
    try {
      if (isCapturing) {
        await stopCapture?.call();
      }
    } catch (error, stackTrace) {
      logger.w("Failed to stop capture before migration.", error, stackTrace);
    }
    // Flush and close Hive so the settings boxes are consistent and unlocked.
    // After this the app cannot read settings again, so migration is the final
    // action before restart. Neutralize StorageBox first so any non-interactive
    // writer that fires before the restart (window move/resize, preference
    // notifiers, sentry counters, version checks, addon history) no-ops instead
    // of throwing on a closed box.
    StorageBox.markHiveClosed();
    try {
      await Hive.close();
    } catch (error, stackTrace) {
      logger.e("Failed to close Hive before migration.", error, stackTrace);
      return false;
    }
    if (!await swapDirectories(pairs(target))) {
      return false;
    }
    // Persist the override only after every swap succeeded. On failure it is left
    // untouched so the old location stays authoritative for the next launch.
    try {
      await writeDataRootOverride(targetRoot?.path);
    } catch (error, stackTrace) {
      logger.e("Failed to persist the data root override after migration.", error, stackTrace);
      return false;
    }
    return true;
  }

  /// Clears the override without touching any data.
  ///
  /// For the degraded case where the configured root is unreachable (e.g. an
  /// unplugged drive): the app is already running on the native defaults, so a
  /// normal [migrate] would copy that empty layout over the chosen root and
  /// strand the real data. This instead just deletes the bootstrap override so
  /// the next launch resolves to the native defaults cleanly. No `Hive.close()`
  /// and no copy, so the running session is unaffected. Returns `false` (leaving
  /// the override intact) if the bootstrap file cannot be removed.
  Future<bool> clearOverride() async {
    try {
      await writeDataRootOverride(null);
      return true;
    } catch (error, stackTrace) {
      logger.e("Failed to clear the data root override.", error, stackTrace);
      return false;
    }
  }

  /// Swaps each `src` directory into its `dst`, preserving any pre-existing
  /// destination data until the whole set succeeds.
  ///
  /// Per pair: any pre-existing `dst` is renamed aside to a sibling backup, the
  /// source is copied into a fresh `dst`, and only on full success are the
  /// backups deleted. On any failure the in-flight pair and every completed swap
  /// are rolled back, so the destination's old data is restored (the source is
  /// never touched either way). If a locked partial copy cannot be removed during
  /// rollback, the original is left at the `.uma-old` sibling and the failure is
  /// logged rather than silently lost. Returns `true` only if all pairs swapped.
  static Future<bool> swapDirectories(List<({DirectoryPath src, DirectoryPath dst})> pairs) async {
    final done = <({DirectoryPath dst, DirectoryPath? backup})>[];
    for (final pair in pairs) {
      // Safety net mirroring classify(): never operate when src and dst resolve
      // to the same directory (would delete the data we are migrating).
      if (p.equals(pair.src.path, pair.dst.path)) continue;
      if (!pair.src.existsSync()) continue;
      DirectoryPath? backup;
      // True once dst has been moved aside or copyTreeInto may have created a
      // partial dst — i.e. once cleaning up dst is safe. Before this, dst is the
      // untouched original and must not be removed.
      var copying = false;
      try {
        if (pair.dst.existsSync()) {
          backup = pair.dst.parent / "${pair.dst.name}.uma-old";
          backup.deleteSync(recursive: true, emptyOk: true);
          if (pair.dst.moveSyncSafe(backup) == null) {
            _restore(done);
            return false;
          }
        }
        copying = true;
        if (!await pair.src.copyTreeInto(pair.dst)) {
          _rollbackInFlight(pair.dst, backup);
          _restore(done);
          return false;
        }
        done.add((dst: pair.dst, backup: backup));
      } catch (error, stackTrace) {
        logger.e("Migration copy failed.", error, stackTrace);
        if (copying) _rollbackInFlight(pair.dst, backup);
        _restore(done);
        return false;
      }
    }
    for (final entry in done) {
      entry.backup?.deleteSync(recursive: true, emptyOk: true);
    }
    return true;
  }

  /// Reverses completed directory swaps, newest first.
  static void _restore(List<({DirectoryPath dst, DirectoryPath? backup})> done) {
    for (final entry in done.reversed) {
      _rollbackInFlight(entry.dst, entry.backup);
    }
  }

  /// Removes a copied destination and restores its backup (if any) into place.
  ///
  /// The deletion and the restore are attempted independently so a failure to
  /// remove a locked partial copy does not skip the backup restore. If the backup
  /// cannot be moved back it is left at its `.uma-old` location and logged, never
  /// silently dropped.
  static void _rollbackInFlight(DirectoryPath dst, DirectoryPath? backup) {
    try {
      dst.deleteSync(recursive: true, emptyOk: true);
    } catch (error, stackTrace) {
      logger.w("Failed to remove a partial migration copy during rollback.", error, stackTrace);
    }
    if (backup == null) return;
    if (backup.moveSyncSafe(dst) == null) {
      logger.e("Could not restore original data to ${dst.path}; it remains at ${backup.path}.");
    }
  }

  /// Quits the app, falling back to a hard exit if the window cannot be closed.
  ///
  /// Delegated since the storage view's settings delete gained the same need: it ends a
  /// session that can no longer read a setting, exactly as a completed migration
  /// does, and it is not a migration. The per-platform bodies, and the Windows
  /// relaunch constraints, are in `app_restart.dart`.
  Future<void> quit() => quitApp();

  /// Relaunches the app, then quits. See [quit] for why this is delegated.
  ///
  /// False when the relaunch could not be scheduled; this dialog offers quit
  /// beside restart on the branch that reaches here with Hive closed, so the
  /// user still has a way out that does not depend on the relaunch working.
  Future<bool> restart() => restartApp();
}
