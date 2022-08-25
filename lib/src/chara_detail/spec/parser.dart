import 'package:dart_json_mapper/dart_json_mapper.dart';

import '/src/chara_detail/chara_detail_record.dart';

@jsonSerializable
enum ParserType {
  evaluationValue,
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
  trainedDate,
  traineeId,
}

@jsonSerializable
@Json(discriminatorProperty: 'type')
abstract class Parser {
  ParserType get type;

  // TODO: This should use generics, but will cause serialize to fail.
  dynamic parse(CharaDetailRecord record);
}

@jsonSerializable
@Json(discriminatorValue: ParserType.evaluationValue)
class EvaluationValueParser extends Parser {
  @override
  ParserType get type => ParserType.evaluationValue;

  @override
  int parse(CharaDetailRecord record) => record.evaluationValue;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.charaCard)
class CharaCardParser extends Parser {
  @override
  ParserType get type => ParserType.charaCard;

  @override
  int parse(CharaDetailRecord record) => record.trainee.card;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.statusSpeed)
class StatusSpeedParser extends Parser {
  @override
  ParserType get type => ParserType.statusSpeed;

  @override
  int parse(CharaDetailRecord record) => record.status.speed;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.statusStamina)
class StatusStaminaParser extends Parser {
  @override
  ParserType get type => ParserType.statusStamina;

  @override
  int parse(CharaDetailRecord record) => record.status.stamina;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.statusPower)
class StatusPowerParser extends Parser {
  @override
  ParserType get type => ParserType.statusPower;

  @override
  int parse(CharaDetailRecord record) => record.status.power;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.statusGuts)
class StatusGutsParser extends Parser {
  @override
  ParserType get type => ParserType.statusGuts;

  @override
  int parse(CharaDetailRecord record) => record.status.guts;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.statusIntelligence)
class StatusIntelligenceParser extends Parser {
  @override
  ParserType get type => ParserType.statusIntelligence;

  @override
  int parse(CharaDetailRecord record) => record.status.intelligence;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesTurf)
class TurfGroundAptitudeParser extends Parser {
  @override
  ParserType get type => ParserType.aptitudesTurf;

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.ground.turf;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesDirt)
class DirtGroundAptitudeParser extends Parser {
  @override
  ParserType get type => ParserType.aptitudesDirt;

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.ground.dirt;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesShortRange)
class ShortRangeAptitudeParser extends Parser {
  @override
  ParserType get type => ParserType.aptitudesShortRange;

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.shortRange;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesMileRange)
class MileRangeAptitudeParser extends Parser {
  @override
  ParserType get type => ParserType.aptitudesMileRange;

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.mileRange;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesMiddleRange)
class MiddleRangeAptitudeParser extends Parser {
  @override
  ParserType get type => ParserType.aptitudesMiddleRange;

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.middleRange;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesLongRange)
class LongRangeAptitudeParser extends Parser {
  @override
  ParserType get type => ParserType.aptitudesLongRange;

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.distance.longRange;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesLeadPace)
class LeadPaceAptitudeParser extends Parser {
  @override
  ParserType get type => ParserType.aptitudesLeadPace;

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.leadPace;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesWithPace)
class WithPaceAptitudeParser extends Parser {
  @override
  ParserType get type => ParserType.aptitudesWithPace;

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.withPace;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesOffPace)
class OffPaceAptitudeParser extends Parser {
  @override
  ParserType get type => ParserType.aptitudesOffPace;

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.offPace;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.aptitudesLateCharge)
class LateChargeAptitudeParser extends Parser {
  @override
  ParserType get type => ParserType.aptitudesLateCharge;

  @override
  int parse(CharaDetailRecord record) => record.aptitudes.style.lateCharge;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.skill)
class SkillParser extends Parser {
  @override
  ParserType get type => ParserType.skill;

  @override
  List<Skill> parse(CharaDetailRecord record) => record.skills;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.factor)
class FactorSetParser extends Parser {
  @override
  ParserType get type => ParserType.factor;

  @override
  FactorSet parse(CharaDetailRecord record) => record.factors;
}

@jsonSerializable
@Json(discriminatorValue: ParserType.trainedDate)
class TrainedDateParser extends Parser {
  @override
  ParserType get type => ParserType.trainedDate;

  @override
  DateTime parse(CharaDetailRecord record) {
    return DateTime.parse(record.trainedDate.replaceAll("/", "-"));
  }
}

@jsonSerializable
@Json(discriminatorValue: ParserType.traineeId)
class TraineeIdParser extends Parser {
  @override
  ParserType get type => ParserType.traineeId;

  @override
  String parse(CharaDetailRecord record) => record.id;
}
