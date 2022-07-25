import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';

import '/src/app/providers.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/character.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/chara_detail/spec/ranged_integer.dart';
import '/src/chara_detail/spec/ranged_label.dart';
import '/src/chara_detail/spec/skill.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/utils.dart';

// ignore: constant_identifier_names
const tr_columns = "pages.chara_detail.columns";

final moduleInfoLoaders = FutureProvider((ref) async {
  return Future.wait([
    ref.watch(_labelMapLoader.future),
    ref.watch(_skillInfoLoader.future),
    ref.watch(_skillTagLoader.future),
    ref.watch(_charaRankBorderLoader.future),
    ref.watch(_charaCardInfoLoader.future),
  ]).then((_) {
    return Future.wait([
      ref.watch(_columnBuilderLoader.future),
      ref.watch(_currentColumnSpecsLoader.future),
    ]);
  });
});

Future<T> _loadFromJson<T>(Ref ref, String fileName) async {
  final path = await ref.watch(pathInfoLoader.future);
  const options = DeserializationOptions(caseStyle: CaseStyle.snake);
  return File("${path.modules}/$fileName").readAsString().then((e) => JsonMapper.deserialize<T>(e, options)!);
}

final _labelMapLoader = FutureProvider<LabelMap>((ref) async {
  return _loadFromJson<Map<String, dynamic>>(ref, "labels.json")
      .then((e) => e.map((k, v) => MapEntry(k, List<String>.from(v))));
});

final labelMapProvider = Provider<LabelMap>((ref) {
  return ref.watch(_labelMapLoader).value!;
});

final _skillInfoLoader = FutureProvider<List<SkillInfo>>((ref) async {
  return _loadFromJson<List<SkillInfo>>(ref, "skill_info.json")
      .then((e) => e.sorted((a, b) => a.sortKey.compareTo(b.sortKey)));
});

final skillInfoProvider = Provider<List<SkillInfo>>((ref) {
  return ref.watch(_skillInfoLoader).value!;
});

final availableSkillInfoProvider = Provider<List<SkillInfo>>((ref) {
  final skillSet = ref.watch(availableSkillSetProvider);
  return ref.watch(skillInfoProvider).where((e) => skillSet.contains(e.sid)).toList();
});

final _skillTagLoader = FutureProvider<List<SkillTag>>((ref) async {
  return _loadFromJson<List<SkillTag>>(ref, "skill_tag.json");
});

final skillTagProvider = Provider<List<SkillTag>>((ref) {
  return ref.watch(_skillTagLoader).value!;
});

final _charaRankBorderLoader = FutureProvider<List<int>>((ref) async {
  return _loadFromJson<List<int>>(ref, "rank_border.json");
});

final _charaCardInfoLoader = FutureProvider<List<CharaCardInfo>>((ref) async {
  return _loadFromJson<List<CharaCardInfo>>(ref, "character_card_info.json");
});

final charaCardInfoProvider = Provider<List<CharaCardInfo>>((ref) {
  return ref.watch(_charaCardInfoLoader).value!;
});

class AvailableCharaCardInfo {
  final CharaCardInfo cardInfo;
  final String iconPath;

  AvailableCharaCardInfo(this.cardInfo, this.iconPath);
}

final availableCharaCardsProvider = Provider<List<AvailableCharaCardInfo>>((ref) {
  final iconMap = ref.watch(charaCardIconMapProvider);
  return ref
      .watch(charaCardInfoProvider)
      .where((e) => iconMap.containsKey(e.sid))
      .sorted((a, b) => a.sortKey.compareTo(b.sortKey))
      .map((e) => AvailableCharaCardInfo(e, iconMap[e.sid]!))
      .toList();
});

