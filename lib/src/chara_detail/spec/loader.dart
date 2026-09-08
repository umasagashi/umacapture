import 'dart:async';

import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/spec_tree.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/mapper_init.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/toast.dart';

part 'loader.mapper.dart';

// ignore: constant_identifier_names
const tr_columns = "pages.chara_detail.columns";

final moduleInfoLoaders = FutureProvider((ref) async {
  return Future.wait([ref.watch(moduleVersionLoader.future)]).then((_) {
    return Future.wait([
      // Spread from [moduleFileLoaders] rather than listed here, so that list —
      // which the storage tab's invalidate table also reads — has a production
      // consumer and cannot fall behind the set of module files the app loads.
      ...moduleFileLoaders.map((loader) => ref.watch(loader.future)),
      // Not module files: these two read the user's own rating and memo stores,
      // and are awaited here only because the column specs below need them.
      ref.watch(charaDetailRecordRatingStorageDataLoader.future),
      ref.watch(charaDetailRecordMemoStorageDataLoader.future),
    ]).then((_) {
      return Future.wait([ref.watch(currentColumnSpecsLoaderProvider.future)]);
    });
  });
});

Future<T> _loadFromJson<T>(FilePath path) async {
  // Read through the FS backend (dart:io on desktop, OPFS on web) rather than a
  // direct dart:io File, which throws at runtime on web.
  final content = await path.readAsString();
  // Parse off the UI isolate on native platforms. Flutter's compute() already
  // executes on the current event loop on web, so callers need no platform gate.
  return compute(_decodeJson<T>, content);
}

T _decodeJson<T>(String content) {
  initializeMappers();
  return MapperContainer.globals.fromJson<T>(content);
}

final labelMapLoader = FutureProvider<LabelMap>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return _loadFromJson<Map<String, dynamic>>(
    path.modulesDir.filePath("labels.json"),
  ).then((e) => e.map((k, v) => MapEntry(k, List<String>.from(v)))).then((map) {
    // record_type maps to the app-side RecordType enum, so its labels come from
    // translations rather than the downloaded module. This keeps a newly added
    // RecordType (e.g. friend) labeled without waiting for a module update, and
    // avoids a range error when the module label list lags behind the enum.
    return {...map, LabelKeys.recordType: _recordTypeLabels()};
  });
});

List<String> _recordTypeLabels() {
  return RecordType.values.map((type) => "$tr_columns.record_type.values.${type.translationKey}".tr()).toList();
}

final labelMapProvider = Provider<LabelMap>((ref) {
  return ref.watch(labelMapLoader).value!;
});

final _skillInfoLoader = FutureProvider<List<SkillInfo>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return _loadFromJson<List<SkillInfo>>(
    path.modulesDir.filePath("skill_info.json"),
  ).then((e) => e.sortedBy<num>((e) => e.sortKey));
});

final skillInfoProvider = Provider<List<SkillInfo>>((ref) {
  return ref.watch(_skillInfoLoader).value!;
});

final availableSkillInfoProvider = Provider<List<SkillInfo>>((ref) {
  final records = ref.watch(charaDetailRecordStorageProvider);
  final ids = records.map((r) => r.skills.map((s) => s.id)).flattened.toSet();
  return ref.watch(skillInfoProvider).where((e) => ids.contains(e.sid)).toList();
});

final _skillTagLoader = FutureProvider<List<Tag>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return _loadFromJson<List<Tag>>(path.modulesDir.filePath("skill_tag.json"));
});

final skillTagProvider = Provider<List<Tag>>((ref) {
  return ref.watch(_skillTagLoader).value!;
});

final factorInfoLoader = FutureProvider<List<FactorInfo>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  final skillInfo = (await ref.watch(_skillInfoLoader.future)).toMap((e) => e.sid);
  return _loadFromJson<List<FactorInfo>>(path.modulesDir.filePath("factor_info.json"))
      .then((info) => info.map((e) => e.copyWith(skillInfo: skillInfo[e.skillSid])).toList())
      .then((e) => e.sortedBy<num>((e) => e.sortKey));
});

final factorInfoProvider = Provider<List<FactorInfo>>((ref) {
  return ref.watch(factorInfoLoader).value!;
});

