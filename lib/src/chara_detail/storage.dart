import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/chara_detail_record.dart';
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
    // Always increment, even if the reload fails: completion is gated on the
    // count reaching the total, so a single failed reload would otherwise leave
    // the progress stuck forever and never reset to Progress.none.
    try {
      await ref.read(charaDetailRecordStorageLoaderProvider.notifier).reload(id);
    } catch (e, s) {
      logger.w("Failed to reload regenerated record $id: $e\n$s");
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

class CharaDetailRecordStorage extends AsyncNotifier<List<CharaDetailRecord>> {
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
      _surfaceQuarantines(results.whereType<RecordQuarantined>().toList());
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
    return charaCardMap.map((k, v) => MapEntry(k, (rootDirectory / v.id).filePath("trainee.jpg")));
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
        _surfaceQuarantines([result]);
    }
  }

  /// Shows a single aggregated toast for records quarantined during a load.
  ///
  /// Centralized here on the main isolate so every load path surfaces the
  /// outcome: the bulk startup load and [reload] run [CharaDetailRecord.load]
  /// inside a `compute` isolate, where `Toaster.show` would be a no-op.
  void _surfaceQuarantines(List<RecordQuarantined> quarantined) {
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
        _surfaceQuarantines([result]);
    }
  }

  void delete(String id) {
    final record = getBy(id: id);
    assert(record != null);
    final directory = recordPathOf(record!);
    directory.deleteSyncSafeWithCheck();
    // Stage the filtered list in the buffer and let forceRebuild() publish it
    // once (rebuilding the card map), instead of emitting state twice.
    _pendingRecords = _records.where((e) => e != record).toList();
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

final charaDetailRecordStorageLoaderProvider = AsyncNotifierProvider<CharaDetailRecordStorage, List<CharaDetailRecord>>(
  CharaDetailRecordStorage.new,
);

// Thin synchronous view over the loaded records, so the many `ref.watch(...)`
// call sites keep receiving a plain List. Mutating callers use
// charaDetailRecordStorageLoaderProvider.notifier instead.
final charaDetailRecordStorageProvider = Provider<List<CharaDetailRecord>>((ref) {
  return ref.watch(charaDetailRecordStorageLoaderProvider).requireValue;
});

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