final _columnBuilderLoader = FutureProvider<List<ColumnBuilder>>((ref) async {
  final charaRankBorder = await ref.watch(_charaRankBorderLoader.future);
  return [
    CharacterCardColumnBuilder(
      title: "$tr_columns.character.title".tr(),
      description: "$tr_columns.character.description".tr(),
      category: ColumnCategory.trainee,
      parser: CharaCardParser(),
    ),
    RangedIntegerColumnBuilder(
      title: "$tr_columns.evaluation.title".tr(),
      description: "$tr_columns.evaluation.description".tr(),
      category: ColumnCategory.trainee,
      parser: EvaluationValueParser(),
      valueMin: 0,
      valueMax: 40000,
    ),
    CharaRankColumnBuilder(
      title: "$tr_columns.chara_rank.title".tr(),
      description: "$tr_columns.chara_rank.description".tr(),
      category: ColumnCategory.trainee,
      parser: CharaRankParser(charaRankBorder),
    ),
    RangedIntegerColumnBuilder(
      title: "$tr_columns.status.speed.title".tr(),
      description: "$tr_columns.status.speed.description".tr(),
      category: ColumnCategory.status,
      parser: StatusSpeedParser(),
      valueMin: 0,
      valueMax: 1200,
    ),
    RangedIntegerColumnBuilder(
      title: "$tr_columns.status.stamina.title".tr(),
      description: "$tr_columns.status.stamina.description".tr(),
      category: ColumnCategory.status,
      parser: StatusStaminaParser(),
      valueMin: 0,
      valueMax: 1200,
    ),
    RangedIntegerColumnBuilder(
      title: "$tr_columns.status.power.title".tr(),
      description: "$tr_columns.status.power.description".tr(),
      category: ColumnCategory.status,
      parser: StatusPowerParser(),
      valueMin: 0,
      valueMax: 1200,
    ),
    RangedIntegerColumnBuilder(
      title: "$tr_columns.status.guts.title".tr(),
      description: "$tr_columns.status.guts.description".tr(),
      category: ColumnCategory.status,
      parser: StatusGutsParser(),
      valueMin: 0,
      valueMax: 1200,
    ),
    RangedIntegerColumnBuilder(
      title: "$tr_columns.status.intelligence.title".tr(),
      description: "$tr_columns.status.intelligence.description".tr(),
      category: ColumnCategory.status,
      parser: StatusIntelligenceParser(),
      valueMin: 0,
      valueMax: 1200,
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.turf_ground.title".tr(),
      description: "$tr_columns.aptitude.turf_ground.description".tr(),
      category: ColumnCategory.aptitude,
      parser: TurfGroundAptitudeParser(),
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.dirt_ground.title".tr(),
      description: "$tr_columns.aptitude.dirt_ground.description".tr(),
      category: ColumnCategory.aptitude,
      parser: DirtGroundAptitudeParser(),
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.short_range.title".tr(),
      description: "$tr_columns.aptitude.short_range.description".tr(),
      category: ColumnCategory.aptitude,
      parser: ShortRangeAptitudeParser(),
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.mile_range.title".tr(),
      description: "$tr_columns.aptitude.mile_range.description".tr(),
      category: ColumnCategory.aptitude,
      parser: MileRangeAptitudeParser(),
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.middle_range.title".tr(),
      description: "$tr_columns.aptitude.middle_range.description".tr(),
      category: ColumnCategory.aptitude,
      parser: MiddleRangeAptitudeParser(),
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.long_range.title".tr(),
      description: "$tr_columns.aptitude.long_range.description".tr(),
      category: ColumnCategory.aptitude,
      parser: LongRangeAptitudeParser(),
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.lead_pace.title".tr(),
      description: "$tr_columns.aptitude.lead_pace.description".tr(),
      category: ColumnCategory.aptitude,
      parser: LeadPaceAptitudeParser(),
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.with_pace.title".tr(),
      description: "$tr_columns.aptitude.with_pace.description".tr(),
      category: ColumnCategory.aptitude,
      parser: WithPaceAptitudeParser(),
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.off_pace.title".tr(),
      description: "$tr_columns.aptitude.off_pace.description".tr(),
      category: ColumnCategory.aptitude,
      parser: OffPaceAptitudeParser(),
    ),
    AptitudeColumnBuilder(
      title: "$tr_columns.aptitude.late_charge.title".tr(),
      description: "$tr_columns.aptitude.late_charge.description".tr(),
      category: ColumnCategory.aptitude,
      parser: LateChargeAptitudeParser(),
    ),
    SkillColumnBuilder(
      title: "$tr_columns.skill.title".tr(),
      description: "$tr_columns.skill.description".tr(),
      category: ColumnCategory.skill,
      parser: SkillParser(),
    ),
  ];
});

final columnBuilderProvider = Provider<List<ColumnBuilder>>((ref) {
  return ref.watch(_columnBuilderLoader).value!;
});

final _currentColumnSpecsLoader = FutureProvider<ColumnSpecSelection>((ref) async {
  final builders = await ref.watch(_columnBuilderLoader.future);
  final List<ColumnSpec> specs = [
    for (final b in builders) b.build(),
  ];
  return ColumnSpecSelection(specs);
});

final currentColumnSpecsProvider = StateNotifierProvider<ColumnSpecSelection, List<ColumnSpec>>((ref) {
  return ref.watch(_currentColumnSpecsLoader).value!;
});

final buildResourceProvider = Provider<BuildResource>((ref) {
  return BuildResource(
    labelMap: ref.watch(labelMapProvider),
    skillInfo: ref.watch(skillInfoProvider),
    charaCardInfo: ref.watch(charaCardInfoProvider),
    charaCardImageMap: ref.watch(charaCardIconMapProvider),
  );
});

class Grid {
  final List<PlutoColumn> columns;
  final List<PlutoRow> rows;

  Grid(this.columns, this.rows);
}

final currentGridProvider = Provider<Grid>((ref) {
  final recordList = ref.watch(charaDetailRecordStorageProvider);
  final specList = ref.watch(currentColumnSpecsProvider);
  final resource = ref.watch(buildResourceProvider);

  final columns = specList.map((spec) => spec.plutoColumn(resource)).toList();

  final columnValues = specList.map((spec) => spec.parse(recordList)).toList();
  final columnConditions = zip2(specList, columnValues).map((e) => e.item1.evaluate(e.item2)).toList();

  final rowValues = columnValues.transpose();
  final rowConditions = columnConditions.transpose().map((e) => e.everyIn()).toList();

  final plutoCells = zip2(rowValues, rowConditions)
      .where((row) => row.item2)
      .map((row) => zip2(specList, row.item1).map((c) => MapEntry(c.item1.id, c.item1.plutoCell(resource, c.item2))));

  final records = zip2(recordList, rowConditions).where((row) => row.item2).map((row) => row.item1);

  final rows = zip2(plutoCells, records)
      .map((row) => PlutoRowWithRawData.create(
            cells: Map.fromEntries(row.item1),
            data: row.item2,
            sortKey: -DateTime.parse(row.item2.metadata.capturedDate).millisecondsSinceEpoch,
          ))
      .sorted((a, b) => a.sortIdx!.compareTo(b.sortIdx!))
      .toList();

  return Grid(columns, rows);
});
