import 'package:dart_json_mapper/dart_json_mapper.dart';

import '/src/chara_detail/chara_detail_record.dart';

@jsonSerializable
enum ParserType {
  evaluationValue,
  charaRank,
  charaCard,
  statusSpeed,
  statusStamina,
  statusPower,
  statusGuts,
  statusIntelligence,
  aptitudesTurf,
  aptitudesDirt,
  aptitudesShortRange,
  aptitudesMileRange,
  aptitudesMiddleRange,
  aptitudesLongRange,
  aptitudesLeadPace,
  aptitudesWithPace,
  aptitudesOffPace,
  aptitudesLateCharge,
  skill,
  factor,
}

@jsonSerializable
@Json(discriminatorProperty: 'type')
abstract class Parser {
  final ParserType type;

  Parser(this.type);

  // TODO: This should use generics, but will cause serialize to fail.
  dynamic parse(CharaDetailRecord record);
}

@jsonSerializable
@Json(discriminatorValue: ParserType.evaluationValue)
class EvaluationValueParser extends Parser {
  EvaluationValueParser() : super(ParserType.evaluationValue);

  @override
  int parse(CharaDetailRecord record) => record.evaluationValue;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.charaRank)
class CharaRankParser extends Parser {
  final List<int> borders;

  CharaRankParser(this.borders) : super(ParserType.charaRank);

  @override
  int parse(CharaDetailRecord record) {
    return borders.indexWhere((e) => e >= record.evaluationValue);
  }
}

@jsonSerializable
@Json(discriminatorValue: ParserType.charaCard)
class CharaCardParser extends Parser {
  CharaCardParser() : super(ParserType.charaCard);

  @override
  int parse(CharaDetailRecord record) => record.trainee.card;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.statusSpeed)
class StatusSpeedParser extends Parser {
  StatusSpeedParser() : super(ParserType.statusSpeed);

  @override
  int parse(CharaDetailRecord record) => record.status.speed;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.statusStamina)
class StatusStaminaParser extends Parser {
  StatusStaminaParser() : super(ParserType.statusStamina);

  @override
  int parse(CharaDetailRecord record) => record.status.stamina;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.statusPower)
class StatusPowerParser extends Parser {
  StatusPowerParser() : super(ParserType.statusPower);

  @override
  int parse(CharaDetailRecord record) => record.status.power;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.statusGuts)
class StatusGutsParser extends Parser {
  StatusGutsParser() : super(ParserType.statusGuts);

  @override
  int parse(CharaDetailRecord record) => record.status.guts;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.statusIntelligence)
class StatusIntelligenceParser extends Parser {
  StatusIntelligenceParser() : super(ParserType.statusIntelligence);

  @override
  int parse(CharaDetailRecord record) => record.status.intelligence;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesTurf)
class TurfGroundAptitudeParser extends Parser {
  TurfGroundAptitudeParser() : super(ParserType.aptitudesTurf);

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.ground.turf;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesDirt)
class DirtGroundAptitudeParser extends Parser {
  DirtGroundAptitudeParser() : super(ParserType.aptitudesDirt);

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.ground.dirt;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesShortRange)
class ShortRangeAptitudeParser extends Parser {
  ShortRangeAptitudeParser() : super(ParserType.aptitudesShortRange);

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.shortRange;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesMileRange)
class MileRangeAptitudeParser extends Parser {
  MileRangeAptitudeParser() : super(ParserType.aptitudesMileRange);

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.mileRange;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesMiddleRange)
class MiddleRangeAptitudeParser extends Parser {
  MiddleRangeAptitudeParser() : super(ParserType.aptitudesMiddleRange);

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.middleRange;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesLongRange)
class LongRangeAptitudeParser extends Parser {
  LongRangeAptitudeParser() : super(ParserType.aptitudesLongRange);

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.longRange;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesLeadPace)
class LeadPaceAptitudeParser extends Parser {
  LeadPaceAptitudeParser() : super(ParserType.aptitudesLeadPace);

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.leadPace;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesWithPace)
class WithPaceAptitudeParser extends Parser {
  WithPaceAptitudeParser() : super(ParserType.aptitudesWithPace);

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.withPace;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesOffPace)
class OffPaceAptitudeParser extends Parser {
  OffPaceAptitudeParser() : super(ParserType.aptitudesOffPace);

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.offPace;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesLateCharge)
class LateChargeAptitudeParser extends Parser {
  LateChargeAptitudeParser() : super(ParserType.aptitudesLateCharge);

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.lateCharge;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.skill)
class SkillParser extends Parser {
  SkillParser() : super(ParserType.skill);

  @override
  List<Skill> parse(CharaDetailRecord record) => record.skills;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.factor)
class FactorSetParser extends Parser {
  FactorSetParser() : super(ParserType.factor);

  @override
  FactorSet parse(CharaDetailRecord record) => record.factors;
}
