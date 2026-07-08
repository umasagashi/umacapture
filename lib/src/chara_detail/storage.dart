import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/image_converter.dart';
import '/src/chara_detail/inheritance.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/core/clipboard_alt.dart';
import '/src/core/mapper_init.dart';
import '/src/core/path_entity.dart';
import '/src/core/platform_controller.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/capture.dart';
import '/src/gui/toast.dart';
import '/src/preference/storage_box.dart';

part 'storage.mapper.dart';

// Grade tag whose shared wins feed the inheritance relation bonus (G1 only, per
// the current game rule). Matches the literal used by the race-grade column.
const _gradeG1 = "grade_g1";

// Monotonic id so each duplicated-chara event yields a distinct StreamProvider value; the sound
// listener uses ref.listen(), which would otherwise dedupe equal consecutive AsyncData and skip
// repeated duplicate detections. See _soundEventSequence in platform_controller.dart.
int _duplicatedCharaEventSequence = 0;

final _duplicatedCharaEvent = EventStreamProvider<int>();
final duplicatedCharaEventProvider = _duplicatedCharaEvent.provider;

final charaCardIconMapProvider = settableNotifierProvider<Map<int, FilePath>>({});

class CharaDetailRecordRegenerationController extends Notifier<Progress> {
  @override
  Progress build() => Progress.none;

  Future<void> start(List<CharaDetailRecord> records) async {
    final platformController = await ref.read(platformControllerLoader.future);
    if (platformController == null) {
      return;
    }
    for (final record in records) {
      platformController.updateRecord(record.id);
    }
    logger.d("Start regenerating ${records.length} chara detail records.");
    state = Progress(total: records.length);
  }

  Future<void> updated(String id) async {
    // Always reload, even outside a batch: the native side can emit this for any
    // record regeneration, and a failed reload must not abort the refresh.
    // Completion is gated on the count reaching the total, so a single failed
    // reload would otherwise leave the progress stuck forever.
    try {
      await ref.read(charaDetailRecordStorageLoaderProvider.notifier).reload(id);
    } catch (e, s) {
      logger.w("Failed to reload regenerated record $id: $e\n$s");
    }
    // Advance batch progress only while a batch is in flight. Progress.none and
    // an already-completed batch both report isCompleted (count >= total), so a
    // stray/late/duplicate native callback would otherwise mark a zero-length
    // batch complete and re-fire completion (spurious success toast + rebuild).
    if (state.isCompleted) {
      return;
    }
    state = state.increment();
    if (state.isCompleted) {
      Future.delayed(const Duration(milliseconds: 200), () {
        ref.read(charaDetailRecordStorageLoaderProvider.notifier).forceRebuild();
        Toaster.show(
          ToastData(
            type: ToastType.success,
            description: "pages.capture.regenerate.success".tr(namedArgs: {"count": state.total.toString()}),
          ),
        );
        state = Progress.none;
      });
    }
    return Future.value();
  }
}

final charaDetailRecordRegenerationControllerProvider =
    NotifierProvider<CharaDetailRecordRegenerationController, Progress>(CharaDetailRecordRegenerationController.new);

// snake_case keeps decoding values written by the pre-dart_mappable Hive
// JsonAdapter, which serialized every enum with CaseStyle.snake (e.g.
// "skill_plain"). Without this, a previously-saved multi-word value throws
// MapperException.unknownEnumValue on read.
@MappableEnum(caseStyle: CaseStyle.snakeCase)
enum CharaDetailRecordImageMode { none, skillPlain, factorPlain, campaignPlain }

extension CharaDetailRecordImageModeExtension on CharaDetailRecordImageMode {
  String get fileName {
    switch (this) {
      case CharaDetailRecordImageMode.none:
        throw UnimplementedError();
      case CharaDetailRecordImageMode.skillPlain:
        return "skill.png";
      case CharaDetailRecordImageMode.factorPlain:
        return "factor.png";
      case CharaDetailRecordImageMode.campaignPlain:
        return "campaign.png";
    }
  }
}

/// Which record set the table currently shows.
enum RecordSource { active, archive }

/// Session-scoped toggle between the active and archive record sources.
///
/// Kept session-only (not persisted): the active set is the working view, so a
/// fresh launch starts there.
final recordSourceProvider = settableNotifierProvider<RecordSource>(RecordSource.active);

/// What a bulk row selection is being gathered for.
///
/// The same checkbox/selection machinery (checkbox column, scrim overlay that
/// freezes the columns and presets, per-row overlay) drives both flows; the
/// purpose only changes which action the scrim surfaces and how the rows are
/// labeled.
enum SelectionPurpose {
  /// Selecting rows to bulk-archive. Active source only.
  archive,

  /// Selecting rows to export. Available for both sources.
  export,

  /// Selecting rows to permanently delete. Available for both sources.
  delete,
}

/// The purpose of the bulk row-selection UI currently engaged, or `null` when no
/// selection is in progress.
///
/// Reset to `null` when switching sources so checked rows from the previous
/// source do not leak across.
final selectionModeProvider = settableNotifierProvider<SelectionPurpose?>(null);

/// Ids of the rows checked for the current bulk selection, kept in sync from the
/// grid's `onRowChecked` callback. Cleared when leaving selection mode or
/// switching sources.
final selectedRecordIdsProvider = settableNotifierProvider<Set<String>>(<String>{});

/// Ids of the rows pinned to the top of the data table.
///
/// Session-only (not persisted): a fresh launch starts with no pinned rows.
/// Shared across record sources since ids are unique across active/archive, so a
/// row only renders pinned in the source where it is actually displayed.
final pinnedRecordIdsProvider = settableNotifierProvider<Set<String>>(<String>{});

/// What to do with a record's recognition images when archiving it.
enum ArchiveImageOption {
  /// Drop the images entirely (smallest result).
  none,

  /// Replace the lossless PNGs with width-clamped JPEGs.
  resizedJpeg,
}

/// Resolves the directory holding the record with [id]'s files for [source].
DirectoryPath recordDirOfId(PathInfo pathInfo, RecordSource source, String id) {
  final root = source == RecordSource.active ? pathInfo.charaDetailActiveDir : pathInfo.charaDetailArchiveDir;
  return root / id;
}