final availableFactorInfoProvider = Provider<List<FactorInfo>>((ref) {
  final records = ref.watch(charaDetailRecordStorageProvider);
  final ids = records.map((r) => r.factors.flattened.map((f) => f.id)).flattened.toSet();
  return ref.watch(factorInfoProvider).where((e) => ids.contains(e.sid)).toList();
});

final _factorTagLoader = FutureProvider<List<Tag>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return _loadFromJson<List<Tag>>(path.modulesDir.filePath("factor_tag.json"));
});

final factorTagProvider = Provider<List<Tag>>((ref) {
  return ref.watch(_factorTagLoader).value!;
});

final charaRankBorderLoader = FutureProvider<List<int>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return _loadFromJson<List<int>>(path.modulesDir.filePath("rank_border.json"));
});

final charaRankBorderProvider = Provider<List<int>>((ref) {
  return ref.watch(charaRankBorderLoader).value!;
});

final _charaCardInfoLoader = FutureProvider<List<CharaCardInfo>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return _loadFromJson<List<CharaCardInfo>>(path.modulesDir.filePath("character_card_info.json"));
});

final charaCardInfoProvider = Provider<List<CharaCardInfo>>((ref) {
  return ref.watch(_charaCardInfoLoader).value!;
});

final raceTitleInfoLoader = FutureProvider<List<RaceTitleInfo>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return _loadFromJson<List<RaceTitleInfo>>(path.modulesDir.filePath("race_title_info.json"));
});

final raceTitleInfoProvider = Provider<List<RaceTitleInfo>>((ref) {
  return ref.watch(raceTitleInfoLoader).value!;
});

/// Every loader whose value was read out of a file in `modulesDir`.
///
/// **One list with two consumers, so it cannot go stale.** [moduleInfoLoaders]
/// awaits exactly these at startup, and the storage tab invalidates exactly these
/// after deleting something under `modules/` (the modules row of its table, in
/// `storage_delete_invalidation.dart`). A loader added to the boot batch is
/// therefore added to the invalidation table by the same edit; a second,
/// hand-kept list beside the delete path would instead be silently short by one,
/// and the symptom — one recognition table still showing data from a module set
/// the user just deleted — is not one anybody would trace back to a missing list
/// entry.
///
/// [moduleVersionLoader] is deliberately not a member: it gates the batch below
/// rather than joining it, because the files here are described by the version it
/// resolves.
final moduleFileLoaders = <FutureProvider<Object?>>[
  labelMapLoader,
  _skillInfoLoader,
  _skillTagLoader,
  factorInfoLoader,
  _factorTagLoader,
  charaRankBorderLoader,
  _charaCardInfoLoader,
  raceTitleInfoLoader,
];

// Resolves a grade tag (e.g. "grade_g1") to the sids of every race title that
// carries it. Memoized per grade and recomputed when [raceTitleInfoProvider]
// changes, so a grade-driven column automatically follows game-data updates.
final raceGradeSidProvider = Provider.family<Set<int>, String>((ref, grade) {
  return ref.watch(raceTitleInfoProvider).where((e) => e.tags.contains(grade)).map((e) => e.sid).toSet();
});

class AvailableCharaCardInfo {
  final CharaCardInfo cardInfo;
  final FilePath iconPath;

  AvailableCharaCardInfo(this.cardInfo, this.iconPath);
}

final availableCharaCardsProvider = Provider<List<AvailableCharaCardInfo>>((ref) {
  final iconMap = ref.watch(charaCardIconMapProvider);
  return ref
      .watch(charaCardInfoProvider)
      .where((e) => iconMap.containsKey(e.sid))
      .sortedBy<num>((e) => e.sortKey)
      .map((e) => AvailableCharaCardInfo(e, iconMap[e.sid]!))
      .toList();
});

