import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';

import '/src/core/json_adapter.dart';
import '/src/core/path_entity.dart';
import '/src/core/fs/record_directory_transaction.dart';
import '/src/core/fs/record_id_safety.dart';
import '/src/core/fs/record_mutation_lock.dart';
import '/src/core/fs/record_recovery_gate.dart';
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

/// Placeholder shown where a record has no value for a field (e.g. the
/// evaluation value and rank of an inheritance-only / friend-inheritance record).
/// A neutral symbol, not localized text: it means "no value", not "minimum".
const String absentValueLabel = "-";

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

/// A record whose decode failed *and* whose quarantine move failed with it, so
/// the directory is still standing where the scan found it.
///
/// Exists so that outcome can be *counted* rather than only announced: the bulk
/// scans put one of these in [RecordScanResult.unavailable], which is what makes
/// the store say its view is incomplete and puts the record on the persistent
/// banner. Reported as a toast alone it was gone the moment it scrolled away,
/// while the record stayed missing from duplicate detection and inheritance
/// resolution for the rest of the session — and the remedy is the same rescan
/// the banner already offers, because a rescan re-runs the decode and therefore
/// re-attempts the very move that failed.
final class RecordQuarantineFailed implements Exception {
  const RecordQuarantineFailed(this.id);

  /// The record directory that could not be moved aside.
  final String id;

  @override
  String toString() =>
      'RecordQuarantineFailed: "$id" could not be decoded and could not be moved '
      'into quarantine/, so it is still in place and still unreadable';
}

/// Outcome of scanning a whole record root.
///
/// [results] holds one [RecordLoadResult] per record directory the scan managed
/// to open; [unavailable] maps the id of every record it could **not** open to
/// the error that refused it. Together they account for every directory scanned,
/// so a caller can never lose a record without being handed the reason.
///
/// Deliberately *not* a third [RecordLoadResult] variant. Only the bulk scan can
/// produce an unavailable record — the single-record loaders rethrow, which is
/// their contract — so widening the per-record result would force a case its own
/// producer cannot return onto the three single-record switches that can never
/// see it, while the two bulk call sites (which filter with `whereType`) would
/// still compile after silently dropping it. The shape instead mirrors
/// `WebRecordPersistenceResult.failures`, which reports the same "lost, and why"
/// on the write side.
typedef RecordScanResult = ({List<RecordLoadResult> results, Map<String, Object> unavailable});

/// A decoded `record.json` claimed an id other than its containing directory.
/// Mutation authority is always derived from the directory leaf.
final class RecordIdMismatch implements Exception {
  const RecordIdMismatch({required this.expectedId, required this.actualId});

  final String expectedId;
  final String actualId;

  @override
  String toString() => 'RecordIdMismatch: expected "$expectedId", decoded "$actualId".';
}

/// File name of the always-retained trainee icon inside a record's directory.
///
/// Single source of truth shared by [CharaDetailRecord.traineeIconPath] and the
/// source-agnostic `traineeIconPathIn` helper in storage.dart.
const traineeIconFileName = "trainee.jpg";

