import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/record_sync_edits.dart';
import '/src/chara_detail/record_zip.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/storage/record_write_effects.dart';
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

/// Runs the resolution a capture runs over the records an import wrote ([writtenIds]), once both
/// stores have been re-listed after [applyRecordsPublished].
///
/// A failure here leaves every record on disk and in the table; only the links and relation bonuses
/// the resolution would have written are missing, and the manual whole-store resolution fills them.
/// So it is reported with the resolution's own sentence and does not turn the import into a failure.
Future<void> _resolveImportedInheritance(ProviderContainer container, Iterable<String> writtenIds) async {
  try {
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    await container.read(charaDetailRecordStorageLoaderProvider.notifier).resolveImportedInheritance(writtenIds);
  } catch (error, stackTrace) {
    logger.e("Failed to resolve inheritance for imported records.", error, stackTrace);
    Toaster.show(ToastData.error(description: "app.inheritance.failed".tr()));
  }
}

/// What a record import declares: the written records' cached pictures and previews are dropped,
/// and the storage view's totals are re-measured.
///
/// [base] must live as long as the container -- the import outlives the toolbar that started it.
RecordWriteEffects recordImportEffects(RefBase base) =>
    RecordWriteEffects(images: RecordImageEffect.drop(base), totals: RecordTotalsEffect.remeasure(base));

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
  RecordImportRefusal.duplicateOfExisting => "$tr_import.refused.duplicate_of_existing",
  RecordImportRefusal.notStored => "$tr_import.refused.not_stored",
};