/// Raised when a rating/memo mutation is asked to change storage whose load failed.
///
/// [AsyncValue.value] is null in two unrelated situations: while the first read is
/// still in flight, and after that read or its decode failed. The first is a window
/// of a few hundred ms that clears on its own, so dropping a change is defensible.
/// The second never clears - nothing re-reads the file for the rest of the session
/// (riverpod's automatic retry is disabled application-wide) - so answering it the
/// same way discards every rating and memo the user enters from then on, while the
/// column keeps rendering from the empty fallback as if the storage were simply new.
/// Refusing loudly is the point: the change cannot be saved, and the caller must not
/// carry on as though it had been.
class StorageLoadFailure implements Exception {
  StorageLoadFailure({required this.storage, required this.key, required this.attempt, required this.cause});

  /// Which storage kind failed, for the message only (`rating` / `memo`).
  final String storage;

  /// Storage file stem, i.e. the family argument of the failing controller.
  final String key;

  /// What the caller was trying to do, phrased for a log line.
  final String attempt;

  /// The error [CharaDetailRecordRatingController.build] (or the memo one) failed with.
  final Object cause;

  @override
  String toString() => "StorageLoadFailure: refused $attempt because $storage storage '$key' failed to load: $cause";
}

/// Reads and decodes one rating/memo storage file, reporting a failure where it happens.
///
/// The resulting `AsyncError` reports nothing by itself: no `ProviderObserver` is
/// registered, so an undecodable file would otherwise reach neither the log nor a
/// crash report - while every later change to that storage is refused.
///
/// **A file that is not there is not a failure, and [whenAbsent] is that answer.**
/// The caller's `exists()` check answers the ordinary "nothing rated yet" case, but
/// it cannot answer the racing one: the storage tab drops the owning controller
/// *before* it deletes the file (`runStorageDeleteSerialized`), so the rebuild that
/// invalidate starts can pass the check and then find the file gone by the time it
/// reads. Reporting that as a load failure sends the user a crash report for an
/// ordinary delete - and leaves the controller stuck on an `AsyncError`, which
/// [StorageLoadFailure] then refuses every later edit against.
///
/// **Only absence is silenced, and it is decided by asking the filesystem rather
/// than by classifying the exception.** A read can fail on either platform with a
/// type neither this layer nor `FsBackend` names (`PathNotFoundException` on io, a
/// `NotFoundError` `DOMException` on OPFS), so matching on the error would have to
/// enumerate both and would answer a third one wrongly. Re-probing `exists()`
/// states the thing that actually decides the answer: the file is gone, so empty
/// is what it holds. Everything else - a truncated or hand-edited JSON, a decode
/// that throws, an I/O error on a file that is still there - still goes to the log
/// and to Sentry exactly as before, because silencing those would show the user
/// "no ratings" for data that is still on disk.
Future<T> _readStorageFile<T>(
  FilePath path,
  String description,
  T Function(String json) decode, {
  required T Function() whenAbsent,
}) async {
  try {
    return decode(await path.readAsString());
  } catch (exception, stackTrace) {
    if (!await path.exists()) {
      logger.d("Skipped $description: path=${path.path} was removed while it was being read");
      return whenAbsent();
    }
    logger.e("Failed to load $description: path=${path.path}", exception, stackTrace);
    captureException(exception, stackTrace);
    rethrow;
  }
}

/// The error [state] is stuck on, or null when it holds a value or is still loading.
///
/// This is the single place that tells the two null-valued states apart, so no
/// caller has to re-derive the distinction (and none can get it subtly wrong). A
/// failed *re*load that still carries the previously loaded value is not stuck:
/// those contents are known, so both reading and persisting them stay correct.
Object? _loadFailureOf<T>(AsyncValue<T> state) {
  if (state.hasValue) {
    return null;
  }
  return switch (state) {
    AsyncError(:final error) => error,
    _ => null,
  };
}

/// The value a mutator may change, or null while [state] is still loading.
///
/// Throws [StorageLoadFailure] when the load failed instead of collapsing that into
/// the same null - see the class doc for why the two cases must not share an answer.
T? _dataForMutation<T>(AsyncValue<T> state, {required String storage, required String key, required String attempt}) {
  final failure = _loadFailureOf(state);
  if (failure != null) {
    throw StorageLoadFailure(storage: storage, key: key, attempt: attempt, cause: failure);
  }
  final value = state.value;
  if (value == null) {
    logger.w("Dropped $attempt: $storage storage $key has not finished loading.");
  }
  return value;
}

