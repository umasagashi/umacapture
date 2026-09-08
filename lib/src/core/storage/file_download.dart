/// Handing one file out of the storage view to wherever the user keeps files
/// (stage 5b).
///
/// **One implementation for both platforms.** `FilePicker.saveFile(bytes:)` is
/// the whole operation on either host: on Windows it runs `GetSaveFileNameW` and
/// then writes the bytes it was given to the chosen path, and on web it wraps
/// them in a `Blob` and clicks an anchor. So the file is read once, in full, and
/// handed over — there is no second code path to keep in step, and nothing here
/// asks which platform it is on except for the one thing that genuinely differs,
/// which is what a `null` return means (see [saveDialogReportsPathProvider]).
///
/// Reading the file **whole** is deliberate, and is the one place this library
/// parts company with the preview layer: `FsBackend.readHead` exists so a `.onnx`
/// or the font cache is not pulled into memory to be looked at, but a download's
/// entire purpose is to reproduce the file, so a head would produce a truncated
/// copy that looks like a success.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '/src/core/fs/record_mutation_lock.dart';
import '/src/core/path_entity.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';

import 'long_read_registry.dart';
import 'storage_exclusion.dart';
import 'storage_group.dart';

/// The save dialog, as a dependency rather than as a direct call.
///
/// Narrower than the record exporter's `ExportSaveFile`: this one always hands
/// over the bytes it wants written, so it has no `initialDirectory` (the storage
/// tab is not exporting into a downloads folder, it is copying a file out) and no
/// `lockParentWindow` (always true — the dialog is modal to the tab that opened
/// it).
typedef StorageSaveFile =
    Future<String?> Function({required String dialogTitle, required String fileName, required Uint8List bytes});

Future<String?> _saveStorageFile({required String dialogTitle, required String fileName, required Uint8List bytes}) {
  return FilePicker.saveFile(dialogTitle: dialogTitle, fileName: fileName, bytes: bytes, lockParentWindow: true);
}

/// The seam every storage-view download goes through — and, because it is the
/// same operation with the same three arguments, the one the settings page's
/// raw-frame probe uses too (`saveRawFrameBundle`). One seam rather than a
/// second copy, so a caller cannot be added that skips the outcome reading
/// [saveDialogReportsPathProvider] describes.
///
/// Production reads this provider, so a test that overrides it is observing the
/// bytes the real flow would have handed to the platform — not a branch that
/// exists for the test. The dialog itself cannot be driven from a test at all
/// (it is an OS window), so this is the last point inside the app where the
/// payload is still inspectable.
final storageSaveFileProvider = Provider<StorageSaveFile>((_) => _saveStorageFile);

/// Whether this build's save dialog reports **where** the file went.
///
/// This is the one real divergence in the download path, and it is a property of
/// the return value rather than of the operation:
///
///  * **Windows** — the dialog answers with the path the user chose, and
///    `file_picker` writes the bytes there. A `null` therefore means the user
///    dismissed the dialog: nothing was written and nothing should be announced.
///  * **Web** — `file_picker`'s web implementation starts an anchor download and
///    then `return null` unconditionally (`file_picker_web.dart`), because a
///    browser download has no path to report. A `null` there carries **no
///    information at all**, and reading it as a cancellation would report every
///    successful download as one — silently, since the failure mode is a missing
///    message rather than an error.
///
/// A capability and not a platform check, and a provider and not the `const`
/// itself, for the reason `clipboardFileReferenceSupportProvider` states: `kIsWeb`
/// folds away in a VM build, so a widget or a function reading it directly makes
/// the browser arrangement unreachable rather than merely untested.
final saveDialogReportsPathProvider = Provider<bool>((_) => !kIsWeb);