/// How prominently [refusal] is shown.
///
/// [RecordImportRefusal.duplicateOfExisting] is a warning, not an error: the
/// record the user wanted is in the table, under the id it was captured with,
/// and they are asked to do nothing. Anything else is a record they wanted and
/// did not get.
@visibleForTesting
ToastType importRefusalToastType(RecordImportRefusal refusal) => switch (refusal) {
  RecordImportRefusal.duplicateOfExisting => ToastType.warning,
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
/// into — the question [CharaDetailImportButton.build] watches, so the control
/// follows the registry frame by frame.
///
/// The run does not call this: it asks [LongReadRegistry.holdWhenFree] about the
/// same [recordImportLongReadPaths], and the registry answers through the same
/// containment atom ([longReadHoldCovers]) that [storageDeleteAwaitsExtraction]
/// applies here. The paths are one derivation and the atom is one derivation, so
/// the control and the run behind it cannot disagree about what they are guarding.
///
/// Takes the resolved [PathInfo] rather than fetching it, because `build` must
/// not touch `pathInfoProvider` at all (it throws until the record store has been
/// prepared, which this button has never depended on) and reads
/// `pathLayoutProvider` instead.
///
/// The delete fold and not the extract one: an import writes where a delete, a
/// bundle and a relocation all act, so what matters is that *something* holds
/// the store, not which side of it this control is on.
LongReadKind? _importBlockedBy(PathInfo pathInfo, Iterable<LongReadClaim> claims) =>
    storageDeleteBlockedBy(StorageDeletePathsRequest(recordImportLongReadPaths(pathInfo)), claims);

/// The active record store, or null when this container has not built one.
///
/// [ProviderContainer.exists] and not a plain read: reading the provider would
/// *create* the store, and creating it scans the record directory and reports what
/// it finds. A duplicate check must not be the thing that starts a scan, and a
/// container with no store holds no records to duplicate, so there is nothing to
/// ask it. The store is built long before this toolbar can be pressed in the app.
CharaDetailRecordStorage? _loadedRecordStorage(ProviderContainer container) {
  if (!container.exists(charaDetailRecordStorageLoaderProvider)) return null;
  return container.read(charaDetailRecordStorageLoaderProvider.notifier);
}

/// One step of a record import ([runRecordImport]): writes records into the store under the storage directory it is
/// handed, asking the import's duplicate rule of each, and answers what it wrote — a zip
/// ([RecordZipService.import]) or the files of a shared record ([RecordZipService.importFiles]).
typedef RecordImportStep =
    Future<RecordImportResult> Function(
      DirectoryPath storageDir,
      bool Function(CharaDetailRecord record, Iterable<CharaDetailRecord> stored) isDuplicate,
    );

/// The records a [runRecordImport] has written and refused so far, across its steps.
class RecordImportProgress {
  RecordImportProgress._(this._storageDir, this._latestById);

  final DirectoryPath _storageDir;
  final Map<String, CharaDetailRecord> _latestById;

  /// Ids of the records written. A set: one record split across several pieces of one export is one record.
  final importedIds = <String>{};

  /// The records not written, by id, keyed by id for the same reason.
  final refusals = <String, RecordImportRefusal>{};

  /// Whether a step reached the store at all, so the stores are re-listed even where it wrote nothing new.
  bool _committed = false;

  /// Runs [step] against the store, weighing each record it carries against the store's records and those the
  /// steps before it wrote ([duplicateCharaIdIn]); a step that throws has written nothing of its own to record.
  Future<void> run(RecordImportStep step) async {
    bool isDuplicate(CharaDetailRecord record, Iterable<CharaDetailRecord> stored) =>
        duplicateCharaIdIn({..._latestById, for (final committed in stored) committed.id: committed}.values, record) !=
        null;
    final result = await step(_storageDir, isDuplicate);
    _committed = true;
    importedIds.addAll(result.recordIds);
    refusals.addAll(result.refusals);
    for (final record in result.acceptedRecords) {
      _latestById[record.id] = record;
    }
  }
}

/// Runs a record import: [action] calls [RecordImportProgress.run] for each step it has, under the import's claim
/// over the record store; then the stores are re-listed, sync is told, [report] tells the outcome of the steps as the
/// caller words it, every refused record is told by its reason, and the inheritance of the written records is
/// resolved.
///
/// The one way into the store for every import the toolbar starts — a zip and a shared record's link —, so the claim,
/// the duplicate rule, the resolution and the refusals' sentences cannot differ between them. [operation] names the
/// import in the log of a claim that refused it. Returns false where the import did not start (another long read
/// holds the store, or the store could not be found), true otherwise.
Future<bool> runRecordImport(
  ProviderContainer container, {
  required String operation,
  required Future<void> Function(RecordImportProgress progress) action,
  required void Function(RecordImportProgress progress) report,
}) async {
  // Declared before the first await, from the container the import reports through.
  final effects = recordImportEffects(container.read(containerRefProvider));
  // Held rather than re-read below, so the `finally` clearing the spinner reads
  // as the one counterpart of this line -- a disposed widget must not leave the
  // (app-scoped) importing flag stuck at true and the button disabled.
  final notifier = container.read(_importingProvider.notifier);
  notifier.set(true);
  try {
    final pathInfo = await container.read(pathInfoLoader.future);
    // The capture path's duplicate rule, asked of every record an import carries, so a
    // chara the user already has does not arrive a second time under a new id.
    //
    // Asked of one record per id: the latest version of it that is on disk. The
    // store's records are read once here -- the store does not change while the
    // import holds the claim below -- and every record a step commits replaces the
    // entry for its id, so a record this import replaced is weighed by its new
    // contents and not by the ones it had before. Only a committed record takes
    // its id's place; one the store refused leaves the stored version in it. If
    // the store is not loaded there is nothing to duplicate, and the map starts
    // empty.
    final progress = RecordImportProgress._(pathInfo.storageDir, <String, CharaDetailRecord>{
      for (final record in _loadedRecordStorage(container)?.existingRecords() ?? const <CharaDetailRecord>[])
        record.id: record,
    });
    // **The claim is over the whole import, and it starts here rather than
    // inside [RecordZipService.import].** The service's own window is one
    // step's persistence; the import's is longer at both ends -- a zip's
    // `readAsBytes` reads a multi-megabyte file (or fetches the picked blob on web)
    // outside every acquisition, and between two zips nothing at all is held.
    // `pathInfo` was resolved before the loop and is not read again, so a
    // relocation granted anywhere in that stretch renames the store away while
    // the remaining zips are still being written into the old one, where the
    // next startup does not look. The registry is what refuses it: the
    // relocation asks `storageDeleteBlockedBy` over the roots it would move,
    // and this claim is the answer.
    //
    // Asked and claimed in one turn, here and not only in `build`: the picker and the
    // link dialog are modal and the user may leave them open for minutes, and no frame
    // of the toolbar is built while they are up, so the gate the button carried can be
    // arbitrarily old. A claim that arrived in that stretch -- a zip, an archive, a
    // relocation -- refuses this import before anything is read.
    //
    // `holdWhenFree` and not `claimUntilReleased`, so the release is the
    // registry's `finally` and not a line here to forget: a step that throws,
    // and the toolbar being disposed mid-import, end the claim by the same path
    // (`release` returns early once the container is gone, which is the case the
    // widget's disposal produces).
    try {
      await container
          .read(longReadRegistryProvider.notifier)
          .holdWhenFree(
            kind: LongReadKind.import,
            paths: recordImportLongReadPaths(pathInfo),
            contention: LongReadContention.refuse,
            action: (_) => action(progress),
          );
    } on LongReadNotStartedException catch (exception) {
      // Caught here, inside the generic `catch` below, so a refusal is not
      // reported as `$tr_import.failure`: nothing has been written -- this is
      // above every step -- so the one sentence every withheld surface shows is
      // as true here as it is on the button. It goes on a toast because by this
      // point the user has asked for the import, and there is nothing left on
      // screen for a tooltip to hang from. The `finally` below still takes the
      // spinner down.
      announceLongReadNotStarted(exception, operation: operation);
      return false;
    }
    // Deliberately not gated on the toolbar still being mounted: the records are on disk and the
    // app-scoped stores are stale whether or not it survived, so the toast (published to an
    // app-wide stream) and the rescan below both still have to happen -- otherwise an import the
    // user navigated away from stays invisible in the table until the app is restarted.
    // Asked before the rescan below rebuilds the store: a container that never built it has no
    // record set to resolve against, the same silence the duplicate check above takes.
    final resolvesAfterImport = container.exists(charaDetailRecordStorageLoaderProvider);
    final importedIds = progress.importedIds;
    if (progress._committed) {
      // Over the container's ref rather than the toolbar's own: the import outlives the widget that started it,
      // which is the same reason this reads the container before the first await.
      applyRecordsPublished(container.read(containerRefProvider), pathInfo, writtenIds: importedIds, effects: effects);
      // The records an import put in are an edit of what sync carries.
      if (importedIds.isNotEmpty) container.read(syncLocalEditsProvider.notifier).edited();
    }
    report(progress);
    // The per-record half of the outcome, which the step-level messages of [report]
    // cannot express: a step can be read end to end and still have records the
    // store refused. Those records are in what the user asked for and are not
    // in the table afterwards, so each reason says how many and what (if
    // anything) to do about it.
    for (final toast in importRefusalToasts(progress.refusals)) {
      Toaster.show(toast);
    }
    if (progress._committed && resolvesAfterImport) {
      await _resolveImportedInheritance(container, importedIds);
    }
    return true;
  } catch (error, stackTrace) {
    // Reached when the import could not be attempted at all (e.g. the storage
    // layout is unavailable), not for a step that failed to import.
    logger.e("Failed to import records", error, stackTrace);
    Toaster.show(ToastData.error(description: "$tr_import.failure".tr()));
    return false;
  } finally {
    notifier.set(false);
  }
}

/// Whether a record import is running, or another long read holds what one would write into: the toolbar's import
/// controls are withheld while it is. [importing] is the first of the two, which the spinner and the sentence prefer.
({bool withheld, bool importing}) recordImportWithheld(WidgetRef ref) {
  final importing = ref.watch(_importingProvider);
  // Watched, not read: the claim the controls have to respect is normally taken
  // long after they were built -- a zip, an archive or a relocation started from
  // the storage dialog on another tab -- and is released again while the
  // toolbar is still up. A gate that answered once, at build time, would be
  // wrong in both directions.
  final claims = ref.watch(longReadRegistryProvider).values;
  // The layout and not `pathInfoProvider`, for the reason
  // `module_update_dialog.dart` states: an import needs to know where the
  // store is, not that it was successfully prepared, and the second throws
  // while it has not been.
  final layout = ref.read(pathLayoutProvider);
  // Asked through [_importBlockedBy], so the set withheld here is the set the
  // run claims and the set the run asks about again once the user has chosen.
  final heldByLongRead = layout != null && _importBlockedBy(layout, claims) != null;
  // The import's own claim is one of these while it runs, so the two reasons
  // overlap on purpose.
  return (withheld: importing || heldByLongRead, importing: importing);
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
    var failures = 0;
    var tooLargeFailures = 0;
    await runRecordImport(
      container,
      operation: 'An import of ${result.files.length} zip(s)',
      action: (progress) async {
        for (final file in result.files) {
          try {
            final bytes = await file.readAsBytes();
            await progress.run(
              (storageDir, isDuplicate) => RecordZipService.import(bytes, storageDir, isDuplicate: isDuplicate),
            );
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
      report: (progress) {
        final importedIds = progress.importedIds;
        if (failures == 0) {
          if (importedIds.isEmpty && progress.refusals.isEmpty) {
            Toaster.show(ToastData.warning(description: "$tr_import.empty".tr()));
          } else if (importedIds.isEmpty) {
            // Records were found and every one of them was refused, so "no records
            // to import" would be false and "0 imported" would say nothing about
            // why. The refusal toasts carry the whole outcome, with the reason and
            // the count, so this branch deliberately adds no line of its own rather
            // than a second, vaguer one.
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
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Match CharaDetailExportButton's metrics exactly so the two controls are
    // visually indistinguishable in the toolbar.
    const buttonSize = 36.0;
    final (:withheld, :importing) = recordImportWithheld(ref);
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