class _RatingDataWriter {
  final FilePath path;
  final RatingData data;

  _RatingDataWriter(this.path, this.data);

  static Future<void> _run(_RatingDataWriter arg) {
    initializeMappers();
    return arg.path.writeAsString(arg.data.toJson());
  }

  Future<void> run() {
    return compute(_RatingDataWriter._run, this);
  }
}

@MappableClass()
class RatingData with RatingDataMappable {
  final String title;
  final Map<String, double> data;

  RatingData({required this.title, required this.data});

  RatingData copyWith({String? title, Map<String, double>? data}) {
    return RatingData(title: title ?? this.title, data: data ?? this.data);
  }

  static RatingData get empty {
    return RatingData(title: "pages.chara_detail.columns.rating.title".tr(), data: {});
  }
}

class CharaDetailRecordRatingController extends AsyncNotifier<RatingData> {
  CharaDetailRecordRatingController(this.key);

  final String key;

  late FilePath path;

  @override
  Future<RatingData> build() async {
    // `path` is assigned synchronously (before the first await) so [save] is safe
    // the moment the controller starts building. The read is async so web can load
    // the ratings file from OPFS; on desktop it is a fast local-disk read.
    path = ref.watch(pathInfoProvider).charaDetailRatingDir.filePath("$key.json");
    return (await path.exists())
        ? await _readStorageFile(
            path,
            "rating storage $key",
            RatingDataMapper.fromJson,
            whenAbsent: () => RatingData.empty,
          )
        : RatingData.empty;
  }

  // The loaded data, or null while the async build is still in flight.
  //
  // Every mutator and [save] below early-returns on null. The rating column does
  // render before this resolves ([RatingColumnSpec.plutoColumn] falls back to
  // RatingData.empty), and an unrated cell is precisely the interactive one, so a
  // drag during the load window is reachable - and writing the fallback back out
  // would erase every rating in this storage file.
  //
  // A *failed* load is a different situation and throws instead of returning null;
  // see [StorageLoadFailure].
  RatingData? _dataFor(String attempt) => _dataForMutation(state, storage: "rating", key: key, attempt: attempt);

  // Mutates the live map in place to avoid rebuilding the data grid on every
  // rating change. [save] snapshots the map before handing it to the writer
  // isolate, so this in-place edit cannot race the serialization.
  void updateWithoutNotify(String recordId, double rating) {
    final data = _dataFor("a rating for $recordId");
    if (data == null) {
      return;
    }
    data.data[recordId] = rating;
  }

  // Named `updateRating` (not `update`) to avoid colliding with the inherited
  // `AsyncNotifier.update` modifier, which has an incompatible signature.
  void updateRating(String recordId, double rating) {
    final data = _dataFor("a rating for $recordId");
    if (data == null) {
      return;
    }
    state = AsyncData(data.copyWith(data: {...data.data, recordId: rating}));
  }

  void updateTitle(String title) {
    final data = _dataFor("a title change");
    if (data == null) {
      return;
    }
    state = AsyncData(data.copyWith(title: title));
  }

  void save() {
    final data = _dataFor("a save");
    if (data == null) {
      return;
    }
    _RatingDataWriter(path, data.copyWith(data: {...data.data})).run();
  }
}

class RatingStorageData {
  final String key;
  final String title;

  RatingStorageData({required this.key, required this.title});

  RatingStorageData copyWith({String? key, String? title}) {
    return RatingStorageData(key: key ?? this.key, title: title ?? this.title);
  }
}

Future<List<RatingStorageData>> _loadRatings(DirectoryPath directoryPath) async {
  initializeMappers();
  if (!await directoryPath.exists()) {
    return [];
  }
  final result = <RatingStorageData>[];
  await for (final e in directoryPath.list()) {
    try {
      final title = RatingDataMapper.fromJson(await e.asFilePath.readAsString()).title;
      result.add(RatingStorageData(key: e.stem, title: title));
    } catch (error, stackTrace) {
      logger.w("Skipping unreadable rating file: path=${e.asFilePath.path}", error, stackTrace);
    }
  }
  return result;
}

