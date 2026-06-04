import 'dart:async';

import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
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
      ref.watch(labelMapLoader.future),
      ref.watch(_skillInfoLoader.future),
      ref.watch(_skillTagLoader.future),
      ref.watch(_factorInfoLoader.future),
      ref.watch(_factorTagLoader.future),
      ref.watch(_charaRankBorderLoader.future),
      ref.watch(_charaCardInfoLoader.future),
      ref.watch(_charaDetailRecordRatingStorageDataLoader.future),
      ref.watch(_charaDetailRecordMemoStorageDataLoader.future),
    ]).then((_) {
      return Future.wait([ref.watch(currentColumnSpecsLoaderProvider.future)]);
    });
  });
});

Future<T> _loadFromJson<T>(FilePath path) async {
  initializeMappers();
  return path.toFile().readAsString().then((e) => MapperContainer.globals.fromJson<T>(e));
}

final labelMapLoader = FutureProvider<LabelMap>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return compute(
    _loadFromJson<Map<String, dynamic>>,
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
  return compute(
    _loadFromJson<List<SkillInfo>>,
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
  return compute(_loadFromJson<List<Tag>>, path.modulesDir.filePath("skill_tag.json"));
});

final skillTagProvider = Provider<List<Tag>>((ref) {
  return ref.watch(_skillTagLoader).value!;
});

final _factorInfoLoader = FutureProvider<List<FactorInfo>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  final skillInfo = (await ref.watch(_skillInfoLoader.future)).toMap((e) => e.sid);
  return compute(_loadFromJson<List<FactorInfo>>, path.modulesDir.filePath("factor_info.json"))
      .then((info) => info.map((e) => e.copyWith(skillInfo: skillInfo[e.skillSid])).toList())
      .then((e) => e.sortedBy<num>((e) => e.sortKey));
});

final factorInfoProvider = Provider<List<FactorInfo>>((ref) {
  return ref.watch(_factorInfoLoader).value!;
});

final availableFactorInfoProvider = Provider<List<FactorInfo>>((ref) {
  final records = ref.watch(charaDetailRecordStorageProvider);
  final ids = records.map((r) => r.factors.flattened.map((f) => f.id)).flattened.toSet();
  return ref.watch(factorInfoProvider).where((e) => ids.contains(e.sid)).toList();
});

final _factorTagLoader = FutureProvider<List<Tag>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return compute(_loadFromJson<List<Tag>>, path.modulesDir.filePath("factor_tag.json"));
});

final factorTagProvider = Provider<List<Tag>>((ref) {
  return ref.watch(_factorTagLoader).value!;
});

final _charaRankBorderLoader = FutureProvider<List<int>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return compute(_loadFromJson<List<int>>, path.modulesDir.filePath("rank_border.json"));
});

final charaRankBorderProvider = Provider<List<int>>((ref) {
  return ref.watch(_charaRankBorderLoader).value!;
});

final _charaCardInfoLoader = FutureProvider<List<CharaCardInfo>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return compute(_loadFromJson<List<CharaCardInfo>>, path.modulesDir.filePath("character_card_info.json"));
});

