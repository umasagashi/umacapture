import 'package:dart_mappable/dart_mappable.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/core/utils.dart';

part 'parser.mapper.dart';

@MappableClass(discriminatorKey: 'type')
abstract class Parser<T> with ParserMappable<T> {
  String get type => runtimeType.toString();

  T parse(CharaDetailRecord record);

  /// Parses a whole record list, with access to the provider graph via [ref].
  ///
  /// Defaults to mapping [parse] over the records, so pure (record-only)
  /// parsers need no change. Parsers whose value depends on module data (loaded
  /// through providers) override this and ignore [parse].
  List<T> parseList(RefBase ref, List<CharaDetailRecord> records) => records.map(parse).toList();
}

@MappableClass(discriminatorValue: 'EvaluationValueParser')
class EvaluationValueParser extends Parser<int> with EvaluationValueParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.evaluationValue;
}

@MappableClass(discriminatorValue: 'CharaCardParser')
class CharaCardParser extends Parser<int> with CharaCardParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.trainee.card;
}

@MappableClass(discriminatorValue: 'StatusSpeedParser')
class StatusSpeedParser extends Parser<int> with StatusSpeedParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.status.speed;
}

@MappableClass(discriminatorValue: 'StatusStaminaParser')
class StatusStaminaParser extends Parser<int> with StatusStaminaParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.status.stamina;
}

@MappableClass(discriminatorValue: 'StatusPowerParser')
class StatusPowerParser extends Parser<int> with StatusPowerParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.status.power;
}

@MappableClass(discriminatorValue: 'StatusGutsParser')
class StatusGutsParser extends Parser<int> with StatusGutsParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.status.guts;
}

@MappableClass(discriminatorValue: 'StatusIntelligenceParser')
class StatusIntelligenceParser extends Parser<int> with StatusIntelligenceParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.status.intelligence;
}

@MappableClass(discriminatorValue: 'TurfGroundAptitudeParser')
class TurfGroundAptitudeParser extends Parser<int> with TurfGroundAptitudeParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.ground.turf;
}

@MappableClass(discriminatorValue: 'DirtGroundAptitudeParser')
class DirtGroundAptitudeParser extends Parser<int> with DirtGroundAptitudeParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.ground.dirt;
}

@MappableClass(discriminatorValue: 'ShortRangeAptitudeParser')
class ShortRangeAptitudeParser extends Parser<int> with ShortRangeAptitudeParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.shortRange;
}

@MappableClass(discriminatorValue: 'MileRangeAptitudeParser')
class MileRangeAptitudeParser extends Parser<int> with MileRangeAptitudeParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.mileRange;
}

@MappableClass(discriminatorValue: 'MiddleRangeAptitudeParser')
class MiddleRangeAptitudeParser extends Parser<int> with MiddleRangeAptitudeParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.middleRange;
}

@MappableClass(discriminatorValue: 'LongRangeAptitudeParser')
class LongRangeAptitudeParser extends Parser<int> with LongRangeAptitudeParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.longRange;
}

@MappableClass(discriminatorValue: 'LeadPaceAptitudeParser')
class LeadPaceAptitudeParser extends Parser<int> with LeadPaceAptitudeParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.leadPace;
}

@MappableClass(discriminatorValue: 'WithPaceAptitudeParser')
class WithPaceAptitudeParser extends Parser<int> with WithPaceAptitudeParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.withPace;
}

@MappableClass(discriminatorValue: 'OffPaceAptitudeParser')
class OffPaceAptitudeParser extends Parser<int> with OffPaceAptitudeParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.offPace;
}

@MappableClass(discriminatorValue: 'LateChargeAptitudeParser')
class LateChargeAptitudeParser extends Parser<int> with LateChargeAptitudeParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.lateCharge;
}

@MappableClass(discriminatorValue: 'SkillParser')
class SkillParser extends Parser<List<Skill>> with SkillParserMappable {
  @override
  List<Skill> parse(CharaDetailRecord record) => record.skills;
}

@MappableClass(discriminatorValue: 'FactorSetParser')
class FactorSetParser extends Parser<FactorSet> with FactorSetParserMappable {
  @override
  FactorSet parse(CharaDetailRecord record) => record.factors;
}

@MappableClass(discriminatorValue: 'FansParser')
class FansParser extends Parser<int> with FansParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.fans;
}

@MappableClass(discriminatorValue: 'ForeignAptitudeParser')
class ForeignAptitudeParser extends Parser<int> with ForeignAptitudeParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.foreignAptitude ?? 0;
}

@MappableClass(discriminatorValue: 'TrainedDateParser')
class TrainedDateParser extends Parser<DateTime> with TrainedDateParserMappable {
  @override
  DateTime parse(CharaDetailRecord record) {
    return record.trainedDate.replaceAll("/", "-").toDateTime();
  }
}

@MappableClass(discriminatorValue: 'CapturedDateParser')
class CapturedDateParser extends Parser<DateTime> with CapturedDateParserMappable {
  @override
  DateTime parse(CharaDetailRecord record) {
    return record.metadata.capturedDate.toDateTime().toLocal();
  }
}

@MappableClass(discriminatorValue: 'RaceWinningCountParser')
class RaceWinningCountParser extends Parser<int> with RaceWinningCountParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.races.where((e) => e.won).length;
}

@MappableClass(discriminatorValue: 'RaceGradeWinningCountParser')
class RaceGradeWinningCountParser extends Parser<int> with RaceGradeWinningCountParserMappable {
  /// The grade tag to count wins for (e.g. "grade_g1"). Stored (not the resolved
  /// sid set) so the count follows game-data updates; sids are resolved per parse
  /// via [raceGradeSidProvider].
  final String grade;

  RaceGradeWinningCountParser({this.grade = "grade_g1"});

  @override
  int parse(CharaDetailRecord record) =>
      throw UnsupportedError("RaceGradeWinningCountParser requires module data; use parseList");

  @override
  List<int> parseList(RefBase ref, List<CharaDetailRecord> records) {
    final sids = ref.read(raceGradeSidProvider(grade));
    return records.map((r) => r.races.where((e) => e.won && sids.contains(e.title)).length).toList();
  }
}

@MappableClass(discriminatorValue: 'RecordTypeParser')
class RecordTypeParser extends Parser<int> with RecordTypeParserMappable {
  @override
  int parse(CharaDetailRecord record) {
    final recordType = record.metadata.recordType ?? RecordType.standard;
    return RecordType.values.indexOf(recordType);
  }
}

@MappableClass(discriminatorValue: 'CampaignScenarioParser')
class CampaignScenarioParser extends Parser<int> with CampaignScenarioParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.scenario.id;
}

@MappableClass(discriminatorValue: 'TraineeIdParser')
class TraineeIdParser extends Parser<String> with TraineeIdParserMappable {
  @override
  String parse(CharaDetailRecord record) => record.id;
}

@MappableClass(discriminatorValue: 'RaceStrategyParser')
class RaceStrategyParser extends Parser<int> with RaceStrategyParserMappable {
  @override
  int parse(CharaDetailRecord record) => record.metadata.strategy;
}