final charaDetailRecordRatingStorageDataLoader = FutureProvider<List<RatingStorageData>>((ref) {
  final path = ref.watch(pathInfoProvider).charaDetailRatingDir;
  return _loadRatings(path);
});

// Holds the list of rating/memo storage descriptors. Replaces the legacy
// StateProvider<List<T>>; [update] mirrors StateController.update so the dialog
// call sites keep their `(state) => newList` closures unchanged.
abstract class _StorageDataNotifier<T> extends Notifier<List<T>> {
  List<T> update(List<T> Function(List<T> state) cb) => state = cb(state);
}

class CharaDetailRecordRatingStorageDataNotifier extends _StorageDataNotifier<RatingStorageData> {
  @override
  List<RatingStorageData> build() => ref.watch(charaDetailRecordRatingStorageDataLoader).value!;
}

final charaDetailRecordRatingStorageDataProvider =
    NotifierProvider<CharaDetailRecordRatingStorageDataNotifier, List<RatingStorageData>>(
      CharaDetailRecordRatingStorageDataNotifier.new,
    );

final charaDetailRecordRatingProvider =
    AsyncNotifierProvider.family<CharaDetailRecordRatingController, RatingData, String>(
      CharaDetailRecordRatingController.new,
    );

class _MemoDataWriter {
  final FilePath path;
  final MemoData data;

  _MemoDataWriter(this.path, this.data);

  static Future<void> _run(_MemoDataWriter arg) {
    initializeMappers();
    return arg.path.writeAsString(arg.data.toJson());
  }

  Future<void> run() {
    return compute(_MemoDataWriter._run, this);
  }
}

@MappableClass()
class MemoData with MemoDataMappable {
  final String title;
  final Map<String, String> data;

  MemoData({required this.title, required this.data});

  MemoData copyWith({String? title, Map<String, String>? data}) {
    return MemoData(title: title ?? this.title, data: data ?? this.data);
  }

  static MemoData get empty {
    return MemoData(title: "pages.chara_detail.columns.memo.title".tr(), data: {});
  }
}

class CharaDetailRecordMemoController extends AsyncNotifier<MemoData> {
  CharaDetailRecordMemoController(this.key);

  final String key;

  late FilePath path;

  @override
  Future<MemoData> build() async {
    // `path` is assigned synchronously (before the first await) so [_save] is safe
    // the moment the controller starts building. The read is async so web can load
    // the memo file from OPFS; on desktop it is a fast local-disk read.
    path = ref.watch(pathInfoProvider).charaDetailMemoDir.filePath("$key.json");
    return (await path.exists())
        ? await _readStorageFile(path, "memo storage $key", MemoDataMapper.fromJson, whenAbsent: () => MemoData.empty)
        : MemoData.empty;
  }

  // The loaded data, or null while the async build is still in flight (see the
  // note on [CharaDetailRecordRatingController]: the mutators and [_save] must
  // never persist a value derived from the empty fallback). A failed load throws
  // [StorageLoadFailure] rather than sharing that null.
  MemoData? _dataFor(String attempt) => _dataForMutation(state, storage: "memo", key: key, attempt: attempt);

  // The empty fallback is safe while the load is in flight: it only labels a column
  // whose real title arrives with it. It is not safe once the load has *failed* -
  // answering with the default title there tells the reader the storage is empty,
  // when in truth its contents are unknown and every memo typed into the dialog this
  // title heads would be refused. That case throws [StorageLoadFailure] instead.
  String get title {
    final failure = _loadFailureOf(state);
    if (failure != null) {
      throw StorageLoadFailure(storage: "memo", key: key, attempt: "reading the title", cause: failure);
    }
    return state.value?.title ?? MemoData.empty.title;
  }

  void _update({required String recordId, required String memo, required MemoData data}) {
    state = AsyncData(data.copyWith(data: {...data.data, recordId: memo}));
  }

  void _remove({required String recordId, required MemoData data}) {
    state = AsyncData(data.copyWith(data: {...data.data}..remove(recordId)));
  }

  void updateTitle({required String title}) {
    final data = _dataFor("a title change");
    if (data == null) {
      return;
    }
    state = AsyncData(data.copyWith(title: title));
    _save();
  }

