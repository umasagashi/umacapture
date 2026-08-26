// Shared CharaDetailRecord fixtures for the domain-logic tests.
//
// Records built here carry only the fields the domain logic reads (card,
// factors, family parent cards, record-id links, races); every other field is a
// dummy zero value. Direct construction needs no mappers; [recordFromFixture]
// does (call initializeMappers() in setUpAll).
import 'dart:convert';
import 'dart:io';

import 'package:umacapture/src/chara_detail/chara_detail_record.dart';

/// A [Character] carrying only its [card] id; the other slots are irrelevant to
/// the domain logic these fixtures exercise.
Character chara(int card) => Character(0, 0, card, 0);

/// A [Parent] whose own card is [card]; its grandparents are zeroed.
Parent parentOf(int card) => Parent(chara(card), chara(0), chara(0), null);

/// A win (finish position 1) of race title [title]; pass `won: false` for a
/// non-winning entry. Other race fields are irrelevant to relation-bonus scoring.
Race race(int title, {bool won = true}) => Race(title, 0, 0, 0, 0, 0, 0, 0, won ? 1 : 2);

/// Builds a record carrying only the fields dedup and the inheritance resolver
/// read; everything else is dummy.
CharaDetailRecord makeRecord({
  required String id,
  required int card,
  List<Factor> self = const [],
  int parent1Card = 0,
  List<Factor> parent1 = const [],
  int parent2Card = 0,
  List<Factor> parent2 = const [],
  String? parent1Id,
  String? parent2Id,
  int? relationBonus,
  List<Race> races = const [],
  RecordType recordType = RecordType.standard,
  // The recognizer leaves this empty when it could not read the date off the
  // game screen, so '' is a real input shape and not a malformed fixture.
  String trainedDate = '2026/01/01',
  int fans = 0,
  int evaluationValue = 0,
}) {
  final metadata = Metadata(
    '1.0.0',
    'JPN',
    RecordId(id, parent1Id, parent2Id),
    'trainer',
    '2026-01-01T00:00:00+0900',
    '2026-01-01T00:00:00+0900',
    RecordStage.active,
    0,
    relationBonus,
    recordType,
  );
  return CharaDetailRecord(
    metadata,
    chara(card),
    evaluationValue,
    const CharacterStatus(0, 0, 0, 0, 0),
    const AptitudeSet(GroundAptitude(0, 0), DistanceAptitude(0, 0, 0, 0), StyleAptitude(0, 0, 0, 0)),
    const <Skill>[],
    FactorSet(self, parent1, parent2),
    const <SupportCard>[],
    Family(parentOf(parent1Card), parentOf(parent2Card)),
    fans,
    const Scenario(0),
    trainedDate,
    races,
  );
}

/// A copy of the shared fixture record with its id and captured date replaced,
/// so a test can hold multiple distinct real records. Requires initializeMappers().
CharaDetailRecord recordFromFixture(String id, String capturedDate) {
  final map = (jsonDecode(File('test/fixtures/chara_detail_record.json').readAsStringSync()) as Map)
      .cast<String, dynamic>();
  final metadata = (map['metadata'] as Map).cast<String, dynamic>();
  (metadata['record_id'] as Map)['self'] = id;
  metadata['captured_date'] = capturedDate;
  map['metadata'] = metadata;
  return CharaDetailRecordMapper.fromMap(map);
}