/// Whether this build's save route rejects a file name with no extension.
///
/// **Divergence, web only, and the constraint is `file_picker`'s web leg:** it
/// refuses a name whose `p.extension` is empty (`file_picker_web.dart`,
/// "The file name should include a valid file extension") *before* it ever
/// reaches the browser — the browser itself would download such a file happily.
/// Windows has no such rule: `GetSaveFileNameW` takes any name.
///
/// This is checked **ahead of the call**, not by catching what it throws: an
/// exception type and message are the package's private business and would
/// change under an upgrade without a compile error, which would silently turn a
/// specific, actionable sentence back into the generic failure one.
///
/// The app does not rename the file to get around this. The storage view's whole
/// premise is that the user is looking at their own files under their own names,
/// and a download that quietly became `LICENSE.bin` would be a different file
/// from the one on screen. Extensionless files really do occur here — the
/// unclassified group collects whatever is in the app's roots.
final saveDialogRequiresFileExtensionProvider = Provider<bool>((_) => kIsWeb);

/// What a download request did.
///
/// [saved] and [downloadRequested] are both successes and are kept apart because
/// only one of them can say *where* the file is; [cancelled] is not a failure and
/// carries no message, because the user is the one who caused it.
/// [extensionRefused] is a failure with a *known* cause, which is why it is not
/// folded into [failed]: the two are told apart by the sentence the user gets.
/// [lockBusy] and [lockUnavailable] are the two the exclusion adds, and are kept apart
/// from each other for the same reason: one is worth retrying and the other is
/// not, and a single sentence covering both would have to be wrong about one.
/// [emptyRefused] is the second failure with a known cause: neither platform's
/// save route will write a zero-byte file, so the app refuses it rather than
/// letting Windows report a save it did not perform (see [downloadStorageFile]).
enum StorageDownloadOutcome {
  saved,
  downloadRequested,
  cancelled,
  failed,
  extensionRefused,
  emptyRefused,
  lockBusy,
  lockUnavailable,
}