/// Resolves the directory holding [record]'s files for the given [source].
DirectoryPath recordDirOf(PathInfo pathInfo, RecordSource source, CharaDetailRecord record) =>
    recordDirOfId(pathInfo, source, record.id);

/// Path to the (always-retained) trainee icon inside [recordDir].
FilePath traineeIconPathIn(DirectoryPath recordDir) => recordDir.filePath(traineeIconFileName);

/// Resolves an existing image file for [mode] in [recordDir], or `null`.
///
/// Active records store lossless `.png`; archived records may instead hold a
/// downscaled `.jpg`, or no image at all. Prefers the lossless `.png` when both
/// exist — that only happens as a leftover when [_disposeArchivedImages] was
/// interrupted between writing the `.jpg` and deleting the `.png`, and in that
/// case the original is the better image. A normally-archived record (only the
/// `.jpg` present) falls through to the `.jpg`.
FilePath? resolveImagePath(DirectoryPath recordDir, CharaDetailRecordImageMode mode) {
  assert(mode != CharaDetailRecordImageMode.none);
  final png = recordDir.filePath(mode.fileName);
  if (png.existsSync()) {
    return png;
  }
  final jpg = recordDir.filePath(mode.fileName.replaceAll(".png", ".jpg"));
  if (jpg.existsSync()) {
    return jpg;
  }
  return null;
}

/// Copies a record's image (resolved by [resolveImagePath]) to the clipboard,
/// reporting via a toast when an archived record has no such image.
void copyRecordImageToClipboard(RefBase ref, DirectoryPath recordDir, CharaDetailRecordImageMode mode) {
  final imagePath = resolveImagePath(recordDir, mode);
  if (imagePath == null) {
    Toaster.show(ToastData.warning(description: "pages.chara_detail.archive_records.no_image".tr()));
    return;
  }
  // Fire-and-forget: pasteImage reports its own outcome via a toast.
  unawaited(ClipboardAlt.pasteImage(ref, imagePath));
}

/// Writes [record] to `record.json` under [recordDir], in the 4-space-indent
/// on-disk format the native recognizer and the exporter produce.
///
/// Shared by both stores' `_persist`, which only differ in the record directory
/// their `recordPathOf` resolves (active vs. archive root).
void _persistRecordJson(DirectoryPath recordDir, CharaDetailRecord record) {
  recordDir.filePath("record.json").writeAsStringSync(const JsonEncoder.withIndent('    ').convert(record.toMap()));
}

/// The mutation surface shared by the active ([CharaDetailRecordStorage]) and
/// archive ([CharaDetailArchiveStorage]) stores.
///
/// Lets callers that already know the [RecordSource] (delete/export flows) pick
/// the right store via [recordStorageFor] and act on it without re-branching on
/// the source at every call site.
abstract interface class CharaDetailRecordMutator {
  CharaDetailRecord? getBy({required String id});

  void delete(String id);

  void deleteAll(Iterable<String> ids);
}

class CharaDetailRecordStorage extends AsyncNotifier<List<CharaDetailRecord>> implements CharaDetailRecordMutator {
  late DirectoryPath rootDirectory;
  final Map<int, CharaDetailRecord> charaCardMap = {};

  @override
  Future<List<CharaDetailRecord>> build() async {
    final pathInfo = await ref.watch(pathInfoLoader.future);
    rootDirectory = pathInfo.charaDetailActiveDir;
    // Trigger the archive build in parallel so capture-time dedup and inheritance
    // resolution can consider archived records. read (not watch, and not awaited):
    // this starts the archive build without subscribing, so later archive
    // mutations (e.g. an inheritance write-back) do not rebuild this store, and
    // the capture listener below is registered without waiting for the archive
    // scan. Until the scan lands, add() reads its asData snapshot and degrades to
    // active-only via the `?? const []` fallback.
    ref.read(charaDetailArchiveStorageLoaderProvider);
    final List<CharaDetailRecord> records = [];
    if (rootDirectory.existsSync()) {
      final results = await compute(_loadAllCharaDetailRecord, rootDirectory);
      records.addAll(results.whereType<RecordLoaded>().map((e) => e.record));
      _surfaceQuarantines(ref, results.whereType<RecordQuarantined>().toList());
    }
    // Safe to write other providers here: we are past the `await` above, so the
    // synchronous build frame (which the modify-during-build guard checks) is done.
    charaCardMap.clear();
    for (final e in records) {
      _updateRecordInfo(e);
    }
    // riverpod 3 removed StreamProvider.stream; listen to the AsyncValue and react
    // to each newly captured record id. Registered with no intervening await after
    // the active load (the archive load above is deliberately not awaited), so the
    // window between this store building and the listener attaching stays as small
    // as it was before archived records were considered: the capture event stream
    // is a broadcast stream with no buffering, so an event delivered before this
    // listener attaches is lost. The callback stays synchronous so add() (and its
    // duplicate-fail override) completes within the stream-delivery microtask,
    // before the next native capture message is processed.
    ref.listen(charaDetailRecordCapturedEventProvider, (_, next) {
      next.whenData((e) => addFromFile(e));
    });
    _checkRecordVersion(records);
    return records;
  }

  // Holds silent updates accumulated during a regeneration batch. While
  // non-null, reads see it instead of the published state; forceRebuild()
  // publishes it. Kept separate so we never mutate the list held by the live
  // AsyncData (which would defeat riverpod's identity-based change detection).
  List<CharaDetailRecord>? _pendingRecords;

  List<CharaDetailRecord> get _records => _pendingRecords ?? state.requireValue;

  int get length => _records.length;

  bool get isEmpty => _records.isEmpty;

  void _updateRecordInfo(CharaDetailRecord record) {
    if (record.evaluationValue > (charaCardMap[record.trainee.card]?.evaluationValue ?? -1)) {
      charaCardMap[record.trainee.card] = record;
      ref.read(charaCardIconMapProvider.notifier).set(Map.from(charaCardIconMap));
    }
  }

  Map<int, FilePath> get charaCardIconMap {
    return charaCardMap.map((k, v) => MapEntry(k, (rootDirectory / v.id).filePath(traineeIconFileName)));
  }

