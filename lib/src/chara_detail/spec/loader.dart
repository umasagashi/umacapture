import 'dart:async';

import 'package:collection/collection.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/json_adapter.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/toast.dart';
import '/src/preference/storage_box.dart';

// ignore: constant_identifier_names
const tr_columns = "pages.chara_detail.columns";

final moduleInfoLoaders = FutureProvider((ref) async {
  return Future.wait([
    ref.watch(moduleVersionLoader.future),
  ]).then((_) {
    return Future.wait([
      ref.watch(_labelMapLoader.future),
      ref.watch(_skillInfoLoader.future),
      ref.watch(_skillTagLoader.future),
      ref.watch(_factorInfoLoader.future),
      ref.watch(_factorTagLoader.future),
      ref.watch(_charaRankBorderLoader.future),
      ref.watch(_charaCardInfoLoader.future),
      ref.watch(_charaDetailRecordRatingStorageDataLoader.future),
      ref.watch(_charaDetailRecordCommentStorageDataLoader.future),
    ]).then((_) {
      return Future.wait([
        ref.watch(_currentColumnSpecsLoader.future),
      ]);
    });
  });
});

Future<T> _loadFromJson<T>(FilePath path) async {
  initializeJsonReflectable();
  const options = DeserializationOptions(caseStyle: CaseStyle.snake);
  return path.toFile().readAsString().then((e) => JsonMapper.deserialize<T>(e, options)!);
}

final _labelMapLoader = FutureProvider<LabelMap>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return compute(_loadFromJson<Map<String, dynamic>>, path.modulesDir.filePath("labels.json"))
      .then((e) => e.map((k, v) => MapEntry(k, List<String>.from(v))));
});

final labelMapProvider = Provider<LabelMap>((ref) {
  return ref.watch(_labelMapLoader).value!;
});

final _skillInfoLoader = FutureProvider<List<SkillInfo>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return compute(_loadFromJson<List<SkillInfo>>, path.modulesDir.filePath("skill_info.json"))
      .then((e) => e.sortedBy<num>((e) => e.sortKey));
});

final skillInfoProvider = Provider<List<SkillInfo>>((ref) {
  return ref.watch(_skillInfoLoader).value!;
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
    initializeJsonReflectable();
    return arg.path.writeAsString(JsonMapper.serialize(arg.data));
  }

  Future<void> run() {
    return compute(_RatingDataWriter._run, this);
  }
}

@jsonSerializable
class RatingData {
  final String title;
  final Map<String, double> data;

  RatingData({
    required this.title,
    required this.data,
  });

  @jsonConstructor
  RatingData.fromJson(
    @JsonProperty(name: 'title') String title,
    @JsonProperty(name: 'data') Map<dynamic, dynamic> data,
    // ignore: prefer_initializing_formals
  )   : title = title,
        data = Map<String, double>.from(data);

  RatingData copyWith({
    String? title,
    Map<String, double>? data,
  }) {
    return RatingData(
      title: title ?? this.title,
      data: data ?? this.data,
    );
  }

  static RatingData get empty {
    return RatingData(
      title: "pages.chara_detail.columns.rating.title".tr(),
      data: {},
    );
  }
}

class CharaDetailRecordRatingController extends StateNotifier<RatingData> {
  final FilePath path;

  CharaDetailRecordRatingController(this.path, super.state);

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

  RatingStorageData({
    required this.key,
    required this.title,
  });

  RatingStorageData copyWith({
    String? key,
    String? title,
  }) {
    return RatingStorageData(
      key: key ?? this.key,
      title: title ?? this.title,
    );
  }
}

Future<List<RatingStorageData>> _loadRatings(DirectoryPath directoryPath) async {
  initializeJsonReflectable();
  if (!directoryPath.existsSync()) {
    return [];
  }
  return directoryPath
      .listSync()
      .map((e) => RatingStorageData(
            key: e.stem,
            title: JsonMapper.deserialize<RatingData>(e.asFilePath.readAsStringSync())!.title,
          ))
      .toList();
}

final _charaDetailRecordRatingStorageDataLoader = FutureProvider<List<RatingStorageData>>((ref) {
  final path = ref.watch(pathInfoProvider).charaDetailRatingDir;
  return compute(_loadRatings, path);
});

final charaDetailRecordRatingStorageDataProvider = StateProvider<List<RatingStorageData>>((ref) {
  return ref.watch(_charaDetailRecordRatingStorageDataLoader).value!;
});

final charaDetailRecordRatingProvider =
    StateNotifierProvider.family<CharaDetailRecordRatingController, RatingData, String>((ref, key) {
  final path = ref.watch(pathInfoProvider).charaDetailRatingDir.filePath("$key.json");
  if (!path.existsSync()) {
    return CharaDetailRecordRatingController(path, RatingData.empty);
  } else {
    return CharaDetailRecordRatingController(path, JsonMapper.deserialize<RatingData>(path.readAsStringSync())!);
  }
});

class _CommentDataWriter {
  final FilePath path;
  final CommentData data;

  _CommentDataWriter(this.path, this.data);

  static Future<void> _run(_CommentDataWriter arg) {
    initializeJsonReflectable();
    return arg.path.writeAsString(JsonMapper.serialize(arg.data));
  }

  Future<void> run() {
    return compute(_CommentDataWriter._run, this);
  }
}

@jsonSerializable
class CommentData {
  final String title;
  final Map<String, String> data;

