import 'package:collection/collection.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/chara_rank.dart';
import '/src/chara_detail/spec/character.dart';
import '/src/chara_detail/spec/factor.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/chara_detail/spec/ranged_integer.dart';
import '/src/chara_detail/spec/ranged_label.dart';
import '/src/chara_detail/spec/skill.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/json_adapter.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
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

final availableSkillInfoProvider = Provider<List<SkillInfo>>((ref) {
  final skillSet = ref.watch(availableSkillSetProvider);
  return ref.watch(skillInfoProvider).where((e) => skillSet.contains(e.sid)).toList();
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
  final factorSet = ref.watch(availableFactorSetProvider);
  return ref.watch(factorInfoProvider).where((e) => factorSet.contains(e.sid)).toList();
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

final columnBuilderProvider = Provider<List<ColumnBuilder>>((ref) {
  final factorInfoList = ref.watch(availableFactorInfoProvider);
  return [
    CharacterCardColumnBuilder(
      title: "$tr_columns.character.title".tr(),
      category: ColumnCategory.trainee,
      parser: CharaCardParser(),
    ),
    RangedIntegerColumnBuilder(
      title: "$tr_columns.evaluation.title".tr(),
      category: ColumnCategory.trainee,
      parser: EvaluationValueParser(),
      valueMin: 0,
      valueMax: 40000,
    ),
    CharaRankColumnBuilder(
      title: "$tr_columns.chara_rank.title".tr(),
      category: ColumnCategory.trainee,
      parser: EvaluationValueParser(),
    ),
    CharaRankColumnBuilder(
      title: "$tr_columns.chara_rank.shortcuts.less_than_a.title".tr(),
      category: ColumnCategory.trainee,
      parser: EvaluationValueParser(),
      max: 5,
    ),
    RangedIntegerColumnBuilder(
      title: "$tr_columns.status.speed.title".tr(),
      category: ColumnCategory.status,
      parser: StatusSpeedParser(),
      valueMin: 0,
      valueMax: 1200,
    ),
    RangedIntegerColumnBuilder(
      title: "$tr_columns.status.stamina.title".tr(),
      category: ColumnCategory.status,
      parser: StatusStaminaParser(),
      valueMin: 0,
      valueMax: 1200,
    ),
    RangedIntegerColumnBuilder(
      title: "$tr_columns.status.power.title".tr(),
      category: ColumnCategory.status,
      parser: StatusPowerParser(),
      valueMin: 0,
      valueMax: 1200,
    ),
    RangedIntegerColumnBuilder(
      title: "$tr_columns.status.guts.title".tr(),
      category: ColumnCategory.status,
      parser: StatusGutsParser(),
      valueMin: 0,
      valueMax: 1200,
    ),
    RangedIntegerColumnBuilder(
      title: "$tr_columns.status.intelligence.title".tr(),
      category: ColumnCategory.status,
      parser: StatusIntelligenceParser(),
      valueMin: 0,
      valueMax: 1200,
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.turf_ground.title".tr(),
      category: ColumnCategory.aptitude,
      parser: TurfGroundAptitudeParser(),
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.dirt_ground.title".tr(),
      category: ColumnCategory.aptitude,
      parser: DirtGroundAptitudeParser(),
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.short_range.title".tr(),
      category: ColumnCategory.aptitude,
      parser: ShortRangeAptitudeParser(),
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.mile_range.title".tr(),
      category: ColumnCategory.aptitude,
      parser: MileRangeAptitudeParser(),
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.middle_range.title".tr(),
      category: ColumnCategory.aptitude,
      parser: MiddleRangeAptitudeParser(),
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.long_range.title".tr(),
      category: ColumnCategory.aptitude,
      parser: LongRangeAptitudeParser(),
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.lead_pace.title".tr(),
      category: ColumnCategory.aptitude,
      parser: LeadPaceAptitudeParser(),
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.with_pace.title".tr(),
      category: ColumnCategory.aptitude,
      parser: WithPaceAptitudeParser(),
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.off_pace.title".tr(),
      category: ColumnCategory.aptitude,
      parser: OffPaceAptitudeParser(),
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.late_charge.title".tr(),
      category: ColumnCategory.aptitude,
      parser: LateChargeAptitudeParser(),
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.shortcuts.short_range.title".tr(),
      category: ColumnCategory.aptitude,
      parser: ShortRangeAptitudeParser(),
      min: 7,
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.shortcuts.mile_range.title".tr(),
      category: ColumnCategory.aptitude,
      parser: MileRangeAptitudeParser(),
      min: 7,
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.shortcuts.middle_range.title".tr(),
      category: ColumnCategory.aptitude,
      parser: MiddleRangeAptitudeParser(),
      min: 7,
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.shortcuts.long_range.title".tr(),
      category: ColumnCategory.aptitude,
      parser: LongRangeAptitudeParser(),
      min: 7,
    ),
    SkillColumnBuilder(
      title: "$tr_columns.skill.title".tr(),
      category: ColumnCategory.skill,
      parser: SkillParser(),
    ),
    FactorColumnBuilder(
      title: "$tr_columns.factor.title".tr(),
      category: ColumnCategory.factor,
      parser: FactorSetParser(),
    ),
    FilterFactorColumnBuilder(
      title: "$tr_columns.factor.shortcuts.status.title".tr(),
      category: ColumnCategory.factor,
      parser: FactorSetParser(),
      isFilterColumn: false,
      initialFactorTags: {"factor_status"},
      initialIds: factorInfoList.where((e) => e.tags.contains("factor_status")).map((e) => e.sid).toSet(),
      initialStar: 1,
    ),
    FilterFactorColumnBuilder(
      title: "$tr_columns.factor.shortcuts.aptitude.title".tr(),
      category: ColumnCategory.factor,
      parser: FactorSetParser(),
      isFilterColumn: false,
      initialFactorTags: {"factor_aptitude"},
      initialIds: factorInfoList.where((e) => e.tags.contains("factor_aptitude")).map((e) => e.sid).toSet(),
      initialStar: 1,
    ),
    FilterFactorColumnBuilder(
      title: "$tr_columns.factor.shortcuts.scenario.title".tr(),
      category: ColumnCategory.factor,
      parser: FactorSetParser(),
      isFilterColumn: true,
      initialFactorTags: {"factor_scenario"},
      initialIds: factorInfoList.where((e) => e.tags.contains("factor_scenario")).map((e) => e.sid).toSet(),
      initialStar: 1,
    ),
    FilterFactorColumnBuilder(
      title: "$tr_columns.factor.shortcuts.short_range.title".tr(),
      category: ColumnCategory.factor,
      parser: FactorSetParser(),
      isFilterColumn: true,
      initialFactorTags: {"factor_aptitude"},
      initialIds: {66},
      initialStar: 1,
    ),
    FilterFactorColumnBuilder(
      title: "$tr_columns.factor.shortcuts.mile_range.title".tr(),
      category: ColumnCategory.factor,
      parser: FactorSetParser(),
      isFilterColumn: true,
      initialFactorTags: {"factor_aptitude"},
      initialIds: {27},
      initialStar: 1,
    ),
    FilterFactorColumnBuilder(
      title: "$tr_columns.factor.shortcuts.middle_range.title".tr(),
      category: ColumnCategory.factor,
      parser: FactorSetParser(),
      isFilterColumn: true,
      initialFactorTags: {"factor_aptitude"},
      initialIds: {73},
      initialStar: 1,
    ),
    FilterFactorColumnBuilder(
      title: "$tr_columns.factor.shortcuts.long_range.title".tr(),
      category: ColumnCategory.factor,
      parser: FactorSetParser(),
      isFilterColumn: true,
      initialFactorTags: {"factor_aptitude"},
      initialIds: {142},
      initialStar: 1,
    ),
  ];
});

final _currentColumnSpecsLoader = FutureProvider<ColumnSpecSelection>((ref) async {
  final entry = StorageBox(StorageBoxKey.columnSpec).entry<String>("current_column_specs");
  return ColumnSpecSelection(entry);
});

final currentColumnSpecsProvider = StateNotifierProvider<ColumnSpecSelection, List<ColumnSpec>>((ref) {
  return ref.watch(_currentColumnSpecsLoader).value!;
});

final buildResourceProvider = Provider<BuildResource>((ref) {
  return BuildResource(
    labelMap: ref.watch(labelMapProvider),
    skillInfo: ref.watch(skillInfoProvider),
    charaCardInfo: ref.watch(charaCardInfoProvider),
    recordRootDir: ref.watch(pathInfoProvider).charaDetailActiveDir,
    charaRankBorder: ref.watch(charaRankBorderProvider),
  );
});

class Grid {
  final List<PlutoColumn> columns;
  final List<PlutoRow> rows;
  final List<int> filteredCounts;

  Grid(this.columns, this.rows, this.filteredCounts);
}

final currentGridProvider = Provider<Grid>((ref) {
  final recordList = ref.watch(charaDetailRecordStorageProvider);
  final specList = ref.watch(currentColumnSpecsProvider);
  final resource = ref.watch(buildResourceProvider);

  final columnValues = specList.map((spec) => spec.parse(resource, recordList)).toList();
  final columnConditions = zip2(specList, columnValues).map((e) => e.item1.evaluate(resource, e.item2)).toList();

  final filteredCounts = columnConditions.map((e) => e.countTrue()).toList();
  final columns = specList.map((spec) => spec.plutoColumn(resource)).toList();

  final rowValues = columnValues.transpose();
  final rowConditions = columnConditions.transpose().map((e) => e.everyIn()).toList();

  final plutoCells = zip2(rowValues, rowConditions)
      .where((row) => row.item2)
      .map((row) => zip2(specList, row.item1).map((c) => MapEntry(c.item1.id, c.item1.plutoCell(resource, c.item2))));

  final records = zip2(recordList, rowConditions).where((row) => row.item2).map((row) => row.item1);

  final rows = zip2(plutoCells, records)
      .map((row) => PlutoRow(
            cells: Map.fromEntries(row.item1),
            sortIdx: -DateTime.parse(row.item2.metadata.capturedDate).millisecondsSinceEpoch,
          )..setUserData(row.item2))
      .sortedBy<num>((e) => e.sortIdx!)
      .toList();

  return Grid(columns, rows, filteredCounts);
});
