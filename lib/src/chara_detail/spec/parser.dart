import 'package:dart_json_mapper/dart_json_mapper.dart';

import '/src/chara_detail/chara_detail_record.dart';

@jsonSerializable
@Json(discriminatorProperty: 'type')
abstract class Parser<T> {
  String get type => runtimeType.toString();

  T parse(CharaDetailRecord record);
}

@jsonSerializable
@Json(discriminatorValue: "EvaluationValueParser")
class EvaluationValueParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.evaluationValue;
}

@jsonSerializable
@Json(discriminatorValue: "CharaCardParser")
class CharaCardParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.trainee.card;
}

@jsonSerializable
@Json(discriminatorValue: "StatusSpeedParser")
class StatusSpeedParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.status.speed;
}

@jsonSerializable
@Json(discriminatorValue: "StatusStaminaParser")
class StatusStaminaParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.status.stamina;
}

@jsonSerializable
@Json(discriminatorValue: "StatusPowerParser")
class StatusPowerParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.status.power;
}

@jsonSerializable
@Json(discriminatorValue: "StatusGutsParser")
class StatusGutsParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.status.guts;
}

@jsonSerializable
@Json(discriminatorValue: "StatusIntelligenceParser")
class StatusIntelligenceParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.status.intelligence;
}

@jsonSerializable
@Json(discriminatorValue: "TurfGroundAptitudeParser")
class TurfGroundAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.ground.turf;
}

@jsonSerializable
@Json(discriminatorValue: "DirtGroundAptitudeParser")
class DirtGroundAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.ground.dirt;
}

@jsonSerializable
@Json(discriminatorValue: "ShortRangeAptitudeParser")
class ShortRangeAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.shortRange;
}

@jsonSerializable
@Json(discriminatorValue: "MileRangeAptitudeParser")
class MileRangeAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.mileRange;
}

@jsonSerializable
@Json(discriminatorValue: "MiddleRangeAptitudeParser")
class MiddleRangeAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.middleRange;
}

@jsonSerializable
@Json(discriminatorValue: "LongRangeAptitudeParser")
class LongRangeAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.longRange;
}

@jsonSerializable
@Json(discriminatorValue: "LeadPaceAptitudeParser")
class LeadPaceAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.leadPace;
}

@jsonSerializable
@Json(discriminatorValue: "WithPaceAptitudeParser")
class WithPaceAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.withPace;
}

@jsonSerializable
@Json(discriminatorValue: "OffPaceAptitudeParser")
class OffPaceAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.offPace;
}

@jsonSerializable
@Json(discriminatorValue: "LateChargeAptitudeParser")
class LateChargeAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.lateCharge;
}

@jsonSerializable
@Json(discriminatorValue: "SkillParser")
class SkillParser extends Parser<List<Skill>> {
  @override
  List<Skill> parse(CharaDetailRecord record) => record.skills;
}

@jsonSerializable
@Json(discriminatorValue: "FactorSetParser")
class FactorSetParser extends Parser<FactorSet> {
  @override
  FactorSet parse(CharaDetailRecord record) => record.factors;
}

@jsonSerializable
@Json(discriminatorValue: "FansParser")
class FansParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.fans;
}

@jsonSerializable
@Json(discriminatorValue: "TrainedDateParser")
class TrainedDateParser extends Parser<DateTime> {
  @override
  DateTime parse(CharaDetailRecord record) {
    return DateTime.parse(record.trainedDate.replaceAll("/", "-"));
  }
}

@jsonSerializable
@Json(discriminatorValue: "TraineeIdParser")
class TraineeIdParser extends Parser<String> {
  @override
  String parse(CharaDetailRecord record) => record.id;
}

@jsonSerializable
@Json(discriminatorValue: "RaceStrategyParser")
class RaceStrategyParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.metadata.strategy;
}