  void _save() {
    final data = _dataFor("a save");
    if (data == null) {
      return;
    }
    _MemoDataWriter(path, data.copyWith(data: {...data.data})).run();
  }

  // Named `updateMemo` (not `update`) to avoid colliding with the inherited
  // `AsyncNotifier.update` modifier, which has an incompatible signature.
  void updateMemo({required String recordId, required String? memo}) {
    final data = _dataFor("a memo for $recordId");
    if (data == null) {
      return;
    }
    if (memo == null || memo.isEmpty) {
      _remove(recordId: recordId, data: data);
    } else {
      _update(recordId: recordId, memo: memo, data: data);
    }
    _save();
  }
}

class MemoStorageData {
  final String key;
  final String title;

  MemoStorageData({required this.key, required this.title});

  MemoStorageData copyWith({String? key, String? title}) {
    return MemoStorageData(key: key ?? this.key, title: title ?? this.title);
  }
}

Future<List<MemoStorageData>> _loadMemos(DirectoryPath directoryPath) async {
  initializeMappers();
  if (!await directoryPath.exists()) {
    return [];
  }
  final result = <MemoStorageData>[];
  await for (final e in directoryPath.list()) {
    try {
      final title = MemoDataMapper.fromJson(await e.asFilePath.readAsString()).title;
      result.add(MemoStorageData(key: e.stem, title: title));
    } catch (error, stackTrace) {
      logger.w("Skipping unreadable memo file: path=${e.asFilePath.path}", error, stackTrace);
    }
  }
  return result;
}

final charaDetailRecordMemoStorageDataLoader = FutureProvider<List<MemoStorageData>>((ref) {
  final path = ref.watch(pathInfoProvider).charaDetailMemoDir;
  return _loadMemos(path);
});

class CharaDetailRecordMemoStorageDataNotifier extends _StorageDataNotifier<MemoStorageData> {
  @override
  List<MemoStorageData> build() => ref.watch(charaDetailRecordMemoStorageDataLoader).value!;
}

final charaDetailRecordMemoStorageDataProvider =
    NotifierProvider<CharaDetailRecordMemoStorageDataNotifier, List<MemoStorageData>>(
      CharaDetailRecordMemoStorageDataNotifier.new,
    );

final charaDetailRecordMemoProvider = AsyncNotifierProvider.family<CharaDetailRecordMemoController, MemoData, String>(
  CharaDetailRecordMemoController.new,
);

final currentColumnSpecsLoaderProvider = AsyncNotifierProvider<ColumnSpecSelection, List<ColumnSpec>>(
  ColumnSpecSelection.new,
);

// Thin synchronous view over the loaded column specs. Mutating callers use
// currentColumnSpecsLoaderProvider.notifier instead.
final currentColumnSpecsProvider = Provider<List<ColumnSpec>>((ref) {
  return ref.watch(currentColumnSpecsLoaderProvider).requireValue;
});

// Ids of specs that were loaded from incomplete/undecodable data (see
// ColumnSpecSelection). The UI renders these as broken chips so the user is
// prompted to review them. Recomputed whenever the selection changes.
final currentColumnSpecBrokenIdsProvider = Provider<Set<String>>((ref) {
  ref.watch(currentColumnSpecsLoaderProvider);
  return ref.read(currentColumnSpecsLoaderProvider.notifier).brokenIds;
});

class Grid {
  final List<TrinaColumn> columns;
  final List<TrinaRow> rows;

  /// Per-column count of records passing that column's condition, keyed by spec id.
  /// Includes nested (injected) columns, not just top-level ones.
  final Map<String, int> filteredCounts;

  Grid(this.columns, this.rows, this.filteredCounts);

  static Grid get empty => Grid([], [], {});
}

/// Field id of the synthetic checkbox column injected in selection mode.
const checkColumnField = "__selection_check__";

