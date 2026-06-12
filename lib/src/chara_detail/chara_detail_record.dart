import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';

import '/src/core/json_adapter.dart';
import '/src/core/path_entity.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';

part 'chara_detail_record.mapper.dart';

@MappableClass(caseStyle: CaseStyle.snakeCase)
class Character extends JsonEquatable with CharacterMappable {
  final int icon;
  final int character;
  final int card;
  final int rank;

  const Character(this.icon, this.character, this.card, this.rank);

  @override
  List<Object?> properties() => [icon, character, card, rank];
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class CharacterStatus extends JsonEquatable with CharacterStatusMappable {
  final int speed;
  final int stamina;
  final int power;
  final int guts;
  final int intelligence;

  const CharacterStatus(this.speed, this.stamina, this.power, this.guts, this.intelligence);

  @override
  List<Object?> properties() => [speed, stamina, power, guts, intelligence];
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class GroundAptitude extends JsonEquatable with GroundAptitudeMappable {
  final int turf;
  final int dirt;

  const GroundAptitude(this.turf, this.dirt);

  @override
  List<Object?> properties() => [turf, dirt];
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class DistanceAptitude extends JsonEquatable with DistanceAptitudeMappable {
  final int shortRange;
  final int mileRange;
  final int middleRange;
  final int longRange;

  const DistanceAptitude(this.shortRange, this.mileRange, this.middleRange, this.longRange);

  List<int> get flatten => [shortRange, mileRange, middleRange, longRange];

  @override
  List<Object?> properties() => [shortRange, mileRange, middleRange, longRange];
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class StyleAptitude extends JsonEquatable with StyleAptitudeMappable {
  final int leadPace; // [JP] 逃げ
  final int withPace; // [JP] 先行
  final int offPace; // [JP] 差し
  final int lateCharge; // [JP] 追込

  const StyleAptitude(this.leadPace, this.withPace, this.offPace, this.lateCharge);

  @override
  List<Object?> properties() => [leadPace, withPace, offPace, lateCharge];
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class AptitudeSet extends JsonEquatable with AptitudeSetMappable {
  final GroundAptitude ground;
  final DistanceAptitude distance;
  final StyleAptitude style;

  const AptitudeSet(this.ground, this.distance, this.style);

  @override
  List<Object?> properties() => [ground, distance, style];
}

@MappableClass(caseStyle: CaseStyle.snakeCase, ignoreNull: true)
class Skill extends JsonEquatable with SkillMappable {
  final int id;
  final int? level;

  const Skill({required this.id, this.level});

  @override
  List<Object?> properties() => [id, level];
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class Factor extends JsonEquatable with FactorMappable {
  final int id;
  final int star;

  const Factor(this.id, this.star);

  @override
  List<Object?> properties() => [id, star];
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class FactorSet extends JsonEquatable with FactorSetMappable {
  final List<Factor> self;
  final List<Factor> parent1;
  final List<Factor> parent2;

  const FactorSet(this.self, this.parent1, this.parent2);

  @override
  List<Object?> properties() => [self, parent1, parent2];

  List<Factor> get flattened => [...self, ...parent1, ...parent2];

  Set<int> get uniqueIds => flattened.map((e) => e.id).toSet();

  List<List<Factor>> toList() => [self, parent1, parent2];
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class SupportCard extends JsonEquatable with SupportCardMappable {
  final int id;
  final int rank;
  final int level;

  const SupportCard(this.id, this.rank, this.level);

  @override
  List<Object?> properties() => [id, rank, level];
}

@MappableClass(caseStyle: CaseStyle.snakeCase, ignoreNull: true)
class Parent extends JsonEquatable with ParentMappable {
  final Character self;
  final Character parent1;
  final Character parent2;
  final bool? rental;

  const Parent(this.self, this.parent1, this.parent2, this.rental);

  @override
  List<Object?> properties() => [self, parent1, parent2, rental];
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class Family extends JsonEquatable with FamilyMappable {
  final Parent parent1;
  final Parent parent2;

  const Family(this.parent1, this.parent2);

  @override
  List<Object?> properties() => [parent1, parent2];
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class Scenario extends JsonEquatable with ScenarioMappable {
  final int id;

  const Scenario(this.id);

  @override
  List<Object?> properties() => [id];
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class Race extends JsonEquatable with RaceMappable {
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

  bool get won => position == 1;

  @override
  List<Object?> properties() => [title, place, ground, distance, variation, weather, strategy, turn, position];
}

@MappableClass(caseStyle: CaseStyle.snakeCase, ignoreNull: true)
class RecordId extends JsonEquatable with RecordIdMappable {
  final String self;
  final String? parent1;
  final String? parent2;

  const RecordId(this.self, this.parent1, this.parent2);

  @override
  List<Object?> properties() => [self, parent1, parent2];
}

@MappableEnum()
enum RecordStage { active }

// In the saved data (record.json), record_type is PascalCase, e.g. "Standard" / "FriendStandard".
// The order must stay aligned with the native RecordType enum, since record_type columns map
// the value to a label by index.
@MappableEnum(caseStyle: CaseStyle.pascalCase)
enum RecordType { standard, inheritanceOnly, friendStandard, friendInheritance }

extension RecordTypeTranslation on RecordType {
  /// Leaf translation key for this record type, under
  /// `pages.chara_detail.columns.record_type.values`.
  ///
  /// The single source for the type-to-key mapping; callers prepend their own
  /// namespace. The exhaustive `switch` makes a forgotten case a compile error.
  String get translationKey => switch (this) {
    RecordType.standard => "standard",
    RecordType.inheritanceOnly => "inheritance_only",
    RecordType.friendStandard => "friend_standard",
    RecordType.friendInheritance => "friend_inheritance",
  };
}

/// Sentinel `trainer_id` for records whose owner is unknown.
///
/// A friend's record captured from the player's own game exposes no recoverable
/// trainer id, so it is stored with this nil UUID rather than the capturing
/// player's id. Only externally shared/imported friend records carry the
/// friend's real id. Mirrors `kUnknownTrainerId` in the native recognizer.
const String unknownTrainerId = "00000000-0000-0000-0000-000000000000";

@MappableClass(caseStyle: CaseStyle.snakeCase, ignoreNull: true)
class Metadata extends JsonEquatable with MetadataMappable {
  final String formatVersion;
  final String region;
  final RecordId recordId;
  final String trainerId;
  final String capturedDate;
  final String recognizerVersion;
  final RecordStage stage;
  final int strategy;
  final int? relationBonus;
  final RecordType? recordType;

  const Metadata(
    this.formatVersion,
    this.region,
    this.recordId,
    this.trainerId,
    this.capturedDate,
    this.recognizerVersion,
    this.stage,
    this.strategy,
    this.relationBonus,
    this.recordType,
  );

  @override
  List<Object?> properties() => [
    formatVersion,
    region,
    recordId,
    trainerId,
    capturedDate,
    recognizerVersion,
    stage,
    strategy,
    relationBonus,
  ];
}

/// Outcome of attempting to load a single record directory.
///
/// Returned by [CharaDetailRecord.load] so the (potentially isolate-bound)
/// loader can report what happened as data, leaving any UI surfacing to the
/// caller on the main isolate.
sealed class RecordLoadResult {
  const RecordLoadResult();
}

/// The record decoded successfully.
class RecordLoaded extends RecordLoadResult {
  final CharaDetailRecord record;

  const RecordLoaded(this.record);
}

/// The record could not be decoded and its directory was quarantined.
///
/// [destination] is the quarantine folder it was moved to, or `null` if the
/// move itself failed (e.g. a file lock), leaving the directory in place.
class RecordQuarantined extends RecordLoadResult {
  final DirectoryPath? destination;

  const RecordQuarantined(this.destination);
}

// ignoreNull keeps persisted record.json byte-compatible with the native writer,
// which omits empty optionals. Without it, toMap() emits "foreign_aptitude": null
// / "uaf_wins": null, which the native recognizer cannot read back on re-recognize.
@MappableClass(caseStyle: CaseStyle.snakeCase, ignoreNull: true)
class CharaDetailRecord extends JsonEquatable with CharaDetailRecordMappable {
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
  final int? foreignAptitude;
  final int? uafWins;
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
    this.foreignAptitude,
    this.uafWins,
    this.trainedDate,
    this.races,
  );

  @override
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
    foreignAptitude,
    uafWins,
    trainedDate,
    races,
  ];

  String get id => metadata.recordId.self;

  /// Whether this is a friend's (practice-partner) record, full or inheritance-only.
  bool get isFriend =>
      metadata.recordType == RecordType.friendStandard || metadata.recordType == RecordType.friendInheritance;

  FilePath get traineeIconPath => DirectoryPath(id).filePath("trainee.jpg");

  DateTime get trainedDateAsDateTime => trainedDate.replaceAll("/", "-").toDateTime();

  /// Loads the record in [directory], quarantining it if it cannot be decoded.
  ///
  /// Returns a [RecordLoaded] on success, or a [RecordQuarantined] if decoding
  /// failed. This runs inside a `compute` isolate on the bulk/reload paths, so
  /// it performs no UI side effects: surfacing the outcome (a toast) is the
  /// caller's responsibility on the main isolate, driven by the returned value.
  static RecordLoadResult load(DirectoryPath directory) {
    try {
      final content = directory.filePath("record.json").readAsStringSync();
      return RecordLoaded(CharaDetailRecordMapper.fromJson(content));
    } catch (exception, stackTrace) {
      logger.e("Failed to load record.json.", exception, stackTrace);
      logger.i(directory.listSync().map((e) => e.name).join(", "));
      captureException(exception, stackTrace);
    }
    // A record that fails to decode (unknown enum value, missing required
    // field, legacy/hand-edited file) is moved aside instead of being deleted,
    // so its images and json survive for later inspection or recovery.
    return RecordQuarantined(quarantine(directory));
  }

  /// Moves a record directory whose `record.json` could not be decoded into a
  /// sibling `quarantine/` folder, preserving it for recovery.
  ///
  /// Records live at `<root>/active/<id>`; the quarantine folder is the sibling
  /// `<root>/quarantine/`, which lies outside the scanned `active/` tree so a
  /// quarantined record is not re-loaded (and re-quarantined) on restart. A name
  /// collision with an already-quarantined id is resolved with an `_<n>` suffix.
  /// Returns the destination, or `null` if the move failed.
  static DirectoryPath? quarantine(DirectoryPath directory) {
    final quarantineRoot = directory.parent.parent / "quarantine";
    var destination = quarantineRoot / directory.name;
    for (var n = 1; destination.existsSync(); n++) {
      destination = quarantineRoot / "${directory.name}_$n";
    }
    return directory.moveSyncSafe(destination);
  }

  /// Determines if another record represents the same character based on key attributes.
  /// This method partially compares only the attributes necessary for distinguishing records.
  bool isSameChara(CharaDetailRecord other) {
    const DeepCollectionEquality equality = DeepCollectionEquality();
    return [
      trainee == other.trainee,
      evaluationValue == other.evaluationValue,
      status == other.status,
      aptitudes == other.aptitudes,
      equality.equals(skills, other.skills),
      factors == other.factors,
    ].everyIn();
  }

  bool isObsoleted(ModuleVersion moduleVersion, bool includeCurrentVersion) {
    final recordVersion = metadata.recognizerVersion.toDateTime();
    final capturedDate = metadata.capturedDate.toDateTime();
    final obsoleted =
        recordVersion != moduleVersion.recognizerVersion && capturedDate.isAfter(moduleVersion.recognizerVersion);
    return obsoleted || (includeCurrentVersion && recordVersion == moduleVersion.recognizerVersion);
  }

  bool isSupported(ModuleVersion moduleVersion) {
    final capturedDate = metadata.capturedDate.toDateTime();
    return capturedDate.isAfter(moduleVersion.minimumVersion);
  }
}
