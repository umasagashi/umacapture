import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/chara_detail/record_zip.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/gui/common.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_import = "pages.chara_detail.import";

/// Whether a zip import is currently running (drives the toolbar spinner).
final _importingProvider = settableNotifierProvider<bool>(false);

/// The **full** translation key for the sentence [refusal] owes the user.
///
/// Exhaustive and explicit rather than derived from `refusal.name`, for the
/// reason `regenerateAllBlockerKey` states in `settings.dart`: easy_localization
/// renders a key it cannot find **as the key**, so a mistyped or absent key ships
/// `pages.…` into a toast instead of failing anywhere. The `switch` also means a
/// third [RecordImportRefusal] cannot be added without the compiler demanding a
/// sentence for it — which is the whole point of the enum, since the defect being
/// fixed here is precisely a refusal that reached the user as nothing at all.
@visibleForTesting
String importRefusalKey(RecordImportRefusal refusal) => switch (refusal) {
  RecordImportRefusal.alreadyArchived => "$tr_import.refused.already_archived",
  RecordImportRefusal.notStored => "$tr_import.refused.not_stored",
};

/// How prominently [refusal] is shown.
///
/// [RecordImportRefusal.alreadyArchived] is a warning, not an error: the user
/// already owns that record and is asked to do nothing. Anything else is a
/// record they wanted and did not get.
@visibleForTesting
ToastType importRefusalToastType(RecordImportRefusal refusal) => switch (refusal) {
  RecordImportRefusal.alreadyArchived => ToastType.warning,
  RecordImportRefusal.notStored => ToastType.error,
};

/// One toast per reason present in [refusals], each carrying its own count.
///
/// Grouped by counting what is in the map, not by testing for a fixed list of
/// reasons: adding a member to [RecordImportRefusal] adds a group here without
/// this function being touched, and [importRefusalKey] then refuses to compile
/// until it has a sentence. Emitted in enum order so a mixed selection reads the
/// same way every time.
@visibleForTesting
List<ToastData> importRefusalToasts(Map<String, RecordImportRefusal> refusals) {
  final counts = <RecordImportRefusal, int>{};
  for (final refusal in refusals.values) {
    counts.update(refusal, (value) => value + 1, ifAbsent: () => 1);
  }
  return [
    for (final refusal in RecordImportRefusal.values)
      if (counts[refusal] case final int count)
        ToastData(
          type: importRefusalToastType(refusal),
          description: importRefusalKey(refusal).tr(namedArgs: {"count": "$count"}),
        ),
  ];
}

/// Toolbar control that imports records from Stage-4-compatible zips.
///
/// Picks one or more `.zip` files with the platform file picker (bytes-based, so
/// it works on web where there is no file path), decodes each through
/// [RecordZipService], writes the record files under the store's `active/`
/// directory, then invalidates the record stores so the freshly imported records
/// populate the table.
///
/// The byte-based picker and transaction service are shared across desktop and
/// web, so the same import control is available on every supported platform.
class CharaDetailImportButton extends ConsumerWidget {
  const CharaDetailImportButton({super.key});