  /// Early duplicate check driven by the factor-tab probe (before scrolling).
  ///
  /// Returns true and fires the duplicate notification (error sound + capture error) when
  /// [probeSelf] shares a long enough leading run of self-factors with any stored record (active or
  /// archived) to clear the match threshold for [recordType] (see
  /// [CharaDetailRecord.factorProbeMatchThreshold]). Fail-open: if storage is not loaded yet or
  /// nothing matches it returns false, so the caller emits the normal scroll-ready cue. This only
  /// notifies; the authoritative dedup still runs in [add] for the full record.
  bool reportDuplicateFromFactorProbe(List<Factor> probeSelf, RecordType? recordType) {
    if (probeSelf.isEmpty) {
      return false;
    }
    // Match add()'s view of the active set: fold in any pending batch updates so the probe and the
    // authoritative dedup agree. `_pendingRecords` already includes the published state when non-null
    // (see add()); fall back to the published state, staying null (fail-open) until storage loads.
    final activeRecords = _pendingRecords ?? state.asData?.value;
    if (activeRecords == null) {
      return false;
    }
    final threshold = CharaDetailRecord.factorProbeMatchThreshold(recordType);
    final archiveRecords =
        ref.read(charaDetailArchiveStorageLoaderProvider).asData?.value ?? const <CharaDetailRecord>[];
    final existing = [...activeRecords, ...archiveRecords];
    var bestMatch = 0;
    CharaDetailRecord? duplicated;
    for (final record in existing) {
      final common = record.leadingFactorProbeMatch(probeSelf);
      if (common > bestMatch) {
        bestMatch = common;
      }
      if (common >= threshold) {
        duplicated = record;
        break;
      }
    }
    logger.i(
      "Factor probe: ${probeSelf.length} factors, best leading match "
      "$bestMatch/$threshold, duplicate=${duplicated != null}",
    );
    if (duplicated == null) {
      return false;
    }
    _duplicatedCharaEvent.add(_duplicatedCharaEventSequence++);
    // Distinct from add()'s "duplicated_character": this fires before scrolling on the looser
    // leading-factor prefix match, so the message tells the user it is a preliminary check and that
    // scrolling anyway re-runs the authoritative dedup (which can clear a rare false positive).
    ref
        .read(charaDetailCaptureStateProvider.notifier)
        .fail("duplicated_character_probe", duplicateRecordId: duplicated.id);
    return true;
  }

  void add(CharaDetailRecord record) {
    final activeRecords = _records;
    // Consider archived records too, so a re-capture of an archived chara is
    // rejected as a duplicate and inheritance can link across both sets. Falls
    // back to active-only if the archive failed to preload (see build()).
    final archiveRecords =
        ref.read(charaDetailArchiveStorageLoaderProvider).asData?.value ?? const <CharaDetailRecord>[];
    final existing = [...activeRecords, ...archiveRecords];
    final duplicated = existing.firstWhereOrNull((e) => record.isSameChara(e));
    if (duplicated != null && duplicated.id != record.id) {
      (rootDirectory / record.id).deleteSyncWithCheck(recursive: true);
      _duplicatedCharaEvent.add(_duplicatedCharaEventSequence++);
      ref.read(charaDetailCaptureStateProvider.notifier).fail("duplicated_character", duplicateRecordId: duplicated.id);
      return;
    }

    // Link this record to existing parents/children (in either the active or the
    // archive set) by matching factors and card, then persist any record.json
    // whose parent ids changed, routing each change back to its owning store.
    final resolution = InheritanceResolver.resolveForNewRecord(record, existing, g1RaceSids: _g1RaceSids());
    final resolvedRecord = resolution.changed.firstWhereOrNull((e) => e.id == record.id) ?? record;
    final archiveIds = {for (final e in archiveRecords) e.id};
    final activeChildUpdates = <String, CharaDetailRecord>{};
    // The new record (always active) persists here too; only existing active
    // children feed the republish map.
    _routeInheritanceChanges(resolution, archiveIds, (updated) {
      if (updated.id != record.id) {
        activeChildUpdates[updated.id] = updated;
      }
    });
    _updateRecordInfo(resolvedRecord);

    // `activeRecords` already folds in any pending batch updates, so publishing it
    // and clearing the buffer keeps the next replaceBy re-snapshotting cleanly.
    // Drop any existing entry with the same id so re-adding a record (same id)
    // replaces it instead of appending a duplicate.
    _pendingRecords = null;
    state = AsyncData([
      for (final e in activeRecords)
        if (e.id != resolvedRecord.id) activeChildUpdates[e.id] ?? e,
      resolvedRecord,
    ]);

    _surfaceInheritance(resolution);

    final autoCopy = ref.read(autoCopyClipboardStateProvider);
    if (autoCopy != CharaDetailRecordImageMode.none) {
      copyToClipboard(resolvedRecord, autoCopy);
    }
  }

  /// Re-resolves parent/child links across every stored record (manual action).
  ///
  /// Additive like the per-capture path: it only fills empty parent slots and
  /// never clears a set link. The active and archive sets are resolved together,
  /// and each changed record is rewritten to disk and republished in its owning
  /// store. Aborts with a warning if the archive has not loaded (build() no longer
  /// awaits it): the relation-bonus recompute walks archived ancestors, so running
  /// it without the archive would tear down bonuses that depend on them.
  void resolveAllInheritance() {
    // Abort if the archive failed to load (or is still building). Links are never
    // cleared (resolution is additive), but the relation-bonus recompute reads
    // archived ancestors' race data; treating the archive as empty would drop
    // every active->archive pair to zero and rewrite those bonuses downward.
    final archiveRecords = ref.read(charaDetailArchiveStorageLoaderProvider).asData?.value;
    if (archiveRecords == null) {
      Toaster.show(ToastData.warning(description: "app.inheritance.archive_not_ready".tr()));
      return;
    }
    final resolution = InheritanceResolver.resolveAll([..._records, ...archiveRecords], g1RaceSids: _g1RaceSids());
    final archiveIds = {for (final e in archiveRecords) e.id};
    _routeInheritanceChanges(resolution, archiveIds, (updated) {
      replaceBy(updated, id: updated.id);
    });
    forceRebuild();
    _surfaceInheritance(resolution, alwaysReport: true);
  }