TrinaColumn _buildCheckColumn() {
  return TrinaColumn(
    title: "",
    field: checkColumnField,
    type: TrinaColumnType.text(),
    // Wide enough for the checkbox's material tap target plus cell padding;
    // autoFitColumns skips this column so the width stays fixed.
    width: 60,
    minWidth: 60,
    enableRowChecked: true,
    readOnly: true,
    enableSorting: false,
    enableContextMenu: false,
    enableDropToResize: false,
    enableColumnDrag: false,
    enableFilterMenuItem: false,
    enableHideColumnMenuItem: false,
    // The built-in header checkbox sits in a Flexible that shares space with the
    // (empty) title text, so on a narrow column it gets squeezed and no longer
    // lines up with the per-row checkboxes. Render the select-all checkbox
    // ourselves, left-aligned with the same padding/scale as the cells.
    titleRenderer: _selectAllCheckboxRenderer,
  );
}

/// Header renderer drawing a tristate select-all checkbox left-aligned to match
/// the per-row checkbox column.
Widget _selectAllCheckboxRenderer(TrinaColumnTitleRendererContext rendererContext) {
  final stateManager = rendererContext.stateManager;
  return ListenableBuilder(
    listenable: stateManager,
    builder: (context, _) {
      final total = stateManager.refRows.length;
      final checked = stateManager.checkedRows.length;
      final bool? value = (total == 0 || checked == 0) ? false : (checked >= total ? true : null);
      return Align(
        alignment: Alignment.centerLeft,
        // Match the cells' left padding (TrinaGridSettings.cellPadding == 10) so
        // the header checkbox lines up exactly with the per-row checkboxes.
        child: Padding(
          padding: const EdgeInsets.only(left: 10),
          child: Transform.scale(
            scale: 0.86,
            child: Checkbox(
              value: value,
              tristate: true,
              onChanged: (newValue) {
                final next = newValue ?? false;
                stateManager.toggleAllRowChecked(next);
                // Route through the grid's onRowChecked so the toolbar's selected
                // set and the row overlays update the same way a cell tap does.
                stateManager.onRowChecked?.call(TrinaGridOnRowCheckedAllEvent(isChecked: next));
              },
            ),
          ),
        ),
      );
    },
  );
}

