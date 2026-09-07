/// The native leg of the storage view's zip export (stage 5c).
///
/// **Streamed, on an isolate, with no size limit.** `ZipFileEncoder` reads
/// each file through an `InputFileStream` and writes through an
/// `OutputFileStream`, so the archive is never held in memory and there is no
/// size at which the operation stops working; the wait it costs is answered with
/// progress rather than with a refusal. That is the same arrangement the record
/// exporter already uses (`exporter.dart`'s `ZipExporter._run`), and this file
/// differs from it in one respect: the record exporter needs no progress, so it
/// can use `compute`, while this one hands a `SendPort` into `Isolate.run` so the
/// worker can report as it goes.
///
/// The destination comes from `storageSaveFileProvider` — the seam stage 5b's
/// download already goes through — asked with an empty payload, because the zip
/// is written by the encoder and not by the picker. `exporter.dart` asks for its
/// desktop destination the same way (`bytes: Uint8List(0)`).
library;

import 'dart:io' show Directory, File;
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';

import '/src/core/path_entity.dart';
import '/src/core/utils.dart';

import 'file_download.dart';
import 'storage_exclusion.dart';
import 'zip_export.dart';
import 'zip_own_output.dart';

/// Native builds offer the action; see [storageZipAvailableProvider].
const platformStorageZipAvailable = true;

/// No limit on this platform: nothing here has to be refused, so nothing is.
Future<String?> platformStorageZipPreflight(RefBase ref, DirectoryPath directory) async => null;

/// Asks where the archive should go, then builds it on a worker isolate.
Future<StorageZipDelivery> platformStorageZipRunner(
  RefBase ref,
  DirectoryPath directory,
  StorageZipProgressSink onProgress,
  StorageExclusionGuard guard,
) async {
  // The registry claim is given back *here*, for the same reason and over the
  // same stretch the group's exclusion is not taken until below: a
  // `GetSaveFileNameW` stands until the user answers, which can be indefinitely,
  // and none of that time is spent reading the folder. Holding it there is no
  // longer only a greyed button — `runModuleInstall` waits for the holders of
  // `modules/`, so a dialog left open would park the automatic module update
  // behind it. [StorageZipProgress.releaseForDialog] carries what is given up.
  final progress = ref.read(storageZipProgressProvider.notifier);
  progress.releaseForDialog();
  final destination = await ref.read(storageSaveFileProvider)(
    dialogTitle: 'pages.storage.actions.zip_directory'.tr(),
    fileName: '${directory.name}.zip',
    bytes: Uint8List(0),
  );
  if (destination == null) {
    // On this platform the dialog answers with the chosen path, so a `null` is a
    // dismissal and nothing was written. (The browser's `null` means something
    // else entirely — see `saveDialogReportsPathProvider` — which is why the web
    // runner is a separate function rather than this one with a flag.)
    return StorageZipDelivery.cancelled;
  }
  // Taken back before anything is read, and refused if somebody claimed the
  // folder while the dialog stood open: the frame that offered this zip is old
  // by now and no rebuild happened in between, which is the same window
  // `ModuleManualUpdateDialog._install` re-checks for. Nothing has been written
  // — the encoder has not run and the staging file does not exist yet — so this
  // is a refusal and not a failure. Asked without naming the folder again: the
  // run knows which one it released, and that is the claim being taken back.
  if (!progress.reclaimAfterDialog()) {
    return StorageZipDelivery.refused;
  }
  // The group's exclusion starts *here*, after the dialog and not before it. A
  // `GetSaveFileNameW` sits open until the user answers, which can be minutes;
  // taking the record lock around it would stall the capture merge for exactly
  // that long, and none of that time is spent reading the folder. What has to be
  // excluded is the walk the encoder does, and this is where that begins.
  await guard(() => _buildOnIsolate(directory.path, destination, onProgress));
  // The encoder reports a position within its own listing, and its last entry
  // may be a directory rather than a file, so the last fraction it sends can be
  // short of one. The bar reaches the end when the work does.
  onProgress(1);
  return StorageZipDelivery.written;
}

Future<void> _buildOnIsolate(String sourcePath, String destinationPath, StorageZipProgressSink onProgress) async {
  final port = ReceivePort();
  final sink = port.sendPort;
  final subscription = port.listen((message) {
    if (message is double) {
      onProgress(message);
    }
  });
  try {
    await _spawnBuild(sourcePath, destinationPath, sink);
  } finally {
    await subscription.cancel();
    port.close();
  }
}

