import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quiver/iterables.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/chara_rank.dart';
import '/src/chara_detail/spec/character.dart';
import '/src/chara_detail/spec/datetime.dart';
import '/src/chara_detail/spec/factor.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/chara_detail/spec/ranged_integer.dart';
import '/src/chara_detail/spec/ranged_label.dart';
import '/src/chara_detail/spec/rating.dart';
import '/src/chara_detail/spec/simple_label.dart';
import '/src/chara_detail/spec/skill.dart';

// ignore: constant_identifier_names
const tr_columns = "pages.chara_detail.columns";

final columnBuilderProvider = Provider<List<ColumnBuilder>>((ref) {
  final labels = ref.watch(labelMapProvider);
  final strategies = enumerate(labels["race_strategy.name"]!).toList();
  final factorInfo = ref.watch(factorInfoProvider);
  final ratingStorages = ref.watch(charaDetailRecordRatingStorageDataProvider);
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
    ),
    RangedIntegerColumnBuilder(
      title: "$tr_columns.status.stamina.title".tr(),
      category: ColumnCategory.status,
      parser: StatusStaminaParser(),
    ),
    RangedIntegerColumnBuilder(
      title: "$tr_columns.status.power.title".tr(),
      category: ColumnCategory.status,
      parser: StatusPowerParser(),
    ),
    RangedIntegerColumnBuilder(
      title: "$tr_columns.status.guts.title".tr(),
      category: ColumnCategory.status,
      parser: StatusGutsParser(),
    ),
    RangedIntegerColumnBuilder(
      title: "$tr_columns.status.intelligence.title".tr(),
      category: ColumnCategory.status,
      parser: StatusIntelligenceParser(),
    ),
    RangedLabelColumnBuilder(
      title: "$tr_columns.aptitude.turf_ground.title".tr(),
      category: ColumnCategory.aptitude,
      labelKey: LabelKeys.aptitude,
      parser: TurfGroundAptitudeParser(),
    ),
    RangedLabelColumnBuilder(
      title: "$tr_columns.aptitude.dirt_ground.title".tr(),
      category: ColumnCategory.aptitude,
      labelKey: LabelKeys.aptitude,
      parser: DirtGroundAptitudeParser(),
    ),
    RangedLabelColumnBuilder(
      title: "$tr_columns.aptitude.short_range.title".tr(),
      category: ColumnCategory.aptitude,
      labelKey: LabelKeys.aptitude,
      parser: ShortRangeAptitudeParser(),
    ),
    RangedLabelColumnBuilder(
      title: "$tr_columns.aptitude.mile_range.title".tr(),
      category: ColumnCategory.aptitude,
      labelKey: LabelKeys.aptitude,
      parser: MileRangeAptitudeParser(),
    ),
    RangedLabelColumnBuilder(
      title: "$tr_columns.aptitude.middle_range.title".tr(),
      category: ColumnCategory.aptitude,
      labelKey: LabelKeys.aptitude,
      parser: MiddleRangeAptitudeParser(),
    ),
    RangedLabelColumnBuilder(
      title: "$tr_columns.aptitude.long_range.title".tr(),
      category: ColumnCategory.aptitude,
      labelKey: LabelKeys.aptitude,
      parser: LongRangeAptitudeParser(),
    ),
    RangedLabelColumnBuilder(
      title: "$tr_columns.aptitude.lead_pace.title".tr(),
      category: ColumnCategory.aptitude,
      labelKey: LabelKeys.aptitude,
      parser: LeadPaceAptitudeParser(),
    ),
    RangedLabelColumnBuilder(
      title: "$tr_columns.aptitude.with_pace.title".tr(),
      category: ColumnCategory.aptitude,
      labelKey: LabelKeys.aptitude,
      parser: WithPaceAptitudeParser(),
    ),
    RangedLabelColumnBuilder(
      title: "$tr_columns.aptitude.off_pace.title".tr(),
      category: ColumnCategory.aptitude,
      labelKey: LabelKeys.aptitude,
      parser: OffPaceAptitudeParser(),
    ),
    RangedLabelColumnBuilder(
      title: "$tr_columns.aptitude.late_charge.title".tr(),
      category: ColumnCategory.aptitude,
      labelKey: LabelKeys.aptitude,
      parser: LateChargeAptitudeParser(),
    ),
    RangedLabelColumnBuilder(
      title: "$tr_columns.aptitude.shortcuts.short_range.title".tr(),
      category: ColumnCategory.aptitude,
      labelKey: LabelKeys.aptitude,
      parser: ShortRangeAptitudeParser(),
      min: 7,
    ),
    RangedLabelColumnBuilder(
      title: "$tr_columns.aptitude.shortcuts.mile_range.title".tr(),
      category: ColumnCategory.aptitude,
      labelKey: LabelKeys.aptitude,
      parser: MileRangeAptitudeParser(),
      min: 7,
    ),
    RangedLabelColumnBuilder(
      title: "$tr_columns.aptitude.shortcuts.middle_range.title".tr(),
      category: ColumnCategory.aptitude,
      labelKey: LabelKeys.aptitude,
      parser: MiddleRangeAptitudeParser(),
      min: 7,
    ),
    RangedLabelColumnBuilder(
      title: "$tr_columns.aptitude.shortcuts.long_range.title".tr(),
      category: ColumnCategory.aptitude,
      labelKey: LabelKeys.aptitude,
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
      initialIds: factorInfo.where((e) => e.tags.contains("factor_status")).map((e) => e.sid).toSet(),
      initialStar: 1,
    ),
    FilterFactorColumnBuilder(
      title: "$tr_columns.factor.shortcuts.aptitude.title".tr(),
      category: ColumnCategory.factor,
      parser: FactorSetParser(),
      isFilterColumn: false,
      initialFactorTags: {"factor_aptitude"},
      initialIds: factorInfo.where((e) => e.tags.contains("factor_aptitude")).map((e) => e.sid).toSet(),
      initialStar: 1,
    ),
    FilterFactorColumnBuilder(
      title: "$tr_columns.factor.shortcuts.scenario.title".tr(),
      category: ColumnCategory.factor,
      parser: FactorSetParser(),
      isFilterColumn: true,
      initialFactorTags: {"factor_scenario"},
      initialIds: factorInfo.where((e) => e.tags.contains("factor_scenario")).map((e) => e.sid).toSet(),
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
    RangedIntegerColumnBuilder(
      title: "$tr_columns.fans.title".tr(),
      category: ColumnCategory.campaign,
      parser: FansParser(),
      tabIdx: 2,
    ),
    DateTimeColumnBuilder(
      title: "$tr_columns.trained_date.title".tr(),
      category: ColumnCategory.campaign,
      parser: TrainedDateParser(),
    ),
    SimpleLabelColumnBuilder(
      title: "$tr_columns.race_strategy.title".tr(),
      category: ColumnCategory.metadata,
      labelKey: LabelKeys.raceStrategy,
      parser: RaceStrategyParser(),
    ),
    for (final strategy in strategies)
      SimpleLabelColumnBuilder(
        title: strategy.value,
        category: ColumnCategory.metadata,
        labelKey: LabelKeys.raceStrategy,
        parser: RaceStrategyParser(),
        rejects: strategies.where((e) => e.index != strategy.index).map((e) => e.index).toSet(),
      ),
    for (final storage in ratingStorages) ...[
      RatingColumnBuilder(
        ref: ref,
        title: storage.title,
        columnTitle: storage.title,
        category: ColumnCategory.metadata,
        parser: TraineeIdParser(),
        storageKey: storage.key,
      ),
    ],
    RatingColumnBuilder(
      ref: ref,
      title: "$tr_columns.rating.builder_title".tr(),
      columnTitle: "$tr_columns.rating.default_title".tr(),
      category: ColumnCategory.metadata,
      parser: TraineeIdParser(),
    ),
  ];
});