// ignoreNull keeps persisted record.json byte-compatible with the native writer,
// which omits empty optionals. Without it, toMap() would emit optional fields as
// explicit nulls (e.g. "relation_bonus": null), which the native recognizer cannot
// read back on re-recognize.
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

  String get id => metadata.recordId.self;

  /// Whether this is a friend's (practice-partner) record, full or inheritance-only.
  bool get isFriend =>
      metadata.recordType == RecordType.friendStandard || metadata.recordType == RecordType.friendInheritance;

  /// Whether this record carries no evaluation value (nor a derived rank).
  ///
  /// The inheritance-only and friend-inheritance layouts have no evaluation value
  /// on screen, so the native recognizer never reads one and leaves it at the
  /// default 0. Mirrors `isInheritanceOnly` in the native recognizer so display
  /// code can render an empty ([absentValueLabel]) cell instead of a spurious
  /// minimum. Friend (non-inheritance) records do carry a real value.
  bool get isInheritanceOnly =>
      metadata.recordType == RecordType.inheritanceOnly || metadata.recordType == RecordType.friendInheritance;

  /// The evaluation value formatted for display, or [absentValueLabel] when the
  /// record has none ([isInheritanceOnly]). Shared by the single-record dialogs
  /// (archive/delete/rating/memo) so they all render the absent case identically.
  String get evaluationValueLabel => isInheritanceOnly ? absentValueLabel : evaluationValue.toNumberString();

  FilePath get traineeIconPath => DirectoryPath(id).filePath(traineeIconFileName);

  /// The date this trainee finished training, or `null` when the recognizer
  /// could not read one.
  ///
  /// Unlike `captured_date`, which this app writes itself, `trained_date` is OCR
  /// of the game screen and is left as an empty string when the date could not
  /// be read -- measured at about 2% of captured records, so "unknown" is a
  /// routine state rather than an error. Nullable so that callers placing a
  /// record in time can leave it out instead of placing it at a stand-in date
  /// decades before every real record.
  DateTime? get trainedDateAsDateTimeOrNull => trainedDate.replaceAll("/", "-").toDateTimeOrNull();

  /// Loads the record in [directory], quarantining it if it cannot be decoded.
  ///
  /// Returns a [RecordLoaded] on success, or a [RecordQuarantined] if decoding
  /// failed. This runs on a worker isolate on the bulk/reload paths, so it
  /// performs no UI side effects: surfacing the outcome (a toast) is the
  /// caller's responsibility on the main isolate, driven by the returned value.
  static RecordLoadResult load(DirectoryPath directory) {
    try {
      final content = directory.filePath("record.json").readAsStringSync();
      final record = CharaDetailRecordMapper.fromJson(content);
      _validateDirectoryId(directory, record);
      return RecordLoaded(record);
    } catch (exception, stackTrace) {
      return _quarantineOnFailure(directory, exception, stackTrace);
    }
  }

  /// Asynchronous counterpart of [load] for the web/main-isolate loader.
  ///
  /// Reads `record.json` through the async FS backend (OPFS on web) instead of
  /// the sync one, but keeps the decode and the `record-load-deletes-on-failure`
  /// quarantine branch identical to [load], so a decode failure still moves the
  /// record aside rather than deleting it.
  static Future<RecordLoadResult> loadAsync(
    DirectoryPath directory, {
    RecordRecoveryGate? recoveryGate,
    RecordMutationLock? mutationLock,
  }) {
    final gate = recoveryGate ?? createPlatformRecordRecoveryGate(mutationLock: mutationLock);
    return gate.runForRecord(directory.parent.parent.parent, directory.name, () => loadAsyncUnlocked(directory));
  }

  /// Variant of [loadAsync] for a caller which already owns [directory]'s
  /// record-mutation lock. Keeping this separate prevents a decode failure
  /// from trying to acquire the same non-reentrant Web Lock a second time.
  static Future<RecordLoadResult> loadAsyncUnlocked(DirectoryPath directory) async {
    try {
      final content = await directory.filePath("record.json").readAsString();
      final record = CharaDetailRecordMapper.fromJson(content);
      _validateDirectoryId(directory, record);
      return RecordLoaded(record);
    } catch (exception, stackTrace) {
      return _quarantineOnFailureAsyncUnlocked(directory, exception, stackTrace);
    }
  }

  static void _validateDirectoryId(DirectoryPath directory, CharaDetailRecord record) {
    if (record.id != directory.name) {
      throw RecordIdMismatch(expectedId: directory.name, actualId: record.id);
    }
  }

  /// Logs [exception], reports it, and quarantines [directory].
  ///
  /// Shared by [load] and [loadAsync] so the decode-failure handling stays
  /// identical across the sync and async loaders. A record that fails to decode
  /// (unknown enum value, missing required field, legacy/hand-edited file) is
  /// moved aside instead of being deleted, so its images and json survive for
  /// later inspection or recovery.
  static RecordLoadResult _quarantineOnFailure(DirectoryPath directory, Object exception, StackTrace stackTrace) {
    logger.e("Failed to load record.json.", exception, stackTrace);
    try {
      logger.i(directory.listSync().map((e) => e.name).join(", "));
    } catch (_) {
      // The listing is diagnostic only; the entry may not be a listable
      // directory (vanished concurrently, or not a directory at all), and
      // that must not escalate one bad record into a scan-wide failure.
    }
    captureException(exception, stackTrace);
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
  ///
  /// The destination name comes from [safeRecordDirectoryName] rather than from
  /// [directory] directly, so it is always a *single* segment. Quarantine is the
  /// one mover that can be handed a name no writer of this app would have
  /// produced — an unusable name is a reason to quarantine, not a reason to
  /// refuse — and joining such a name onto the quarantine root is what would
  /// file the record below `quarantine/` instead of in it.
  static DirectoryPath? quarantine(DirectoryPath directory) {
    final quarantineRoot = directory.parent.parent / "quarantine";
    final name = safeRecordDirectoryName(directory.name);
    var destination = quarantineRoot / name;
    for (var n = 1; destination.existsSync(); n++) {
      destination = quarantineRoot / "${name}_$n";
    }
    return directory.moveSyncSafe(destination);
  }

  /// Asynchronous counterpart of [_quarantineOnFailure], for a caller which
  /// already owns [directory]'s record-mutation lock.
  ///
  /// Reached from [loadAsyncUnlocked] and quarantines through
  /// [quarantineAsyncUnlocked], so the decode-failure path never asks for the
  /// same non-reentrant Web Lock a second time.
  static Future<RecordLoadResult> _quarantineOnFailureAsyncUnlocked(
    DirectoryPath directory,
    Object exception,
    StackTrace stackTrace,
  ) async {
    logger.e("Failed to load record.json.", exception, stackTrace);
    try {
      logger.i(await directory.list().map((e) => e.name).join(", "));
    } catch (_) {
      // Diagnostic-only; the directory may already have changed.
    }
    captureException(exception, stackTrace);
    return RecordQuarantined(await quarantineAsyncUnlocked(directory));
  }

  /// Asynchronous counterpart of [quarantine] for the web / main-isolate loader,
  /// for a caller which already holds a lock covering [directory].
  ///
  /// That is [directory]'s own record-mutation lock for the decode-failure path,
  /// and the **exclusive root lock** for the store scan's unusable-name path,
  /// which cannot name a per-record lock after the id it is quarantining *for*.
  /// The root scope is the wider of the two — every per-record acquisition takes
  /// the root name shared first — so both callers are covered, and neither is an
  /// unlocked mutation.
  ///
  /// Resolves the collision-free destination via async existence probes and moves
  /// the directory with [DirectoryPath.moveAsyncSafe] (a copy-then-delete, since
  /// OPFS has no directory rename). Returns the destination, or `null` if the
  /// move failed.
  ///
  /// The destination probe and the move stay in the same critical section, so a
  /// collision cannot select the same suffix in another tab.
  ///
  /// The name is folded through [safeRecordDirectoryName] for the reason spelled
  /// out there: `WebVfs` splits the joined path on `\` as well as `/`, so a
  /// directory whose name carries a separator would be filed one level below
  /// `quarantine/` — out of sight of the only reader that folder has.
  ///
  /// Deliberately *not* a [RecordDirectoryTransaction]: every way this can be
  /// interrupted leaves the record whole. A partial copy leaves `active/<id>`
  /// untouched and a stray tree under `quarantine/`; a copy that finished but a
  /// delete that did not leaves the record in both places. Either way the next
  /// scan fails the same decode and quarantines it again to the next free
  /// `_<n>` suffix, so nothing is lost and the store converges on its own. A
  /// transaction can only protect a move whose commit deletes bytes that exist
  /// nowhere else, which is what archiving does and this does not.
  static Future<DirectoryPath?> quarantineAsyncUnlocked(DirectoryPath directory) async {
    final quarantineRoot = directory.parent.parent / "quarantine";
    final name = safeRecordDirectoryName(directory.name);
    var destination = quarantineRoot / name;
    for (var n = 1; await destination.exists(); n++) {
      destination = quarantineRoot / "${name}_$n";
    }
    return directory.moveAsyncSafe(destination);
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

  /// Number of leading self-factors the probe and a stored record must agree on (id and star) for
  /// the early duplicate check to fire, for a capture of the given record [type].
  ///
  /// The factors are read top-to-bottom / left-then-right exactly as the full pipeline reads
  /// [FactorSet.self], so a recapture reproduces this many leading entries reliably. The threshold
  /// stays below the count visible before scrolling so the bottom-most rows — which can be clipped or
  /// misrecognized on a single, non-stitched frame — never affect the result, while remaining unique
  /// enough to avoid collisions. [RecordType.friendStandard] uses a shifted factor-tab layout that
  /// exposes fewer reliable rows, so it keeps a lower threshold; the other types show more rows and
  /// use a higher, more collision-resistant one.
  static int factorProbeMatchThreshold(RecordType? type) {
    return type == RecordType.friendStandard ? 10 : 14;
  }

  /// Length of the leading run of self-factors that exactly match [probeSelf] (id and star).
  ///
  /// The early duplicate check recognizes only the self-factors visible on the factor tab before
  /// scrolling; this counts how many of them line up with this record's own factors from the top.
  int leadingFactorProbeMatch(List<Factor> probeSelf) {
    final self = factors.self;
    final limit = probeSelf.length < self.length ? probeSelf.length : self.length;
    var common = 0;
    while (common < limit && self[common] == probeSelf[common]) {
      common++;
    }
    return common;
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
