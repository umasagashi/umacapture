// Covers the relation-bonus column: the RelationBonusStatus value type (which
// distinguishes a confirmed number from a "-" placeholder or a "≧ n" lower
// bound) and the column's range filter. The confirmed-vs-lower-bound
// distinction is the whole point of the column, so a confirmed 0 must never
// read the same as a not-yet-known 0.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/relation_bonus_spec_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/ranged_integer.dart';
import 'package:umacapture/src/chara_detail/spec/relation_bonus.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';

import 'support/riverpod.dart';

Character _chara(int card) => Character(0, 0, card, 0);

Parent _parent(int card) => Parent(_chara(card), _chara(0), _chara(0), null);

// A record carrying only the stored relation bonus and no parent links, so its
// lineage resolves to zero linked ancestors (an incomplete status).
CharaDetailRecord makeRecord({required String id, required int? relationBonus}) {
  final metadata = Metadata(
    '1.0.0',
    'JPN',
    RecordId(id, null, null),
    'trainer',
    '2026-01-01T00:00:00+0900',
    '2026-01-01T00:00:00+0900',
    RecordStage.active,
    0,
    relationBonus,
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

RelationBonusColumnSpec makeSpec({
  IsInRangeIntegerPredicate? predicate,
  bool hidden = false,
  String? description,
  double? width,
}) {
  return RelationBonusColumnSpec(
    id: 'relation-bonus-id',
    title: 'Relation Bonus',
    predicate: predicate ?? IsInRangeIntegerPredicate(),
    hidden: hidden,
    description: description,
    width: width,
  );
}

void main() {
  setUpAll(initializeMappers);

  group('RelationBonusStatus', () {
    test('unlinked (no stored value) shows the placeholder and is unconfirmed', () {
      const status = RelationBonusStatus(null, 0);
      expect(status.isComplete, isFalse);
      expect(status.isConfirmed, isFalse);
      expect(status.filterValue, 0);
      expect(status.label, '-');
    });

    test('a full lineage confirms the stored value', () {
      const status = RelationBonusStatus(50, 6);
      expect(status.isComplete, isTrue);
      expect(status.isConfirmed, isTrue);
      expect(status.filterValue, 50);
      expect(status.label, '50');
    });

    test('an incomplete lineage marks the value as a lower bound', () {
      const status = RelationBonusStatus(50, 3);
      expect(status.isComplete, isFalse);
      expect(status.isConfirmed, isFalse);
      expect(status.filterValue, 50);
      expect(status.label, '≧ 50');
    });

    test('a confirmed 0 is distinct from a not-yet-known 0', () {
      const confirmed = RelationBonusStatus(0, 6);
      expect(confirmed.isConfirmed, isTrue);
      expect(confirmed.label, '0');

      const unknown = RelationBonusStatus(null, 6);
      expect(unknown.isConfirmed, isFalse);
      expect(unknown.label, '-');
    });
  });

  group('RelationBonusColumnSpec.evaluate', () {
    test('an open range accepts every value', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final ref = container.read(refBaseProvider);

      final result = makeSpec().evaluate(ref, const [
        RelationBonusStatus(null, 0),
        RelationBonusStatus(100, 6),
        RelationBonusStatus(50, 3),
      ]);
      expect(result, [isTrue, isTrue, isTrue]);
    });

    test('a bounded range filters on filterValue, inclusive of both ends', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final ref = container.read(refBaseProvider);

      final spec = makeSpec(predicate: IsInRangeIntegerPredicate(min: 50, max: 100));
      final result = spec.evaluate(ref, const [
        RelationBonusStatus(40, 6), // below min
        RelationBonusStatus(50, 6), // at min
        RelationBonusStatus(75, 3), // incomplete but in range (uses filterValue)
        RelationBonusStatus(100, 6), // at max
        RelationBonusStatus(110, 6), // above max
      ]);
      expect(result, [isFalse, isTrue, isTrue, isTrue, isFalse]);
    });
  });

  group('RelationBonusColumnSpec.parse', () {
    test('pairs the stored bonus with the live linked-ancestor count', () {
      final record = makeRecord(id: 'c', relationBonus: 30);
      final container = ProviderContainer.test(
        overrides: [
          allRecordsByIdProvider.overrideWithValue({record.id: record}),
        ],
      );
      addTearDown(container.dispose);
      final ref = container.read(refBaseProvider);

      final statuses = makeSpec().parse(ref, [record]);

      expect(statuses.single.value, 30);
      // No parent links, so the lineage is incomplete and the value is a bound.
      expect(statuses.single.linkedAncestors, 0);
      expect(statuses.single.isConfirmed, isFalse);
    });
  });

  group('RelationBonusColumnSpec.withFilterReset', () {
    test('clears the range while keeping display settings', () {
      final spec = makeSpec(
        predicate: IsInRangeIntegerPredicate(min: 50, max: 100),
        hidden: true,
        description: 'keep me',
        width: 200.0,
      );

      final reset = spec.withFilterReset(null) as RelationBonusColumnSpec;

      expect(reset.predicate.min, isNull);
      expect(reset.predicate.max, isNull);
      expect(reset.hidden, isTrue);
      expect(reset.description, 'keep me');
      expect(reset.width, 200.0);
    });
  });

  group('RelationBonusColumnSpec.measuredText', () {
    test('reports the status label from the cell for row-height measurement', () {
      final spec = makeSpec();

      TrinaCell cellFor(RelationBonusStatus status) =>
          TrinaCell(value: status.filterValue)..setUserData(RelationBonusCellData(status));

      expect(spec.measuredText(cellFor(const RelationBonusStatus(75, 6)), '75'), '75');
      expect(spec.measuredText(cellFor(const RelationBonusStatus(75, 3)), '75'), '≧ 75');
      expect(spec.measuredText(cellFor(const RelationBonusStatus(null, 0)), '0'), '-');
      // With no attached cell data, it falls back to the formatted value.
      expect(spec.measuredText(null, 'fallback'), 'fallback');
    });
  });
}
