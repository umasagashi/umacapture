import 'package:dart_json_mapper/dart_json_mapper.dart';

import '/src/chara_detail/chara_detail_record.dart';

@jsonSerializable
@Json(discriminatorProperty: 'type')
abstract class Parser<T> {
  String? type;

  T parse(CharaDetailRecord record);
}

@jsonSerializable
class EvaluationValueParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.evaluationValue;
}

@jsonSerializable
class CharaRankParser extends Parser<int> {
  @JsonProperty(ignore: true)
  final List<int> borders;

  CharaRankParser(this.borders);

  @override
  int parse(CharaDetailRecord record) {
    return borders.indexWhere((e) => e >= record.evaluationValue);
  }
}

@jsonSerializable
class CharaCardParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.trainee.card;
}

@jsonSerializable
class StatusSpeedParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.status.speed;
}

@jsonSerializable
class StatusStaminaParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.status.stamina;
}

@jsonSerializable
class StatusPowerParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.status.power;
}

@jsonSerializable
class StatusGutsParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.status.guts;
}

@jsonSerializable
class StatusIntelligenceParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.status.intelligence;
}

@jsonSerializable
class TurfGroundAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.ground.turf;
}

@jsonSerializable
class DirtGroundAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.ground.dirt;
}

@jsonSerializable
class ShortRangeAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.shortRange;
}

@jsonSerializable
class MileRangeAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.mileRange;
}

@jsonSerializable
class MiddleRangeAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.middleRange;
}

@jsonSerializable
class LongRangeAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.longRange;
}

@jsonSerializable
class LeadPaceAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.leadPace;
}

@jsonSerializable
class WithPaceAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.withPace;
}

@jsonSerializable
class OffPaceAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.offPace;
}

@jsonSerializable
class LateChargeAptitudeParser extends Parser<int> {
  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.lateCharge;
}

@jsonSerializable
class SkillParser extends Parser<List<Skill>> {
  @override
  List<Skill> parse(CharaDetailRecord record) => record.skills;
}

@jsonSerializable
class FactorSetParser extends Parser<FactorSet> {
  @override
  FactorSet parse(CharaDetailRecord record) => record.factors;
}