  /// G1 race title sids for the relation-bonus computation, or an empty set when
  /// the race-title module has not finished loading.
  ///
  /// Read through the loader's async state because [raceGradeSidProvider] (and
  /// [raceTitleInfoProvider] underneath it) dereference `.value!` and throw
  /// before the module resolves. An empty set tells the resolver to leave
  /// [Metadata.relationBonus] untouched, so link resolution still runs at capture
  /// time before the module is ready; the next full re-resolve fills the bonus in.
  Set<int> _g1RaceSids() {
    final loaded = ref.read(raceTitleInfoLoader).asData;
    if (loaded == null) {
      return const {};
    }
    return ref.read(raceGradeSidProvider(_gradeG1));
  }

  /// Routes each changed record to its owning store.
  ///
  /// Active records are persisted here and then handed to [onActive] for the
  /// store-specific in-memory republish; archived records are collected and
  /// written back (and republished) by the archive store in a single
  /// [CharaDetailArchiveStorage.applyInheritanceUpdates] call.
  void _routeInheritanceChanges(
    InheritanceResolution resolution,
    Set<String> archiveIds,
    void Function(CharaDetailRecord updated) onActive,
  ) {
    final archiveUpdates = <CharaDetailRecord>[];
    for (final updated in resolution.changed) {
      if (archiveIds.contains(updated.id)) {
        archiveUpdates.add(updated);
      } else {
        _persist(updated);
        onActive(updated);
      }
    }
    ref.read(charaDetailArchiveStorageLoaderProvider.notifier).applyInheritanceUpdates(archiveUpdates);
  }

  /// Reports the outcome of an inheritance resolution via toasts.
  ///
  /// A success toast is shown when links were written; with [alwaysReport] it is
  /// shown even for zero changes (so the manual action confirms it ran). A
  /// warning toast is shown whenever some slots were left unlinked as ambiguous.
  void _surfaceInheritance(InheritanceResolution resolution, {bool alwaysReport = false}) {
    if (resolution.changed.isNotEmpty || alwaysReport) {
      Toaster.show(
        ToastData.success(
          description: "app.inheritance.resolved".tr(namedArgs: {"count": "${resolution.changed.length}"}),
        ),
      );
    }
    if (resolution.ambiguities.isNotEmpty) {
      Toaster.show(
        ToastData.warning(
          description: "app.inheritance.ambiguous".tr(namedArgs: {"count": "${resolution.ambiguities.length}"}),
        ),
      );
    }
  }

  /// Writes [record] back to its active `record.json` via [_persistRecordJson].
  void _persist(CharaDetailRecord record) => _persistRecordJson(recordPathOf(record), record);

  void addFromFile(String id) {
    final result = CharaDetailRecord.load(rootDirectory / id);
    switch (result) {
      case RecordLoaded(:final record):
        add(record);
      case RecordQuarantined():
        _surfaceQuarantines(ref, [result]);
    }
  }

  @override
  CharaDetailRecord? getBy({required String id}) {
    return _records.firstWhereOrNull((e) => e.id == id);
  }

  void replaceBy(CharaDetailRecord record, {required String id}) {
    // Accumulate into a private buffer instead of mutating the list held by the
    // live AsyncData. reload() replaces records silently during regeneration;
    // the grid only rebuilds once forceRebuild() publishes the buffer.
    final records = _pendingRecords ??= [...state.requireValue];
    final index = records.indexWhere((e) => e.id == id);
    if (index == -1) {
      // The record was removed (e.g. deleted) during the async reload; skip.
      return;
    }
    records[index] = record;
  }

  DirectoryPath recordPathOf(CharaDetailRecord record) {
    return rootDirectory / record.id;
  }

  FilePath imagePathOf(CharaDetailRecord record, CharaDetailRecordImageMode image) {
    assert(image != CharaDetailRecordImageMode.none);
    return recordPathOf(record).filePath(image.fileName);
  }

  FilePath traineeIconPathOf(CharaDetailRecord record) {
    return rootDirectory.filePath(record.traineeIconPath);
  }

  void copyToClipboard(CharaDetailRecord record, CharaDetailRecordImageMode image) {
    assert(image != CharaDetailRecordImageMode.none);
    final imagePath = imagePathOf(record, image);
    // Fire-and-forget: pasteImage reports its own outcome via a toast. unawaited
    // makes the intent explicit so a future async failure isn't silently dropped.
    unawaited(ClipboardAlt.pasteImage(ref.base, imagePath));
  }

  List<CharaDetailRecord> get records => _records;

  Future<void> checkRecordVersion({bool includeCurrentVersion = false}) {
    return _checkRecordVersion(_records, includeCurrentVersion: includeCurrentVersion);
  }

  // Takes the loaded records explicitly because build() calls this before the
  // notifier's state has been published.
  Future<void> _checkRecordVersion(List<CharaDetailRecord> records, {bool includeCurrentVersion = false}) async {
    final moduleVersion = await ref.read(moduleVersionLoader.future);
    if (moduleVersion == null) {
      return Future.value();
    }
    final obsoletedRecords = records.where((r) {
      return r.isObsoleted(moduleVersion, includeCurrentVersion) && r.isSupported(moduleVersion);
    }).toList();
    if (obsoletedRecords.isEmpty) {
      return Future.value();
    }
    ref.read(charaDetailRecordRegenerationControllerProvider.notifier).start(obsoletedRecords);
  }

  Future<void> reload(String id) async {
    final result = await compute(_loadCharaDetailRecord, rootDirectory / id);
    switch (result) {
      case RecordLoaded(:final record):
        replaceBy(record, id: id);
      case RecordQuarantined():
        _surfaceQuarantines(ref, [result]);
    }
  }

  @override
  void delete(String id) {
    // Deleting a record does not clear other records' parentN links to it.
    // Inheritance resolution is additive and never clears links (see
    // InheritanceResolver), so the dangling id persists, but it is harmless:
    // relationBonus / resolveRegisteredAncestors resolve a missing id to null
    // and it contributes nothing.
    final record = getBy(id: id);
    // Guard rather than assert: the record can vanish between a dialog opening
    // and its confirm (a background capture reload, or an archive of the same
    // id), and asserts are stripped in release builds, so `record!` would throw.
    if (record == null) {
      return;
    }
    recordPathOf(record).deleteSyncSafeWithCheck();
    removeRecords([id]);
  }