final charaCardInfoProvider = Provider<List<CharaCardInfo>>((ref) {
  return ref.watch(_charaCardInfoLoader).value!;
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

class CharaDetailRecordRatingController extends Notifier<RatingData> {
  CharaDetailRecordRatingController(this.key);

  final String key;

  late FilePath path;

  @override
  RatingData build() {
    path = ref.watch(pathInfoProvider).charaDetailRatingDir.filePath("$key.json");
    return path.existsSync() ? RatingDataMapper.fromJson(path.readAsStringSync()) : RatingData.empty;
  }

  void updateWithoutNotify(String recordId, double rating) {
    state.data[recordId] = rating;
  }

  void update(String recordId, double rating) {
    state.data[recordId] = rating;
    state = state.copyWith();
  }

  void updateTitle(String title) {
    state = state.copyWith(title: title);
  }

  void save() {
    _RatingDataWriter(path, state).run();
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
  if (!directoryPath.existsSync()) {
    return [];
  }
  return directoryPath
      .listSync()
      .map(
        (e) => RatingStorageData(key: e.stem, title: RatingDataMapper.fromJson(e.asFilePath.readAsStringSync()).title),
      )
      .toList();
}

final _charaDetailRecordRatingStorageDataLoader = FutureProvider<List<RatingStorageData>>((ref) {
  final path = ref.watch(pathInfoProvider).charaDetailRatingDir;
  return compute(_loadRatings, path);
});

// Holds the list of rating/memo storage descriptors. Replaces the legacy
// StateProvider<List<T>>; [update] mirrors StateController.update so the dialog
// call sites keep their `(state) => newList` closures unchanged.
abstract class _StorageDataNotifier<T> extends Notifier<List<T>> {
  List<T> update(List<T> Function(List<T> state) cb) => state = cb(state);
}

class CharaDetailRecordRatingStorageDataNotifier extends _StorageDataNotifier<RatingStorageData> {
  @override
  List<RatingStorageData> build() => ref.watch(_charaDetailRecordRatingStorageDataLoader).value!;
}

final charaDetailRecordRatingStorageDataProvider =
    NotifierProvider<CharaDetailRecordRatingStorageDataNotifier, List<RatingStorageData>>(
      CharaDetailRecordRatingStorageDataNotifier.new,
    );

final charaDetailRecordRatingProvider = NotifierProvider.family<CharaDetailRecordRatingController, RatingData, String>(
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

class CharaDetailRecordMemoController extends Notifier<MemoData> {
  CharaDetailRecordMemoController(this.key);

  final String key;

  late FilePath path;

  @override
  MemoData build() {
    path = ref.watch(pathInfoProvider).charaDetailMemoDir.filePath("$key.json");
    return path.existsSync() ? MemoDataMapper.fromJson(path.readAsStringSync()) : MemoData.empty;
  }

  String get title => state.title;

  void _update({required String recordId, required String memo}) {
    state.data[recordId] = memo;
    state = state.copyWith();
  }

  void _remove({required String recordId}) {
    state.data.remove(recordId);
    state = state.copyWith();
  }

  void updateTitle({required String title}) {
    state = state.copyWith(title: title);
    _save();
  }

  void _save() {
    _MemoDataWriter(path, state).run();
  }

  void update({required String recordId, required String? memo}) {
    if (memo?.isEmpty ?? true) {
      _remove(recordId: recordId);
    } else {
      _update(recordId: recordId, memo: memo!);
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
  if (!directoryPath.existsSync()) {
    return [];
  }
  return directoryPath
      .listSync()
      .map((e) => MemoStorageData(key: e.stem, title: MemoDataMapper.fromJson(e.asFilePath.readAsStringSync()).title))
      .toList();
}

final _charaDetailRecordMemoStorageDataLoader = FutureProvider<List<MemoStorageData>>((ref) {
  final path = ref.watch(pathInfoProvider).charaDetailMemoDir;
  return compute(_loadMemos, path);
});

class CharaDetailRecordMemoStorageDataNotifier extends _StorageDataNotifier<MemoStorageData> {
  @override
  List<MemoStorageData> build() => ref.watch(_charaDetailRecordMemoStorageDataLoader).value!;
}

final charaDetailRecordMemoStorageDataProvider =
    NotifierProvider<CharaDetailRecordMemoStorageDataNotifier, List<MemoStorageData>>(
      CharaDetailRecordMemoStorageDataNotifier.new,
    );

final charaDetailRecordMemoProvider = NotifierProvider.family<CharaDetailRecordMemoController, MemoData, String>(
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
  final List<int> filteredCounts;

  Grid(this.columns, this.rows, this.filteredCounts);

  static Grid get empty => Grid([], [], []);
}

Grid _buildGrid(RefBase ref, List<CharaDetailRecord> recordList, List<ColumnSpec> specList) {
  final columnValues = specList.map((spec) => spec.parse(ref, recordList)).toList();
  final columnConditions = zip2(specList, columnValues).map((e) => e.$1.evaluate(ref, e.$2)).toList();

  final filteredCounts = columnConditions.map((e) => e.countTrue()).toList();
  final columns = specList.map((spec) => spec.plutoColumn(ref)).toList();

  final rowValues = columnValues.transpose();
  final rowConditions = columnConditions.transpose().map((e) => e.everyIn()).toList();

  final plutoCells = zip2(rowValues, rowConditions)
      .where((row) => row.$2)
      .map((row) => zip2(specList, row.$1).map((c) => MapEntry(c.$1.id, c.$1.plutoCell(ref, c.$2))));

  final records = zip2(recordList, rowConditions).where((row) => row.$2).map((row) => row.$1);

  final rows = zip2(plutoCells, records)
      .map(
        (row) => TrinaRow(
          cells: Map.fromEntries(row.$1),
          sortIdx: -DateTime.parse(row.$2.metadata.capturedDate).millisecondsSinceEpoch,
        )..setUserData(row.$2),
      )
      .sortedBy<num>((e) => e.sortIdx)
      .toList();

  return Grid(columns, rows, filteredCounts);
}

final currentGridProvider = Provider<Grid>((ref) {
  final recordList = ref.watch(charaDetailRecordStorageProvider);
  final specList = ref.watch(currentColumnSpecsProvider);

  try {
    return _buildGrid(ref.base, recordList, specList);
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