/// Spawns the worker, **from a scope that holds nothing else**.
///
/// A closure is serialised together with the context it was created in, and
/// sibling closures in one function body share that context. Written inline in
/// [_buildOnIsolate], the spawn closure would therefore carry the progress sink
/// as well — and that sink reaches a `Notifier`, a container and their pending
/// futures, none of which can cross an isolate boundary. The failure is an
/// `ArgumentError` from `Isolate.spawn` naming `_Future` as unsendable, which
/// says nothing about the sink it actually came from. Giving the spawn a scope of
/// exactly three sendable values is what keeps it sendable.
///
/// `Isolate.run` and not `compute`: the worker reports while it runs, and
/// `compute` has one channel, used by its return value. The port travels with
/// this closure, which is what makes it reach the worker.
Future<void> _spawnBuild(String sourcePath, String destinationPath, SendPort progress) {
  return Isolate.run(() => _buildZip(sourcePath, destinationPath, progress));
}

/// Runs on the worker isolate.
///
/// `addDirectory` streams each file's bytes asynchronously, and `close` flushes
/// the output and writes the central directory, so both are awaited: the same
/// reason `exporter.dart` gives — otherwise the archive comes out truncated or
/// empty.
///
/// `includeDirName` is left at its default, so the archive holds
/// `<folder>/<relative path>` and expands into a copy of the folder rather than
/// scattering its contents into whatever directory it was opened in.
///
/// **Written beside the destination and moved onto it, never into it.**
/// `ZipFileEncoder.create` opens its `OutputFileStream` with `FileMode.write`,
/// so the path it is given is created or truncated *before* the walk begins and
/// only gains a central directory when `close` runs. Given the destination
/// directly, a file that disappears or is locked part way through the walk would
/// therefore leave the user holding an archive no tool can open — and, if the
/// save dialog's destination was an existing file the user chose to replace,
/// would already have destroyed it. Building into a sibling and renaming means
/// the destination is written exactly once, when there is a whole archive to put
/// there. The browser leg needs none of this: it has every byte in memory before
/// it calls the save seam at all, so a failure there reaches no file.
///
/// **What is removed on failure is this function's own staging file, by the path
/// it just created.** The destination is never deleted: a partial archive is
/// ours, the file the user pointed at is not.
///
/// **And neither the staging file nor the destination is ever an entry.** The
/// user can point the dialog at the folder being bundled, and the walk starts
/// after the staging file exists; `zipOwnOutputFilter` says why that has to be a
/// filter rather than a staging file elsewhere.
Future<void> _buildZip(String sourcePath, String destinationPath, SendPort progress) async {
  // A sibling, so the rename below stays on one volume and is a move rather
  // than a copy; suffixed with the microsecond clock so a concurrent export, or
  // a file the user happens to keep beside the destination, is not what gets
  // truncated and removed.
  final stagingPath = '$destinationPath.${DateTime.now().microsecondsSinceEpoch}.part';
  final encoder = ZipFileEncoder();
  encoder.create(stagingPath);
  try {
    await encoder.addDirectory(
      Directory(sourcePath),
      followLinks: false,
      onProgress: (fraction) => progress.send(fraction),
      filter: zipOwnOutputFilter(stagingPath: stagingPath, destinationPath: destinationPath),
    );
    await encoder.close();
    // Replaces the destination if it exists, which is what the user answered the
    // overwrite prompt for; `rename` is the operating system's replace on both
    // Windows and POSIX, so there is no moment where neither file is there. It
    // is inside the same `try` as the build: a move that cannot happen — the
    // destination is a directory, the volume is full, the path became
    // unwritable while the walk ran — would otherwise leave the staging file as
    // the rubble this whole arrangement exists to avoid.
    await File(stagingPath).rename(destinationPath);
  } catch (_) {
    _discardStaging(encoder, stagingPath);
    rethrow;
  }
}

/// Closes [encoder] if it still holds the staging file open and removes the
/// file, so a failed export leaves nothing behind.
///
/// Both steps are best-effort and neither may mask the original failure: this
/// runs from a `catch` that is about to rethrow, and an error raised here would
/// replace the one that says why the export failed. Closing first is not
/// optional on Windows, where a file that is still open cannot be deleted.
void _discardStaging(ZipFileEncoder encoder, String stagingPath) {
  try {
    encoder.closeSync();
  } catch (_) {
    // Already closed, or closing is what failed. Either way the delete below is
    // the part that matters.
  }
  try {
    final staging = File(stagingPath);
    if (staging.existsSync()) {
      staging.deleteSync();
    }
  } catch (_) {
    // A staging file we cannot remove is a stray file next to the destination.
    // It is not the user's data, and it is not worth turning into the error
    // they are shown.
  }
}