  /// Permanently deletes every record in [ids], erasing each directory then
  /// republishing once via [removeRecords] (instead of per id).
  @override
  void deleteAll(Iterable<String> ids) {
    for (final id in ids) {
      final record = getBy(id: id);
      if (record == null) {
        continue;
      }
      recordPathOf(record).deleteSyncSafeWithCheck();
    }
    removeRecords(ids);
  }

  /// Drops [ids] from the in-memory record set and republishes once.
  ///
  /// Used by [delete] (after erasing a directory) and by the archive flow (after
  /// moving directories out of `active/`). Like [delete] it stages the filtered
  /// list in the buffer and lets [forceRebuild] publish it a single time
  /// (rebuilding the card map), instead of emitting state per id.
  void removeRecords(Iterable<String> ids) {
    final idSet = ids.toSet();
    _pendingRecords = _records.where((e) => !idSet.contains(e.id)).toList();
    forceRebuild();
  }

  void forceRebuild() {
    final records = _records;
    _pendingRecords = null;
    charaCardMap.clear();
    for (final e in records) {
      _updateRecordInfo(e);
    }
    state = AsyncData([...records]);
  }
}

RecordLoadResult _loadCharaDetailRecord(DirectoryPath directory) {
  initializeMappers();
  return CharaDetailRecord.load(directory);
}

List<RecordLoadResult> _loadAllCharaDetailRecord(DirectoryPath directory) {
  initializeMappers();
  return directory
      .listSync(recursive: false, followLinks: false)
      .map((e) => CharaDetailRecord.load(e.asDirectoryPath))
      .toList();
}

/// Shows a single aggregated toast for records quarantined during a load.
///
/// Runs on the main isolate so every load path surfaces the outcome: the bulk
/// startup load and [CharaDetailRecordStorage.reload] run [CharaDetailRecord.load]
/// inside a `compute` isolate, where `Toaster.show` would be a no-op. Shared by
/// both the active and archive storages, which each call [CharaDetailRecord.load]
/// (the latter via [_loadAllCharaDetailRecord]) and so can both trigger a
/// quarantine move that must be reported.
void _surfaceQuarantines(Ref ref, List<RecordQuarantined> quarantined) {
  if (quarantined.isEmpty) {
    return;
  }
  final destinations = quarantined.map((e) => e.destination).whereType<DirectoryPath>().toList();
  final failed = quarantined.length - destinations.length;
  if (destinations.isNotEmpty) {
    // All quarantined records share the same quarantine folder; tapping the
    // toast opens it in the file explorer so the user can inspect/recover them.
    final quarantineDir = destinations.first.parent;
    Toaster.show(
      ToastData.warning(
        description: "app.record_quarantined".tr(namedArgs: {"count": "${destinations.length}"}),
        onTap: () => quarantineDir.launch(),
      ),
    );
    // Refresh the persistent banner on the chara_detail tab.
    ref.invalidate(charaDetailQuarantineCountProvider);
  }
  if (failed > 0) {
    Toaster.show(ToastData.error(description: "app.record_quarantine_error".tr(namedArgs: {"count": "$failed"})));
  }
}

final charaDetailRecordStorageLoaderProvider = AsyncNotifierProvider<CharaDetailRecordStorage, List<CharaDetailRecord>>(
  CharaDetailRecordStorage.new,
);

// Thin synchronous view over the loaded records, so the many `ref.watch(...)`
// call sites keep receiving a plain List. Mutating callers use
// charaDetailRecordStorageLoaderProvider.notifier instead.
final charaDetailRecordStorageProvider = Provider<List<CharaDetailRecord>>((ref) {
  return ref.watch(charaDetailRecordStorageLoaderProvider).requireValue;
});

/// Storage for the archived records under `chara_detail/archive/`.
///
/// Deliberately minimal: unlike [CharaDetailRecordStorage] it registers no
/// capture listener and runs no version check, so archived records are
/// structurally excluded from re-recognition. They are, however, included in
/// capture-time and manual inheritance resolution and in capture dedup: the
/// active store reads this set as extra candidates and writes back any archived
/// record whose parent links change via [applyInheritanceUpdates].
class CharaDetailArchiveStorage extends AsyncNotifier<List<CharaDetailRecord>> implements CharaDetailRecordMutator {
  late DirectoryPath rootDirectory;

  @override
  Future<List<CharaDetailRecord>> build() async {
    final pathInfo = await ref.watch(pathInfoLoader.future);
    rootDirectory = pathInfo.charaDetailArchiveDir;
    if (!rootDirectory.existsSync()) {
      return [];
    }
    final results = await compute(_loadAllCharaDetailRecord, rootDirectory);
    // Loading a corrupt archived record quarantines its directory as a side
    // effect; surface that like the active storage does, rather than silently
    // dropping it (and leaving the count inconsistent).
    _surfaceQuarantines(ref, results.whereType<RecordQuarantined>().toList());
    return results.whereType<RecordLoaded>().map((e) => e.record).toList();
  }

  DirectoryPath recordPathOf(CharaDetailRecord record) => rootDirectory / record.id;

  @override
  CharaDetailRecord? getBy({required String id}) {
    return state.asData?.value.firstWhereOrNull((e) => e.id == id);
  }

  /// Writes [record] back to its archived `record.json` via [_persistRecordJson].
  void _persist(CharaDetailRecord record) => _persistRecordJson(recordPathOf(record), record);

  /// Persists inheritance-updated archived [records] and swaps them into the
  /// in-memory list by id.
  ///
  /// Called by the active store's capture-time and manual inheritance resolution
  /// when an archived record's parent links change. A no-op for an empty list.
  /// Disk is always updated; the in-memory swap is skipped only if the archive
  /// view never loaded (the next build reads the updated json from disk).
  void applyInheritanceUpdates(List<CharaDetailRecord> records) {
    if (records.isEmpty) {
      return;
    }
    for (final record in records) {
      _persist(record);
    }
    final current = state.asData?.value;
    if (current == null) {
      return;
    }
    final byId = {for (final record in records) record.id: record};
    state = AsyncData([for (final e in current) byId[e.id] ?? e]);
  }

