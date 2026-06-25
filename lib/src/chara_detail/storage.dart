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
import '/src/core/clipboard_alt.dart';
import '/src/core/mapper_init.dart';
import '/src/core/path_entity.dart';
import '/src/core/platform_controller.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/capture.dart';
import '/src/gui/toast.dart';

part 'storage.mapper.dart';

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
    // to each newly captured record id.
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

  void add(CharaDetailRecord record) {
    final records = _records;
    final duplicated = records.firstWhereOrNull((e) => record.isSameChara(e));
    if (duplicated != null && duplicated.id != record.id) {
      (rootDirectory / record.id).deleteSyncWithCheck(recursive: true);
      _duplicatedCharaEvent.add(_duplicatedCharaEventSequence++);
      ref.read(charaDetailCaptureStateProvider.notifier).fail("duplicated_character");
      return;
    }

    // Link this record to existing parents/children by matching factors and
    // card, then persist any record.json (this record and/or existing children)
    // whose parent ids changed.
    final resolution = InheritanceResolver.resolveForNewRecord(record, records);
    final resolvedRecord = resolution.changed.firstWhereOrNull((e) => e.id == record.id) ?? record;
    final childUpdates = {for (final e in resolution.changed.where((e) => e.id != record.id)) e.id: e};
    for (final updated in resolution.changed) {
      _persist(updated);
    }
    _updateRecordInfo(resolvedRecord);

    // `records` already folds in any pending batch updates, so publishing it
    // and clearing the buffer keeps the next replaceBy re-snapshotting cleanly.
    // Drop any existing entry with the same id so re-adding a record (same id)
    // replaces it instead of appending a duplicate.
    _pendingRecords = null;
    state = AsyncData([
      for (final e in records)
        if (e.id != resolvedRecord.id) childUpdates[e.id] ?? e,
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
  /// Unlike the per-capture resolution, this is authoritative: it both sets and
  /// clears links so the whole storage reflects the current matches. Records
  /// whose links change are rewritten to disk and republished.
  void resolveAllInheritance() {
    final resolution = InheritanceResolver.resolveAll(_records);
    for (final updated in resolution.changed) {
      _persist(updated);
      replaceBy(updated, id: updated.id);
    }
    forceRebuild();
    _surfaceInheritance(resolution, alwaysReport: true);
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

  /// Writes [record] back to its `record.json`, matching the on-disk format
  /// (4-space indent) that the native recognizer and the exporter produce.
  void _persist(CharaDetailRecord record) {
    recordPathOf(
      record,
    ).filePath("record.json").writeAsStringSync(const JsonEncoder.withIndent('    ').convert(record.toMap()));
  }

  void addFromFile(String id) {
    final result = CharaDetailRecord.load(rootDirectory / id);
    switch (result) {
      case RecordLoaded(:final record):
        add(record);
      case RecordQuarantined():
        _surfaceQuarantines(ref, [result]);
    }
  }

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

  void delete(String id) {
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

/// Read-only view over the archived records under `chara_detail/archive/`.
///
/// Deliberately minimal: unlike [CharaDetailRecordStorage] it registers no
/// capture listener, runs no version check, and builds no card/inheritance maps.
/// That keeps capture, dedup, and re-recognition bound exclusively to the active
/// set, so archived records are structurally excluded from re-recognition.
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

  CharaDetailRecord? getBy({required String id}) {
    return state.asData?.value.firstWhereOrNull((e) => e.id == id);
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
/// it can be unit-tested directly. The record's `record.json`, `trainee.jpg`,
/// and image geometry `*.json` are left untouched; only the recognition PNGs are
/// dropped or replaced.
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

/// Drops or downscales the recognition PNGs of an already-archived record in
/// [recordDir]. Best-effort: any failure is logged and swallowed, because the
/// record has already been moved into the archive and must not be reported as a
/// failed archive over a mere image-cleanup hiccup.
void _disposeArchivedImages(DirectoryPath recordDir, ArchiveImageOption option) {
  const imageModes = [
    CharaDetailRecordImageMode.skillPlain,
    CharaDetailRecordImageMode.factorPlain,
    CharaDetailRecordImageMode.campaignPlain,
  ];
  try {
    if (option == ArchiveImageOption.resizedJpeg) {
      final srcs = <String>[];
      final dsts = <String>[];
      for (final mode in imageModes) {
        final png = recordDir.filePath(mode.fileName);
        if (png.existsSync()) {
          srcs.add(png.path);
          dsts.add(recordDir.filePath(mode.fileName.replaceAll(".png", ".jpg")).path);
        }
      }
      if (srcs.isNotEmpty) {
        convertPngBatch(ImageConvertArgs(srcs, dsts));
      }
      // Only drop a PNG once its JPEG exists, so a failed conversion keeps the
      // original rather than losing the image entirely.
      for (final mode in imageModes) {
        if (recordDir.filePath(mode.fileName.replaceAll(".png", ".jpg")).existsSync()) {
          recordDir.filePath(mode.fileName).deleteSync(emptyOk: true);
        }
      }
    } else {
      for (final mode in imageModes) {
        recordDir.filePath(mode.fileName).deleteSync(emptyOk: true);
      }
    }
  } catch (error, stackTrace) {
    logger.e("Failed to dispose archived images in ${recordDir.path}.", error, stackTrace);
  }
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
