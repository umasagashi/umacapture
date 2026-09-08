import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/chara_detail/record_zip.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/storage/storage_delete_request.dart';
import '/src/core/utils.dart';
import '/src/gui/common.dart';
import '/src/gui/storage_tree.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_import = "pages.chara_detail.import";

/// Whether a zip import is currently running (drives the toolbar spinner).
final _importingProvider = settableNotifierProvider<bool>(false);

/// Every path a record import holds open for its whole run.
///
/// **One derivation, two callers**, for the reason `recordExportLongReadPaths`
/// is one for the export's three: the set the import *claims* and the set this
/// button *asks about* have to be the same, and two lists written separately are
/// free to disagree — which is how a control is offered over a directory the
/// import is writing into, or a claim is taken over one it never touches.
///
/// **The record store root, and not the record ids the zips carry.** Which ids
/// arrive is not known until a zip has been decoded, and the window this claim
/// exists for opens before the first of them is read; a claim that grew as the
/// loop learned the ids would leave the store unheld over exactly the stretch
/// the defect lives in. The root is also the whole of what the import writes:
/// `WebRecordPersistence` resolves `storageDir / 'chara_detail'` and stages,
/// publishes and cleans up beneath it, so nothing lands outside
/// [PathInfo.charaDetailDir].
///
/// **Not `storageDir`, which is what [RecordZipService.import] is handed.** That
/// is the parent, and holding it would withhold the storage view's controls over
/// `storage/sound` — a folder no import has ever written to. The relocation is
/// refused all the same: `storageDeleteAwaitsExtraction` places a target inside a
/// hold *or* a hold inside a target, so a claim on the record store answers a
/// question asked about `storage/`.
List<PathEntity> recordImportLongReadPaths(PathInfo pathInfo) => [pathInfo.charaDetailDir];

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

/// Which registered long reader, if any, is holding what an import would write
/// into.
///
/// **One derivation, two subscriptions.** [CharaDetailImportButton.build]
/// watches, so the control follows the registry frame by frame;
/// [CharaDetailImportButton._pickAndImport] reads once, at the instant it is
/// about to write. Spelling the fold out twice — once for the button and once
/// for the run — is the shape that lets a control and the operation behind it
/// disagree about what they are guarding, so there is one of it.
///
/// Takes the resolved [PathInfo] rather than fetching it, because the two
/// callers reach it differently: the run has awaited `pathInfoLoader` and holds
/// the value, while `build` must not touch `pathInfoProvider` at all (it throws
/// until the record store has been prepared, which this button has never
/// depended on) and reads `pathLayoutProvider` instead.
///
/// The delete fold and not the extract one: an import writes where a delete, a
/// bundle and a relocation all act, so what matters is that *something* holds
/// the store, not which side of it this control is on.
LongReadKind? _importBlockedBy(PathInfo pathInfo, Iterable<LongReadClaim> claims) =>
    storageDeleteBlockedBy(StorageDeletePathsRequest(recordImportLongReadPaths(pathInfo)), claims);

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
      // Asked again here, and not only in `build`. The gate the button carries
      // was resolved in a frame that is now arbitrarily old: the picker is a
      // modal dialog the user may leave open for minutes -- this method says so
      // a few lines above, as its reason for not gating on `context.mounted` --
      // and no frame is built while it is up. A zip, an archive or a relocation
      // started from the storage dialog in that stretch would otherwise be
      // walked straight over, because the claim this loop takes below excludes
      // nobody: the registry grants nothing, so arriving second at it is not an
      // error the `hold` reports. The same fold the button watched, asked once
      // more at the instant the write is about to start.
      final blockedBy = _importBlockedBy(pathInfo, container.read(longReadRegistryProvider).values);
      if (blockedBy != null) {
        // The one sentence every withheld surface shows, on the control's own
        // toast route rather than as a tooltip: by this point the user has
        // pressed the button and chosen files, so there is nothing left on
        // screen for a tooltip to hang from. Nothing has been read or written
        // yet -- this is above every `readAsBytes` -- so the sentence is as true
        // here as it is on the button, which is what lets one line serve both.
        Toaster.show(ToastData.error(description: longReadBusyMessage()));
        return;
      }
      final importedIds = <String>{};
      // Keyed by record id for the same reason `importedIds` is a set: one record
      // split across several pieces of one export is one record, and is refused
      // once even if it is met twice.
      final refusals = <String, RecordImportRefusal>{};
      var committed = false;
      var failures = 0;
      var tooLargeFailures = 0;
      // **The claim is over the whole selection, and it starts here rather than
      // inside [RecordZipService.import].** The service's own window is one
      // zip's persistence; this loop's is longer at both ends -- `readAsBytes`
      // below reads a multi-megabyte file (or fetches the picked blob on web)
      // outside every acquisition, and between two zips nothing at all is held.
      // `pathInfo` was resolved before the loop and is not read again, so a
      // relocation granted anywhere in that stretch renames the store away while
      // the remaining zips are still being written into the old one, where the
      // next startup does not look. The registry is what refuses it: the
      // relocation asks `storageDeleteBlockedBy` over the roots it would move,
      // and this claim is the answer.
      //
      // `hold` and not `claimUntilReleased`, so the release is the registry's
      // `finally` and not a line here to forget: a zip that throws, a picker
      // result that turns out empty, and this toolbar being disposed mid-import
      // all end the claim by the same path (`release` returns early once the
      // container is gone, which is the case the widget's disposal produces).
      await container
          .read(longReadRegistryProvider.notifier)
          .hold(
            kind: LongReadKind.import,
            paths: recordImportLongReadPaths(pathInfo),
            action: (_) async {
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
            },
          );
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
    // Watched, not read: the claim this button has to respect is normally taken
    // long after it was built -- a zip, an archive or a relocation started from
    // the storage dialog on another tab -- and is released again while this
    // toolbar is still up. A gate that answered once, at build time, would be
    // wrong in both directions.
    final claims = ref.watch(longReadRegistryProvider).values;
    // The layout and not `pathInfoProvider`, for the reason
    // `module_update_dialog.dart` states: an import needs to know where the
    // store is, not that it was successfully prepared, and the second throws
    // while it has not been.
    final layout = ref.read(pathLayoutProvider);
    // Asked through [_importBlockedBy], so the set withheld here is the set the
    // run claims and the set the run asks about again once the picker returns.
    final heldByLongRead = layout != null && _importBlockedBy(layout, claims) != null;
    // The import's own claim is one of these while it runs, so the two reasons
    // overlap on purpose; the spinner and the sentence below both prefer
    // [importing], which is the one the user just caused.
    final withheld = importing || heldByLongRead;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: SizedBox(
        height: buttonSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Disabled(
              disabled: withheld,
              tooltip: importing ? "$tr_import.disabled_tooltip".tr() : longReadBusyMessage(),
              child: IconButton(
                icon: const Icon(Symbols.upload_rounded, size: 22),
                tooltip: "$tr_import.button_tooltip".tr(),
                visualDensity: VisualDensity.compact,
                splashRadius: 20,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
                onPressed: withheld ? null : () => _pickAndImport(context),
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