  /// Appends just-archived [records] to the in-memory list, mirroring the active
  /// store's [CharaDetailRecordStorage.removeRecords].
  ///
  /// Used by the archive flow instead of invalidating (and re-scanning every
  /// archived directory from disk). No-op when the archive view has never been
  /// loaded — the next build reads the moved directories straight from disk.
  void insert(List<CharaDetailRecord> records) {
    final current = state.asData?.value;
    if (current == null) {
      return;
    }
    state = AsyncData([...current, ...records]);
  }

  /// Permanently deletes an archived record's directory and republishes.
  @override
  void delete(String id) {
    final records = state.asData?.value;
    if (records == null) {
      return;
    }
    final record = records.firstWhereOrNull((e) => e.id == id);
    if (record == null) {
      return;
    }
    recordPathOf(record).deleteSyncSafeWithCheck();
    state = AsyncData(records.where((e) => e.id != id).toList());
  }

  /// Permanently deletes every archived record in [ids], erasing each directory
  /// then republishing the filtered set once.
  @override
  void deleteAll(Iterable<String> ids) {
    final records = state.asData?.value;
    if (records == null) {
      return;
    }
    final idSet = ids.toSet();
    for (final record in records.where((e) => idSet.contains(e.id))) {
      recordPathOf(record).deleteSyncSafeWithCheck();
    }
    state = AsyncData(records.where((e) => !idSet.contains(e.id)).toList());
  }
}

final charaDetailArchiveStorageLoaderProvider =
    AsyncNotifierProvider<CharaDetailArchiveStorage, List<CharaDetailRecord>>(CharaDetailArchiveStorage.new);

/// A one-shot request to focus (highlight and scroll to) a record in the table, set to the record id
/// to focus. The table consumes it once (on load or on change) and resets it to null. Used when the
/// capture screen navigates to the table on a duplicate, to point at the existing record.
final charaDetailFocusRecordProvider = settableNotifierProvider<String?>(null);

/// The record list the table should display, following [recordSourceProvider].
///
/// The two sources are never shown together; this picks one. The grid watches
/// this instead of [charaDetailRecordStorageProvider] directly.
final displayedRecordsProvider = Provider<List<CharaDetailRecord>>((ref) {
  switch (ref.watch(recordSourceProvider)) {
    case RecordSource.active:
      return ref.watch(charaDetailRecordStorageProvider);
    case RecordSource.archive:
      return ref.watch(charaDetailArchiveStorageLoaderProvider).asData?.value ?? const [];
  }
});

/// Active and archive records merged into one id->record lookup, for ancestry
/// resolution that must reach across both sets (an ancestor may live in either,
/// regardless of which set the table currently displays).
///
/// Falls back to active-only while the archive is still loading (build() starts
/// it without awaiting), so callers degrade gracefully; the lookup refreshes
/// once the archive lands. Active wins on the (normally impossible) id clash.
final allRecordsByIdProvider = Provider<Map<String, CharaDetailRecord>>((ref) {
  final active = ref.watch(charaDetailRecordStorageProvider);
  final archive = ref.watch(charaDetailArchiveStorageLoaderProvider).asData?.value ?? const <CharaDetailRecord>[];
  return {for (final record in archive) record.id: record, for (final record in active) record.id: record};
});

/// The `read`-based counterpart of [displayedRecordsProvider] for a fixed
/// [source].
///
/// Used by the export flow, which snapshots the source at confirm time so a
/// later source switch cannot redirect an in-flight write to the other set.
List<CharaDetailRecord> recordsForSource(RefBase ref, RecordSource source) {
  switch (source) {
    case RecordSource.active:
      return ref.read(charaDetailRecordStorageProvider);
    case RecordSource.archive:
      return ref.read(charaDetailArchiveStorageLoaderProvider).asData?.value ?? const [];
  }
}

/// The [CharaDetailRecordMutator] backing [source].
///
/// Centralizes the active-vs-archive notifier choice so delete/export call sites
/// dispatch once instead of repeating the `source == active ? ... : ...` branch.
CharaDetailRecordMutator recordStorageFor(WidgetRef ref, RecordSource source) {
  switch (source) {
    case RecordSource.active:
      return ref.read(charaDetailRecordStorageLoaderProvider.notifier);
    case RecordSource.archive:
      return ref.read(charaDetailArchiveStorageLoaderProvider.notifier);
  }
}

/// Leaves bulk-selection mode: drops the purpose and clears the checked ids.
///
/// The two providers are semantically coupled (a non-null purpose without a
/// checked set, or vice versa, is meaningless), so every exit path resets both
/// through here rather than repeating the pair.
void exitSelection(WidgetRef ref) {
  ref.read(selectionModeProvider.notifier).set(null);
  ref.read(selectedRecordIdsProvider.notifier).set(<String>{});
}

/// Switches the displayed [source] and clears any in-progress selection.
///
/// The two are coupled: checked ids belong to the source they were checked in,
/// so leaving them set would leak a stale selection across the switch (and a
/// confirm could target ids absent from the new source). Routing every source
/// switch through here keeps that invariant in one place.
void setRecordSource(WidgetRef ref, RecordSource source) {
  ref.read(recordSourceProvider.notifier).set(source);
  exitSelection(ref);
}

/// Drives the bulk-archive operation and exposes its [Progress] for the UI.
///
/// Like [CharaDetailRecordRegenerationController] it sets a non-empty [Progress]
/// while running and resets to [Progress.none] when done, so the table shows the
/// same circular indicator. The whole batch runs in one isolate (no per-record
/// callback), so the indicator stays a busy marker rather than advancing a count.
class CharaArchiveController extends Notifier<Progress> {
  @override
  Progress build() => Progress.none;

