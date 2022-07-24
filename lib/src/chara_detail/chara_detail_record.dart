import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:equatable/equatable.dart';

import '/src/core/utils.dart';

@jsonSerializable
abstract class JsonEquatable extends Equatable {
  const JsonEquatable();

  @override
  @JsonProperty(ignore: true)
  bool get stringify => true;

  @override
  @JsonProperty(ignore: true)
  // ignore: hash_and_equals
  int get hashCode => runtimeType.hashCode ^ identityHashCode(this);

  @override
  @JsonProperty(ignore: true)
  List<Object?> get props => properties();

  List<Object?> properties();
}

@jsonSerializable
class Character extends JsonEquatable {
  final int icon;
  final int character;
  final int card;
  final int rank;

  const Character(this.icon, this.character, this.card, this.rank);

  @override
  List<Object?> properties() => [icon, character, card, rank];
}

@jsonSerializable
class CharacterStatus extends JsonEquatable {
  final int speed;
  final int stamina;
  final int power;
  final int guts;
  final int intelligence;

  const CharacterStatus(this.speed, this.stamina, this.power, this.guts, this.intelligence);

  @override
  List<Object?> properties() => [speed, stamina, power, guts, intelligence];
}

@jsonSerializable
class GroundAptitude extends JsonEquatable {
  final int turf;
  final int dirt;

  const GroundAptitude(this.turf, this.dirt);

  @override
  List<Object?> properties() => [turf, dirt];
}

@jsonSerializable
class DistanceAptitude extends JsonEquatable {
  final int shortRange;
  final int mileRange;
  final int middleRange;
  final int longRange;

  const DistanceAptitude(this.shortRange, this.mileRange, this.middleRange, this.longRange);

  @override
  List<Object?> properties() => [shortRange, mileRange, middleRange, longRange];
}

@jsonSerializable
class StyleAptitude extends JsonEquatable {
  final int leadPace; // [JP] 逃げ
  final int withPace; // [JP] 先行
  final int offPace; // [JP] 差し
  final int lateCharge; // [JP] 追込

  const StyleAptitude(this.leadPace, this.withPace, this.offPace, this.lateCharge);

  @override
  List<Object?> properties() => [leadPace, withPace, offPace, lateCharge];
}

@jsonSerializable
class AptitudeSet extends JsonEquatable {
  final GroundAptitude ground;
  final DistanceAptitude distance;
  final StyleAptitude style;

  const AptitudeSet(this.ground, this.distance, this.style);

  @override
  List<Object?> properties() => [ground, distance, style];
}

@jsonSerializable
@Json(ignoreNullMembers: true)
class Skill extends JsonEquatable {
  final int id;
  final int? level;

  const Skill({required this.id, this.level});

  @override
  List<Object?> properties() => [id, level];
}

@jsonSerializable
class Factor extends JsonEquatable {
  final int id;
  final int star;

  const Factor(this.id, this.star);

  @override
  List<Object?> properties() => [id, star];
}

@jsonSerializable
class FactorSet extends JsonEquatable {
  final List<Factor> self;
  final List<Factor> parent1;
  final List<Factor> parent2;

  const FactorSet(this.self, this.parent1, this.parent2);

  @override
  List<Object?> properties() => [self, parent1, parent2];
}

@jsonSerializable
class SupportCard extends JsonEquatable {
  final int id;
  final int rank;
  final int level;

  const SupportCard(this.id, this.rank, this.level);

  @override
  List<Object?> properties() => [id, rank, level];
}

@jsonSerializable
@Json(ignoreNullMembers: true)
class Parent extends JsonEquatable {
  final Character self;
  final Character parent1;
  final Character parent2;
  final bool? rental;

  const Parent(this.self, this.parent1, this.parent2, this.rental);

  @override
  List<Object?> properties() => [self, parent1, parent2, rental];
}

@jsonSerializable
class Family extends JsonEquatable {
  final Parent parent1;
  final Parent parent2;

