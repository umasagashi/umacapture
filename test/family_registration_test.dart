// Verifies the family-registration ancestor walk: which of the six ancestor
// slots (two parents, four grandparents) resolve to records present in
// storage, in display order, plus the count-based filter predicate.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/family_registration_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/spec/family_registration.dart';
import 'package:umacapture/src/core/mapper_init.dart';

Character _chara(int card) => Character(0, 0, card, 0);

Parent _parent(int card) => Parent(_chara(card), _chara(0), _chara(0), null);

// Builds a record carrying only the fields the ancestor walk reads (the
// record-id links); everything else is dummy.
CharaDetailRecord makeRecord({required String id, String? parent1Id, String? parent2Id}) {
  final metadata = Metadata(
    '1.0.0',
    'JPN',
    RecordId(id, parent1Id, parent2Id),
    'trainer',
    '2026-01-01T00:00:00+0900',
    '2026-01-01T00:00:00+0900',
    RecordStage.active,
    0,
    null,
    RecordType.standard,
  );
  return CharaDetailRecord(
    metadata,
    _chara(1),
    0,
    const CharacterStatus(0, 0, 0, 0, 0),
    const AptitudeSet(GroundAptitude(0, 0), DistanceAptitude(0, 0, 0, 0), StyleAptitude(0, 0, 0, 0)),
    const <Skill>[],
    const FactorSet([], [], []),
    const <SupportCard>[],
    Family(_parent(0), _parent(0)),
    0,
    const Scenario(0),
    '2026/01/01',
    const <Race>[],
  );
}

Map<String, CharaDetailRecord> byId(List<CharaDetailRecord> records) {
  return {for (final record in records) record.id: record};
}

void main() {
  setUpAll(initializeMappers);

  group('resolveRegisteredAncestors', () {
    test('no parent links yields no registered slots', () {
      final record = makeRecord(id: 'c');

      final result = resolveRegisteredAncestors(record, byId([record]));

      expect(result, isEmpty);
    });

    test('both parents registered without grandparents', () {
      final left = makeRecord(id: 'l');
      final right = makeRecord(id: 'r');
      final child = makeRecord(id: 'c', parent1Id: 'l', parent2Id: 'r');

      final result = resolveRegisteredAncestors(child, byId([child, left, right]));

      expect(result.map((e) => e.slot), [FamilySlot.parent1, FamilySlot.parent2]);
      expect(result.map((e) => e.recordId), ['l', 'r']);
    });

    test('full tree yields all six slots in display order', () {
      final records = [
        makeRecord(id: 'c', parent1Id: 'l', parent2Id: 'r'),
        makeRecord(id: 'l', parent1Id: 'll', parent2Id: 'lr'),
        makeRecord(id: 'r', parent1Id: 'rl', parent2Id: 'rr'),
        makeRecord(id: 'll'),
        makeRecord(id: 'lr'),
        makeRecord(id: 'rl'),
        makeRecord(id: 'rr'),
      ];

      final result = resolveRegisteredAncestors(records.first, byId(records));

      expect(result.map((e) => e.slot), FamilySlot.values);
      expect(result.map((e) => e.recordId), ['l', 'll', 'lr', 'r', 'rl', 'rr']);
    });

    test('unregistered parent hides its grandparent slots', () {
      // Left parent link is absent, so even existing left-side grandparents
      // are unreachable; only the right side is walked.
      final records = [
        makeRecord(id: 'c', parent2Id: 'r'),
        makeRecord(id: 'r', parent1Id: 'rl', parent2Id: 'rr'),
        makeRecord(id: 'rl'),
        makeRecord(id: 'rr'),
      ];

      final result = resolveRegisteredAncestors(records.first, byId(records));

      expect(result.map((e) => e.slot), [FamilySlot.parent2, FamilySlot.grandparent21, FamilySlot.grandparent22]);
    });

    test('parent link to a deleted record counts as unregistered for the whole side', () {
      final records = [makeRecord(id: 'c', parent1Id: 'gone', parent2Id: 'r'), makeRecord(id: 'r')];

      final result = resolveRegisteredAncestors(records.first, byId(records));

      expect(result.map((e) => e.slot), [FamilySlot.parent2]);
    });

    test('grandparent link to a deleted record skips only that slot', () {
      final records = [
        makeRecord(id: 'c', parent1Id: 'l'),
        makeRecord(id: 'l', parent1Id: 'gone', parent2Id: 'lr'),
        makeRecord(id: 'lr'),
      ];

      final result = resolveRegisteredAncestors(records.first, byId(records));

      expect(result.map((e) => e.slot), [FamilySlot.parent1, FamilySlot.grandparent12]);
    });

    test('4/6 example: parents plus one grandparent per side', () {
      final records = [
        makeRecord(id: 'c', parent1Id: 'l', parent2Id: 'r'),
        makeRecord(id: 'l', parent1Id: 'll'),
        makeRecord(id: 'r', parent1Id: 'rl'),
        makeRecord(id: 'll'),
        makeRecord(id: 'rl'),
      ];

      final result = resolveRegisteredAncestors(records.first, byId(records));

      expect(result.map((e) => e.slot), [
        FamilySlot.parent1,
        FamilySlot.grandparent11,
        FamilySlot.parent2,
        FamilySlot.grandparent21,
      ]);
    });
  });

  group('FamilyRegistrationPredicate', () {
    test('accepts every count by default', () {
      final predicate = FamilyRegistrationPredicate.any();

      for (var count = 0; count <= 6; count++) {
        expect(predicate.apply(count), isTrue);
      }
    });

    test('rejects only the listed counts', () {
      final predicate = FamilyRegistrationPredicate(rejects: {0, 6});

      expect(predicate.apply(0), isFalse);
      expect(predicate.apply(3), isTrue);
      expect(predicate.apply(6), isFalse);
    });
  });
}