  CommentData({
    required this.title,
    required this.data,
  });

  @jsonConstructor
  CommentData.fromJson(
    @JsonProperty(name: 'title') String title,
    @JsonProperty(name: 'data') Map<dynamic, dynamic> data,
    // ignore: prefer_initializing_formals
  )   : title = title,
        data = Map<String, String>.from(data);

  CommentData copyWith({
    String? title,
    Map<String, String>? data,
  }) {
    return CommentData(
      title: title ?? this.title,
      data: data ?? this.data,
    );
  }

  static CommentData get empty {
    return CommentData(
      title: "pages.chara_detail.columns.comment.title".tr(),
      data: {},
    );
  }
}

class CharaDetailRecordCommentController extends StateNotifier<CommentData> {
  final FilePath path;

  CharaDetailRecordCommentController(this.path, super.state);

  String get title => state.title;

  // void _updateWithoutNotify({
  //   required String recordId,
  //   required String comment,
  // }) {
  //   state.data[recordId] = comment;
  // }

  void _update({
    required String recordId,
    required String comment,
  }) {
    state.data[recordId] = comment;
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
    _CommentDataWriter(path, state).run();
  }

  void update({
    required String recordId,
    required String? comment,
  }) {
    if (comment?.isEmpty ?? true) {
      _remove(recordId: recordId);
    } else {
      _update(recordId: recordId, comment: comment!);
    }
    _save();
  }
}

class CommentStorageData {
  final String key;
  final String title;

  CommentStorageData({
    required this.key,
    required this.title,
  });

  CommentStorageData copyWith({
    String? key,
    String? title,
  }) {
    return CommentStorageData(
      key: key ?? this.key,
      title: title ?? this.title,
    );
  }
}

Future<List<CommentStorageData>> _loadComments(DirectoryPath directoryPath) async {
  initializeJsonReflectable();
  if (!directoryPath.existsSync()) {
    return [];
  }
  return directoryPath
      .listSync()
      .map((e) => CommentStorageData(
            key: e.stem,
            title: JsonMapper.deserialize<CommentData>(e.asFilePath.readAsStringSync())!.title,
          ))
      .toList();
}

final _charaDetailRecordCommentStorageDataLoader = FutureProvider<List<CommentStorageData>>((ref) {
  final path = ref.watch(pathInfoProvider).charaDetailCommentDir;
  return compute(_loadComments, path);
});

final charaDetailRecordCommentStorageDataProvider = StateProvider<List<CommentStorageData>>((ref) {
  return ref.watch(_charaDetailRecordCommentStorageDataLoader).value!;
});

final charaDetailRecordCommentProvider =
    StateNotifierProvider.family<CharaDetailRecordCommentController, CommentData, String>((ref, key) {
  final path = ref.watch(pathInfoProvider).charaDetailCommentDir.filePath("$key.json");
  if (!path.existsSync()) {
    return CharaDetailRecordCommentController(path, CommentData.empty);
  } else {
    return CharaDetailRecordCommentController(path, JsonMapper.deserialize<CommentData>(path.readAsStringSync())!);
  }
});

final _currentColumnSpecsLoader = FutureProvider<ColumnSpecSelection>((ref) async {
  final entry = StorageBox(StorageBoxKey.columnSpec).entry<String>("current_column_specs");
  return ColumnSpecSelection(entry);
});

final currentColumnSpecsProvider = StateNotifierProvider<ColumnSpecSelection, List<ColumnSpec>>((ref) {
  return ref.watch(_currentColumnSpecsLoader).value!;
});

class Grid {
  final List<PlutoColumn> columns;
  final List<PlutoRow> rows;
  final List<int> filteredCounts;

  Grid(this.columns, this.rows, this.filteredCounts);

  static Grid get empty => Grid([], [], []);
}

Grid _buildGrid(RefBase ref, List<CharaDetailRecord> recordList, List<ColumnSpec> specList) {
  final columnValues = specList.map((spec) => spec.parse(ref, recordList)).toList();
  final columnConditions = zip2(specList, columnValues).map((e) => e.item1.evaluate(ref, e.item2)).toList();

  final filteredCounts = columnConditions.map((e) => e.countTrue()).toList();
  final columns = specList.map((spec) => spec.plutoColumn(ref)).toList();

  final rowValues = columnValues.transpose();
  final rowConditions = columnConditions.transpose().map((e) => e.everyIn()).toList();

  final plutoCells = zip2(rowValues, rowConditions)
      .where((row) => row.item2)
      .map((row) => zip2(specList, row.item1).map((c) => MapEntry(c.item1.id, c.item1.plutoCell(ref, c.item2))));

  final records = zip2(recordList, rowConditions).where((row) => row.item2).map((row) => row.item1);

  final rows = zip2(plutoCells, records)
      .map((row) => PlutoRow(
            cells: Map.fromEntries(row.item1),
            sortIdx: -DateTime.parse(row.item2.metadata.capturedDate).millisecondsSinceEpoch,
          )..setUserData(row.item2))
      .sortedBy<num>((e) => e.sortIdx!)
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
    // Cannot change state while building.
    Future.delayed(
      const Duration(milliseconds: 1),
      () => ref.read(currentColumnSpecsProvider.notifier).clear(), // TODO: Remove only failed specs.
    );
    Toaster.show(ToastData(ToastType.error, description: "pages.chara_detail.error.building_grid".tr()));
    return Grid.empty;
  }
});