Grid _buildGrid(
  RefBase ref,
  List<CharaDetailRecord> recordList,
  List<ColumnSpec> specList, {
  bool selectionMode = false,
  Set<String> pinnedIds = const {},
}) {
  // Every node in the tree contributes a data column (leaves show their value,
  // container columns show a pass/fail cell), so flatten the forest for display.
  final displaySpecs = flattenForest(specList);

  // Parse each leaf spec exactly once. Container columns have no value of their
  // own; their cells come from the combined condition computed below.
  final parsedById = <String, List>{};
  for (final spec in displaySpecs) {
    if (!spec.acceptsChildren) {
      parsedById[spec.id] = spec.parse(ref, recordList);
    }
  }

  // Resolve each spec's per-row condition, recursing through container columns.
  // Leaf conditions come from evaluate(); a container combines its children's
  // conditions, dispatched through the ContainerColumnSpec capability so any
  // container kind works without enumerating concrete types here.
  final conditionsById = <String, List<bool>>{};
  List<bool> resolve(ColumnSpec spec) {
    final cached = conditionsById[spec.id];
    if (cached != null) {
      return cached;
    }
    final List<bool> condition;
    if (spec is ContainerColumnSpec) {
      final childConditions = spec.children.map(resolve).toList();
      condition = spec.combineChildren(childConditions, recordList.length);
    } else {
      condition = spec.evaluate(ref, parsedById[spec.id]!);
    }
    conditionsById[spec.id] = condition;
    return condition;
  }

  for (final spec in displaySpecs) {
    resolve(spec);
  }

  final filteredCounts = {for (final spec in displaySpecs) spec.id: conditionsById[spec.id]!.countTrue()};

  // Hidden columns are evaluated above (so they still filter rows and feed the
  // pass-count badge) but contribute no visible column or cell. Everything below
  // that builds the rendered grid works from [visibleSpecs] instead.
  final visibleSpecs = displaySpecs.where((spec) => !spec.hidden).toList();
  final columns = visibleSpecs.map((spec) => spec.plutoColumn(ref)).toList();
  // Sanitize pinned widths read back from storage (see ColumnSpec.clampedWidth):
  // trina clamps to minColumnWidth only on interactive resize, not at build, so a
  // corrupted persisted value would otherwise render broken. Index-aligned with
  // visibleSpecs since columns is the map() of it; the checkbox column is inserted
  // below and is not a ColumnSpec, so it is unaffected.
  for (final (index, spec) in visibleSpecs.indexed) {
    final width = spec.clampedWidth;
    if (width != null) {
      columns[index].width = width;
    }
  }
  // A leading checkbox column drives bulk selection. Its cells are added to
  // every row below; the column's field must match those cell keys.
  if (selectionMode) {
    columns.insert(0, _buildCheckColumn());
    // Freeze sorting while selecting: re-sorting rebuilds rows and would drop the
    // in-progress checkbox selection.
    for (final column in columns) {
      column.enableSorting = false;
    }
  }

  // A row is visible only if every TOP-LEVEL spec passes. Nested specs influence
  // visibility solely through their parent container column. Computed per record
  // (not via transpose) so an empty specList yields one bool per record — all
  // visible — instead of collapsing every record into a single phantom row.
  final rowConditions = List<bool>.generate(
    recordList.length,
    (rowIndex) => specList.every((spec) => conditionsById[spec.id]![rowIndex]),
  );

  TrinaCell cellOf(ColumnSpec spec, int rowIndex) {
    if (spec is ContainerColumnSpec) {
      return spec.conditionCell(ref, conditionsById[spec.id]![rowIndex]);
    }
    return spec.plutoCell(ref, parsedById[spec.id]![rowIndex]);
  }

  final visibleIndices = rowConditions.indexed.where((e) => e.$2).map((e) => e.$1);

  final rows = visibleIndices
      .map((rowIndex) {
        final record = recordList[rowIndex];
        return TrinaRow(
          cells: {
            if (selectionMode) checkColumnField: TrinaCell(value: ""),
            for (final spec in visibleSpecs) spec.id: cellOf(spec, rowIndex),
          },
          sortIdx: -record.metadata.capturedDate.toDateTime().millisecondsSinceEpoch,
          frozen: pinnedIds.contains(record.id) ? TrinaRowFrozen.start : TrinaRowFrozen.none,
        )..setUserData(record);
      })
      .sortedBy<num>((e) => e.sortIdx)
      .toList();

  return Grid(columns, rows, filteredCounts);
}

final currentGridProvider = Provider<Grid>((ref) {
  final selectionMode = ref.watch(selectionModeProvider) != null;
  // While selecting, build the whole grid through a read-only ref so NONE of the
  // providers touched during the build (records, specs, and the rating/memo/label
  // providers that plutoColumn/cellOf watch deep inside) register a dependency.
  // Any such rebuild would reset TrinaGrid's checkboxes while selectedRecordIdsProvider
  // kept the stale ids, so a confirm would act on rows the user no longer sees
  // checked. Only selectionModeProvider stays a real watch above, so the grid is
  // rebuilt solely when selection mode itself toggles (enter/exit).
  final gridRef = selectionMode ? ref.base.readOnly : ref.base;
  final recordList = gridRef.watch(displayedRecordsProvider);
  final specList = gridRef.watch(currentColumnSpecsProvider);
  // Pinned rows render frozen at the top. In selection mode this resolves through
  // the readOnly ref so toggling pins (disabled there anyway) won't rebuild and
  // drop the in-progress checkbox selection; outside it, a pin toggle rebuilds
  // the grid and re-derives the frozen rows from this set.
  final pinnedIds = gridRef.watch(pinnedRecordIdsProvider);

  try {
    return _buildGrid(gridRef, recordList, specList, selectionMode: selectionMode, pinnedIds: pinnedIds);
  } catch (exception, stackTrace) {
    logger.e("Failed to build grid.", exception, stackTrace);
    captureException(exception, stackTrace);
    // Render an empty grid for this session without touching storage. Clearing
    // the selection here would re-serialize an empty list and permanently erase
    // every saved column on a transient build failure.
    Toaster.show(ToastData.error(description: "pages.chara_detail.error.building_grid".tr()));
    return Grid.empty;
  }
});