  Future<void> _pickAndImport(BuildContext context) async {
    // The container, not this widget's `ref`: the picker is modal and the import that follows takes
    // one await per selected zip, so this toolbar can be disposed anywhere along the way, while the
    // container -- and the app-scoped stores and flag it holds -- lives on. Read before the first
    // await, from a context that is certainly still mounted; nothing below touches `ref` at all.
    final container = ProviderScope.containerOf(context, listen: false);
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ["zip"],
      // Stated rather than inherited from the default. A whole selection is
      // imported because this feature itself prescribes splitting: an export
      // over the size limit is refused with `too_large`, which tells the user to
      // import the zip in several pieces. Taking only the first of those pieces
      // and dropping the rest without a word would contradict the instruction.
      // ignore: deprecated_member_use
      allowMultiple: true,
      // Stated because the default is `true` on web, where it would materialise
      // every selected zip in memory the moment the dialog closes -- exactly the
      // memory pressure the split is meant to relieve. With it off,
      // `readAsBytes()` below fetches one zip at a time (from its blob URL on
      // web, from the path on desktop) and the previous one becomes collectable.
      // ignore: deprecated_member_use
      withData: false,
      lockParentWindow: true,
    );
    if (result == null || result.files.isEmpty) {
      return; // Cancelled.
    }
    // No `context.mounted` gate here, deliberately. The picker awaits on a dialog the user may leave
    // open for minutes, so this toolbar can be gone by the time it answers -- but a selection the
    // user made is a selection they expect something to come of, and returning here would discard it
    // with no toast and no log line, which is the very silence this control exists to avoid. The
    // import runs to completion and reports itself through the container, as it does from any other
    // point past this line.
    //
    // Held rather than re-read below, so the `finally` clearing the spinner reads
    // as the one counterpart of this line -- a disposed widget must not leave the
    // (app-scoped) importing flag stuck at true and the button disabled.
    final notifier = container.read(_importingProvider.notifier);
    notifier.set(true);
    try {
      final pathInfo = await container.read(pathInfoLoader.future);
      final importedIds = <String>{};
      // Keyed by record id for the same reason `importedIds` is a set: one record
      // split across several pieces of one export is one record, and is refused
      // once even if it is met twice.
      final refusals = <String, RecordImportRefusal>{};
      var committed = false;
      var failures = 0;
      var tooLargeFailures = 0;
      for (final file in result.files) {
        try {
          final bytes = await file.readAsBytes();
          final importResult = await RecordZipService.import(bytes, pathInfo.storageDir);
          committed = true;
          // Union, because the same record may appear in more than one of the
          // pieces a single export was split into, and it is imported once.
          importedIds.addAll(importResult.recordIds);
          refusals.addAll(importResult.refusals);
        } catch (error, stackTrace) {
          // Per zip: one unreadable piece of a split export must not discard the
          // pieces that follow it -- the user picked them all in one dialog and
          // cannot tell which one the loop stopped on.
          logger.e("Failed to import records from ${file.name}", error, stackTrace);
          failures += 1;
          if (error is RecordZipTooLargeException) {
            tooLargeFailures += 1;
          }
        }
      }
      // Deliberately not gated on the toolbar still being mounted: the records are on disk and the
      // app-scoped stores are stale whether or not it survived, so the toast (published to an
      // app-wide stream) and the rescan below both still have to happen -- otherwise an import the
      // user navigated away from stays invisible in the table until the app is restarted.
      if (committed) {
        // Rescan both stores so the imported records appear. The active store's
        // build() re-lists active/; the archive rescan keeps dedup/inheritance
        // views consistent even though the import only touches active/.
        container.invalidate(charaDetailRecordStorageLoaderProvider);
        container.invalidate(charaDetailArchiveStorageLoaderProvider);
      }
      if (failures == 0) {
        if (importedIds.isEmpty && refusals.isEmpty) {
          Toaster.show(ToastData.warning(description: "$tr_import.empty".tr()));
        } else if (importedIds.isEmpty) {
          // Records were found and every one of them was refused, so "no records
          // to import" would be false and "0 imported" would say nothing about
          // why. The refusal toasts below carry the whole outcome, with the
          // reason and the count, so this branch deliberately adds no line of its
          // own rather than a second, vaguer one.
        } else {
          Toaster.show(
            ToastData.success(description: "$tr_import.success".tr(namedArgs: {"count": "${importedIds.length}"})),
          );
        }
      } else if (failures == result.files.length) {
        // Every zip failed. RecordZipTooLargeException is a distinct
        // FormatException subtype (see record_zip.dart), so the size branch only
        // matches the size/entry-count limits and not the zip-slip rejection,
        // which is a plain FormatException.
        final allTooLarge = tooLargeFailures == failures;
        if (result.files.length == 1) {
          // One zip is the only failure shape a single selection has: report it
          // exactly as this button always has, down to the wording.
          Toaster.show(ToastData.error(description: "$tr_import.${allTooLarge ? "too_large" : "failure"}".tr()));
        } else {
          // Several zips, none of which arrived. The single-selection wording
          // would not say how many were refused -- and its `too_large` variant
          // tells the user to split the export into several zips, which is
          // exactly what they just did and had rejected.
          final messageKey = allTooLarge ? "all_too_large" : "all_failure";
          Toaster.show(ToastData.error(description: "$tr_import.$messageKey".tr(namedArgs: {"failed": "$failures"})));
        }
      } else {
        // Only reachable with several zips selected. Neither the success nor the
        // failure message is true here, and saying either would hide the other
        // half of the selection.
        Toaster.show(
          ToastData.warning(
            description: "$tr_import.partial_failure".tr(
              namedArgs: {"count": "${importedIds.length}", "failed": "$failures"},
            ),
          ),
        );
      }
      // The per-record half of the outcome, which the zip-level messages above
      // cannot express: a zip can be read end to end and still have records the
      // store refused. Those records are in the file the user picked and are not
      // in the table afterwards, so each reason says how many and what (if
      // anything) to do about it.
      for (final toast in importRefusalToasts(refusals)) {
        Toaster.show(toast);
      }
    } catch (error, stackTrace) {
      // Reached when the import could not be attempted at all (e.g. the storage
      // layout is unavailable), not for a zip that failed to import.
      logger.e("Failed to import records", error, stackTrace);
      Toaster.show(ToastData.error(description: "$tr_import.failure".tr()));
    } finally {
      notifier.set(false);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Match CharaDetailExportButton's metrics exactly so the two controls are
    // visually indistinguishable in the toolbar.
    const buttonSize = 36.0;
    final importing = ref.watch(_importingProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: SizedBox(
        height: buttonSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Disabled(
              disabled: importing,
              tooltip: "$tr_import.disabled_tooltip".tr(),
              child: IconButton(
                icon: const Icon(Symbols.upload_rounded, size: 22),
                tooltip: "$tr_import.button_tooltip".tr(),
                visualDensity: VisualDensity.compact,
                splashRadius: 20,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
                onPressed: importing ? null : () => _pickAndImport(context),
              ),
            ),
            if (importing)
              const IgnorePointer(
                child: SizedBox(width: buttonSize, height: buttonSize, child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }
}