  Future<void> archive(List<String> ids, ArchiveImageOption option) async {
    if (ids.isEmpty) {
      return;
    }
    final pathInfo = await ref.read(pathInfoLoader.future);
    final activeRoot = pathInfo.charaDetailActiveDir;
    final archiveRoot = pathInfo.charaDetailArchiveDir;
    // Whole-batch busy state: one isolate handles every record, so there is no
    // per-record callback to advance a percentage. Mark it indeterminate so the
    // indicator spins rather than sitting frozen at 0%.
    state = Progress(total: ids.length, indeterminate: true);
    // Snapshot the to-be-archived records before they leave the active store, so
    // the archive store can be updated in memory (see below) without a re-scan.
    final activeStore = ref.read(charaDetailRecordStorageLoaderProvider.notifier);
    final archivedRecordsById = {for (final id in ids) id: activeStore.getBy(id: id)};
    // Move every selected record in a single isolate, rather than spawning one
    // per record. The args stay aligned with [ids] so the result bools map back
    // by index.
    final items = [for (final id in ids) ArchiveRecordArgs((activeRoot / id).path, (archiveRoot / id).path, option)];
    final results = await compute(archiveRecordsInIsolate, ArchiveBatchArgs(items));
    final archived = <String>[];
    var failed = 0;
    for (var i = 0; i < ids.length; i++) {
      if (results[i]) {
        archived.add(ids[i]);
      } else {
        failed++;
      }
    }
    if (archived.isNotEmpty) {
      ref.read(charaDetailRecordStorageLoaderProvider.notifier).removeRecords(archived);
      // Move the records into the archive store in memory, mirroring the active
      // store's surgical removal, instead of invalidating and re-scanning every
      // archived directory from disk. A no-op if the archive view never loaded.
      final archivedRecords = [for (final id in archived) archivedRecordsById[id]].nonNulls.toList();
      ref.read(charaDetailArchiveStorageLoaderProvider.notifier).insert(archivedRecords);
    }
    state = Progress.none;
    if (archived.isNotEmpty) {
      Toaster.show(
        ToastData.success(
          description: "pages.chara_detail.archive_records.success".tr(namedArgs: {"count": "${archived.length}"}),
        ),
      );
    }
    if (failed > 0) {
      Toaster.show(
        ToastData.error(description: "pages.chara_detail.archive_records.error".tr(namedArgs: {"count": "$failed"})),
      );
    }
  }
}

final charaArchiveControllerProvider = NotifierProvider<CharaArchiveController, Progress>(CharaArchiveController.new);

/// Arguments for [archiveRecordInIsolate], crossing the `compute` boundary as
/// plain strings plus the chosen [ArchiveImageOption].
class ArchiveRecordArgs {
  final String srcDirPath;
  final String dstDirPath;
  final ArchiveImageOption option;

  const ArchiveRecordArgs(this.srcDirPath, this.dstDirPath, this.option);
}

/// Arguments for [archiveRecordsInIsolate]: a whole batch of per-record moves.
class ArchiveBatchArgs {
  final List<ArchiveRecordArgs> items;

  const ArchiveBatchArgs(this.items);
}

/// Archives every record in [ArchiveBatchArgs.items] inside a single isolate,
/// returning a per-item success flag aligned with the input order.
///
/// Batching avoids spawning one `compute` isolate per record (heavy on Windows).
/// Each item is independent and best-effort via [archiveRecordInIsolate], so one
/// record's failure neither aborts the batch nor shifts the result indices.
List<bool> archiveRecordsInIsolate(ArchiveBatchArgs args) {
  return [for (final item in args.items) archiveRecordInIsolate(item)];
}

/// Moves a single record's directory into the archive, then disposes of its
/// recognition images, returning whether the record was archived.
///
/// Runs inside a `compute` isolate (image decoding/encoding and a directory
/// rename are all off the UI thread), but is also a plain top-level function so
/// it can be unit-tested directly. The record's `record.json` and `trainee.jpg`
/// are left untouched; the recognition images, their geometry `*.json`, and the
/// large `prediction.json` are dropped or rewritten by [_disposeArchivedImages].
///
/// The move happens first, before any file is touched: if the rename fails (a
/// Windows file lock, a stale destination, …) the source is left completely
/// intact rather than already stripped of its images. Once the move succeeds the
/// record is archived, so the subsequent image disposition is best-effort — a
/// failure there is logged but does not flip the result back to a (misleading)
/// failure that would leave the in-memory active set out of sync with disk.
bool archiveRecordInIsolate(ArchiveRecordArgs args) {
  try {
    final srcDir = DirectoryPath(args.srcDirPath);
    if (!srcDir.existsSync()) {
      return false;
    }
    // A pre-existing destination (a leftover from an interrupted archive of the
    // same id) makes the rename throw on Windows and report an opaque failure.
    // Detect it explicitly so the cause is logged instead of being swallowed.
    if (DirectoryPath(args.dstDirPath).existsSync()) {
      logger.e("Cannot archive ${args.srcDirPath}: destination ${args.dstDirPath} already exists.");
      return false;
    }
    final dstDir = srcDir.moveSyncSafe(DirectoryPath(args.dstDirPath));
    if (dstDir == null) {
      // Move failed; the active record is untouched. Report failure so the
      // caller keeps it in the active set.
      return false;
    }
    _disposeArchivedImages(dstDir, args.option);
    return true;
  } catch (error, stackTrace) {
    logger.e("Failed to archive record ${args.srcDirPath}.", error, stackTrace);
    return false;
  }
}