  const Family(this.parent1, this.parent2);

  @override
  List<Object?> properties() => [parent1, parent2];
}

@jsonSerializable
class Scenario extends JsonEquatable {
  final int id;

  const Scenario(this.id);

  @override
  List<Object?> properties() => [id];
}

@jsonSerializable
class Race extends JsonEquatable {
  final int title;
  final int place;
  final int ground;
  final int distance;
  final int variation;
  final int weather;
  final int strategy;
  final int turn;
  final int position;

  const Race(
    this.title,
    this.place,
    this.ground,
    this.distance,
    this.variation,
    this.weather,
    this.strategy,
    this.turn,
    this.position,
  );

  @override
  List<Object?> properties() => [
        title,
        place,
        ground,
        distance,
        variation,
        weather,
        strategy,
        turn,
        position,
      ];
}

@jsonSerializable
@Json(ignoreNullMembers: true)
class RecordId extends JsonEquatable {
  final String self;
  final String? parent1;
  final String? parent2;

  const RecordId(this.self, this.parent1, this.parent2);

  @override
  List<Object?> properties() => [self, parent1, parent2];
}

@jsonSerializable
@Json(ignoreNullMembers: true)
class Metadata extends JsonEquatable {
  final String version;
  final String region;
  final RecordId recordId;
  final String trainerId;
  final String capturedDate;
  final String lastModifiedDate;
  final int? strategy;
  final int? relationBonus;
  final bool? isArchived;

  const Metadata(
    this.version,
    this.region,
    this.recordId,
    this.trainerId,
    this.capturedDate,
    this.lastModifiedDate,
    this.strategy,
    this.relationBonus,
    this.isArchived,
  );

  @override
  @JsonProperty(ignore: true)
  List<Object?> properties() => [
        version,
        region,
        recordId,
        trainerId,
        capturedDate,
        lastModifiedDate,
        strategy,
        relationBonus,
        isArchived,
      ];
}

@jsonSerializable
class CharaDetailRecord extends JsonEquatable {
  final Metadata metadata;

  final Character trainee;
  final int evaluationValue;
  final CharacterStatus status;
  final AptitudeSet aptitudes;
  final List<Skill> skills;
  final FactorSet factors;
  final List<SupportCard> supportCards;
  final Family family;
  final int fans;
  final Scenario scenario;
  final String trainedDate;
  final List<Race> races;

  const CharaDetailRecord(
    this.metadata,
    this.trainee,
    this.evaluationValue,
    this.status,
    this.aptitudes,
    this.skills,
    this.factors,
    this.supportCards,
    this.family,
    this.fans,
    this.scenario,
    this.trainedDate,
    this.races,
  );

  @override
  @JsonProperty(ignore: true)
  List<Object?> properties() => [
        metadata,
        trainee,
        evaluationValue,
        status,
        aptitudes,
        skills,
        factors,
        supportCards,
        family,
        fans,
        scenario,
        trainedDate,
        races,
      ];

  @JsonProperty(ignore: true)
  String get traineeIconPath => "${metadata.recordId.self}/trainee.jpg";

  static Future<CharaDetailRecord> readFromFile(
    String path, {
    DeserializationOptions option = const DeserializationOptions(caseStyle: CaseStyle.snake),
  }) async {
    return File(path).readAsString().then((body) => JsonMapper.deserialize<CharaDetailRecord>(body, option)!);
  }

  bool isSameChara(CharaDetailRecord other) {
    const DeepCollectionEquality equality = DeepCollectionEquality();
    return [
      // No metadata comparison.
      trainee == other.trainee,
      evaluationValue == other.evaluationValue,
      status == other.status,
      aptitudes == other.aptitudes,
      equality.equals(skills, other.skills),
      factors == other.factors,
      equality.equals(supportCards, other.supportCards),
      family == other.family,
      fans == other.fans,
      scenario == other.scenario,
      trainedDate == other.trainedDate,
      equality.equals(races, other.races),
    ].everyIn();
  }
}
