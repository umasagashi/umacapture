/// Business logic for relocating the user-configurable data root.
///
/// This layer is deliberately free of any Flutter widget concerns so the
/// data-loss-critical parts (the per-directory atomic swap and its rollback) can
/// be unit-tested against real temp directories. The dialog in
/// `gui/storage_settings.dart` owns only the UI state and delegates here.
library;

import 'dart:io';

import 'package:hive_ce_flutter/adapters.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '/src/core/bootstrap.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';

/// How a chosen target relates to the current data, deciding the dialog content.
enum MigrationKind { sameLocation, invalid, empty, hasData }

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
    (src: source.storageDir, dst: target.storageDir),
    (src: source.modulesDir, dst: target.modulesDir),
    (src: source.settingsDir, dst: target.settingsDir),
  ];

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
  /// the next launch resolves paths under the new root. Returns `false` without
  /// changing the override if any step fails; the source data is never touched,
  /// so a failed migration is fully recoverable by restarting.
  Future<bool> migrate(
    DirectoryPath? targetRoot, {
    required bool isCapturing,
    Future<void> Function()? stopCapture,
  }) async {
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
    // action before restart.
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
  Future<void> quit() async {
    try {
      await windowManager.destroy();
    } catch (_) {
      exit(0);
    }
  }

  /// Relaunches the app, then quits.
  ///
  /// Two Windows constraints shape this:
  /// - The native runner enforces a single instance via a named mutex
  ///   (`windows/runner/main.cpp`), so a new instance spawned while we are
  ///   still alive sees the mutex, foregrounds us, and exits. The relaunch must
  ///   therefore wait until this process has fully exited (releasing the mutex).
  /// - A child started with `Process.start(detached)` does NOT survive this
  ///   process exiting (verified empirically). A process created via PowerShell
  ///   `Start-Process` is reparented to the session and does survive.
  ///
  /// So we write a tiny relay script and launch it through `Start-Process`
  /// (awaited, so it exists before we quit). The relay waits for our PID to
  /// vanish, then starts a fresh instance — which re-reads the bootstrap file
  /// and opens Hive at the migrated location. If scheduling fails the dialog
  /// stays put so the user can still quit and relaunch manually.
  Future<void> restart() async {
    final exePath = Platform.resolvedExecutable;
    final exeDir = FilePath.resolvedExecutable.parent.path;
    final relayScript =
        'param([int]\$ParentPid)\n'
        'Wait-Process -Id \$ParentPid -ErrorAction SilentlyContinue\n'
        'Start-Process -FilePath ${_psQuote(exePath)} -WorkingDirectory ${_psQuote(exeDir)}\n'
        'Remove-Item -LiteralPath \$PSCommandPath -ErrorAction SilentlyContinue\n';
    try {
      final relayFile = File("${Directory.systemTemp.path}\\umacapture_restart_$pid.ps1");
      relayFile.writeAsStringSync(relayScript);
      final relayPath = relayFile.path.replaceAll('\\', '/');
      await Process.run("powershell", [
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        "Start-Process powershell -WindowStyle Hidden -ArgumentList "
            "'-NoProfile','-ExecutionPolicy','Bypass','-File',${_psQuote(relayPath)},'$pid'",
      ]);
    } catch (error, stackTrace) {
      logger.e("Failed to schedule a restart.", error, stackTrace);
      return;
    }
    await quit();
  }

  /// Wraps [value] as a PowerShell single-quoted literal, escaping embedded
  /// single quotes by doubling them (PowerShell's literal-string escape). Without
  /// this a path containing an apostrophe (e.g. `C:\Users\O'Brien\...`) would
  /// terminate the string early and break the relaunch.
  static String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";
}