/// Reads [file] whole and offers it to the user through the platform's save
/// dialog, announcing the outcome.
///
/// [file] must belong to [group], which is what decides who has to be out of the
/// way while it is read. The exclusion covers **the read and nothing
/// else**: the save dialog that follows sits open until the user answers it, and
/// a record lock held across that would stall the capture merge for however long
/// they take, over a file that has already been copied into memory.
///
/// Returns what happened. [silent] suppresses the toast (tests, and any future
/// caller that has a better place to put the outcome).
Future<StorageDownloadOutcome> downloadStorageFile(
  RefBase ref,
  FilePath file, {
  required StorageGroup group,
  bool silent = false,
}) async {
  // Before the read, not after: refusing a 13 MB model after pulling it into
  // memory would cost exactly what the refusal is meant to avoid. `p.extension`
  // is the same function the web leg tests with, so the answer here and the
  // answer there cannot disagree.
  if (ref.read(saveDialogRequiresFileExtensionProvider) && p.extension(file.name).isEmpty) {
    if (!silent) {
      Toaster.show(ToastData.error(description: 'pages.storage.download.needs_extension'.tr()));
    }
    return StorageDownloadOutcome.extensionRefused;
  }

  final Uint8List bytes;
  try {
    bytes = await runUnderStorageExclusion(
      ref,
      group: group,
      target: file,
      intent: StorageExclusionIntent.read,
      // One file into memory and straight out to the save dialog. It is the
      // *dialog* that then takes an unbounded amount of the user's time, and by
      // then this frame has returned and the bytes are no longer being read from
      // storage — so a claim held here would end at the wrong moment anyway.
      declaration: const LongReadDeclaration.none(reason: 'one file read into memory; the wait after it is the dialog'),
      beforeMaintenance: const BeforeRootMaintenance.none(
        reason: 'a download removes nothing, so there is no set of entries a later drain could add to',
      ),
      action: (_) => file.readAsBytes(),
    );
  } on RecordMutationLockBusy catch (e, st) {
    // `logger.w`, not `logger.e`: another writer held the file longer than the
    // budget. Nothing is broken, nothing was written, and the sentence below
    // says so — a state that must never be reported as a success.
    logger.w('Storage download could not take its lock in time: ${file.path}', e, st);
    if (!silent) {
      Toaster.show(ToastData.error(description: 'pages.storage.download.busy'.tr()));
    }
    return StorageDownloadOutcome.lockBusy;
  } on RecordMutationLockUnavailable catch (e, st) {
    logger.w('Storage download has no exclusion primitive: ${file.path}', e, st);
    if (!silent) {
      Toaster.show(ToastData.error(description: 'pages.storage.download.unavailable'.tr()));
    }
    return StorageDownloadOutcome.lockUnavailable;
  } catch (e, st) {
    return _fail(e, st, silent: silent);
  }

  // Asked here rather than folded into a platform capability, because for once
  // the two platforms agree: **neither save route will write a zero-byte file.**
  // Windows' `saveBytesToFile` opens with
  // `if (path == null || bytes == null || bytes.isEmpty) return;`, so the dialog
  // still answers the chosen path and nothing is written at it — and since the
  // dialog runs with `confirmOverwrite: true`, that path can be a file the user
  // already had, which would then keep its old contents while this function
  // announced a save. Web's leg throws `ArgumentError` for the same input. So a
  // capability provider here would be a divergence that does not exist.
  //
  // Before the dialog and not after: refusing afterwards would still be honest,
  // but only after walking the user through choosing — and confirming an
  // overwrite of — a destination that was never going to be written. It is after
  // the read rather than before because the bytes are what the seam is given, so
  // asking them is exact, where a stat could be answering about a different
  // moment; and a zero-byte read costs nothing.
  //
  // This is the first of the web leg's three preconditions. The third is
  // [saveDialogRequiresFileExtensionProvider]; the second, an empty file name,
  // cannot occur — `file.name` is the last segment of a path that resolved to a
  // file, so it is never empty.
  if (bytes.isEmpty) {
    if (!silent) {
      // Its own sentence, and the pair to `needs_extension`: both are refusals
      // with a *known* cause that the user can act on (this file is empty; this
      // file has no extension), which is what keeps them out of the generic
      // `failed`. They sit next to each other in `ja.json` for the same reason.
      Toaster.show(ToastData.error(description: 'pages.storage.download.is_empty'.tr()));
    }
    return StorageDownloadOutcome.emptyRefused;
  }

  // Read before the await so the answer cannot change mid-flight, and read from
  // the same ref the bytes came through.
  final reportsPath = ref.read(saveDialogReportsPathProvider);
  final String? savedPath;
  try {
    savedPath = await ref.read(storageSaveFileProvider)(
      dialogTitle: 'pages.storage.actions.download_file'.tr(),
      fileName: file.name,
      bytes: bytes,
    );
  } catch (e, st) {
    return _fail(e, st, silent: silent);
  }

  if (!reportsPath) {
    // The browser has the bytes; `savedPath` is null here whatever happened, so
    // it is not consulted. Announcing a place the file went would be a guess.
    _announce(silent, 'pages.storage.download.started');
    return StorageDownloadOutcome.downloadRequested;
  }
  if (savedPath == null) {
    // Dismissed. No toast: nothing happened, and the user is the one who
    // decided so.
    return StorageDownloadOutcome.cancelled;
  }
  _announce(silent, 'pages.storage.download.saved');
  return StorageDownloadOutcome.saved;
}

StorageDownloadOutcome _fail(Object error, StackTrace stackTrace, {required bool silent}) {
  logger.e('Failed to download a file from the storage view', error, stackTrace);
  if (!silent) {
    Toaster.show(ToastData.error(description: 'pages.storage.download.failed'.tr()));
  }
  return StorageDownloadOutcome.failed;
}

void _announce(bool silent, String key) {
  if (silent) return;
  Toaster.show(ToastData.success(description: key.tr()));
}