/// Disposes of an already-archived record's recognition data in [recordDir]:
/// always drops the large `prediction.json`; for [ArchiveImageOption.resizedJpeg]
/// downscales the PNGs to JPEGs and rescales their geometry json to match; for
/// [ArchiveImageOption.none] drops the images and their geometry json.
///
/// Best-effort: any failure is logged and swallowed, because the record has
/// already been moved into the archive and must not be reported as a failed
/// archive over a mere image-cleanup hiccup.
void _disposeArchivedImages(DirectoryPath recordDir, ArchiveImageOption option) {
  const imageModes = [
    CharaDetailRecordImageMode.skillPlain,
    CharaDetailRecordImageMode.factorPlain,
    CharaDetailRecordImageMode.campaignPlain,
  ];
  try {
    // The recognition overlay data (prediction.json) is large and the overlay is
    // not offered for archived records, so drop it regardless of the image option.
    recordDir.filePath("prediction.json").deleteSync(emptyOk: true);
    if (option == ArchiveImageOption.resizedJpeg) {
      // Convert each present PNG to a JPEG, keeping the mode alongside each pair so
      // the conversion result (the JPEG's pixel size) can be matched back to the
      // right geometry json afterwards.
      final modes = <CharaDetailRecordImageMode>[];
      final srcs = <String>[];
      final dsts = <String>[];
      for (final mode in imageModes) {
        final png = recordDir.filePath(mode.fileName);
        if (png.existsSync()) {
          modes.add(mode);
          srcs.add(png.path);
          dsts.add(recordDir.filePath(mode.fileName.replaceAll(".png", ".jpg")).path);
        }
      }
      final results = srcs.isEmpty ? const <ImageConvertResult?>[] : convertPngBatch(ImageConvertArgs(srcs, dsts));
      for (var i = 0; i < modes.length; i++) {
        final mode = modes[i];
        // Only drop a PNG once its JPEG exists, so a failed conversion keeps the
        // original rather than losing the image entirely.
        if (recordDir.filePath(mode.fileName.replaceAll(".png", ".jpg")).existsSync()) {
          recordDir.filePath(mode.fileName).deleteSync(emptyOk: true);
        }
        // Rescale the geometry json to the (possibly downscaled) JPEG so the
        // preview's layout box matches the image to the pixel instead of leaving
        // the original capture size that produces gaps.
        final result = i < results.length ? results[i] : null;
        if (result != null) {
          scaleIntersectionJson(
            recordDir.filePath(mode.fileName.replaceAll(".png", ".json")),
            newWidth: result.dstWidth,
            newHeight: result.dstHeight,
          );
        }
      }
    } else {
      // Drop the images and their geometry json together: an image-less archive
      // has no use for the layout metadata, and the preview treats a missing image
      // as the neutral "no image" case rather than a load error.
      for (final mode in imageModes) {
        recordDir.filePath(mode.fileName).deleteSync(emptyOk: true);
        recordDir.filePath(mode.fileName.replaceAll(".png", ".json")).deleteSync(emptyOk: true);
      }
    }
  } catch (error, stackTrace) {
    logger.e("Failed to dispose archived images in ${recordDir.path}.", error, stackTrace);
  }
}

/// One-time repair of records archived before geometry json was kept in sync with
/// the downscaled image.
///
/// Older archives carry a `prediction.json` and a geometry `*.json` written at the
/// original capture resolution, while the archived `*.jpg` was downscaled to
/// <=720px. The preview then sizes its layout box from the stale json and draws
/// the smaller image with gaps. This brings each archived record in line with the
/// current [_disposeArchivedImages] behaviour:
///
/// - drop `prediction.json` (large, unused for archived records);
/// - for each tab, if an image exists, rescale its geometry json to the image's
///   actual pixel size; if no image exists, drop the now-useless geometry json.
///
/// Best-effort and idempotent: a record already in the target state is left
/// effectively unchanged, so a re-run (or a partially-completed prior run) is safe.
void _migrateArchivedRecord(DirectoryPath recordDir) {
  const imageModes = [
    CharaDetailRecordImageMode.skillPlain,
    CharaDetailRecordImageMode.factorPlain,
    CharaDetailRecordImageMode.campaignPlain,
  ];
  try {
    recordDir.filePath("prediction.json").deleteSync(emptyOk: true);
    for (final mode in imageModes) {
      final jsonFile = recordDir.filePath(mode.fileName.replaceAll(".png", ".json"));
      final image = resolveImagePath(recordDir, mode);
      if (image == null) {
        jsonFile.deleteSync(emptyOk: true);
        continue;
      }
      final size = readImageSize(image);
      if (size != null) {
        scaleIntersectionJson(jsonFile, newWidth: size.width, newHeight: size.height);
      }
    }
  } catch (error, stackTrace) {
    logger.e("Failed to migrate archived record ${recordDir.path}.", error, stackTrace);
  }
}

/// Runs [_migrateArchivedRecord] over every record directory under the archive
/// root at [archiveDirPath], returning the number of records visited.
///
/// A plain top-level function so it can run inside a `compute` isolate (file I/O
/// and image-header reads off the UI thread) and be unit-tested directly.
int migrateArchivedRecordsInIsolate(String archiveDirPath) {
  final archiveDir = DirectoryPath(archiveDirPath);
  if (!archiveDir.existsSync()) {
    return 0;
  }
  final dirs = archiveDir.listSync(recursive: false, followLinks: false);
  for (final entry in dirs) {
    _migrateArchivedRecord(entry.asDirectoryPath);
  }
  return dirs.length;
}

/// Hive key marking the one-time archive geometry/prediction cleanup as done.
const _archiveGeometryMigrationKey = "chara_detail_archive_geometry_v1";

/// Runs the one-time [migrateArchivedRecordsInIsolate] cleanup the first time
/// only, recording completion so later launches skip the archive scan.
///
/// The migration itself is idempotent, so the flag is purely an optimization: a
/// missing flag (or a crash before it is set) just re-runs a harmless pass.
Future<void> runArchiveGeometryMigrationIfNeeded(PathInfo pathInfo) async {
  final entry = StorageBox(StorageBoxKey.dataMigration).entry<bool>(_archiveGeometryMigrationKey);
  if (entry.pull() == true) {
    return;
  }
  final count = await compute(migrateArchivedRecordsInIsolate, pathInfo.charaDetailArchiveDir.path);
  logger.i("Archive geometry migration visited $count archived record(s).");
  entry.push(true);
}

/// Number of records currently sitting in the quarantine folder.
///
/// Read from the filesystem, so it also reflects records quarantined in earlier
/// sessions (which are never re-scanned from `active/`). [CharaDetailRecordStorage]
/// invalidates this when it quarantines records at runtime so the banner updates.
final charaDetailQuarantineCountProvider = Provider<int>((ref) {
  final dir = ref.watch(pathInfoProvider).charaDetailQuarantineDir;
  if (!dir.existsSync()) {
    return 0;
  }
  return dir.listSync(recursive: false, followLinks: false).length;
});
