// Covers the "no evaluation value" handling for inheritance-only and
// friend-inheritance records: their evaluation and rank columns must render an
// empty (absentValueLabel) cell instead of a spurious minimum, while standard
// and friend (non-inheritance) records keep their real value.
//
// The native recognizer never reads an evaluation value for the inheritance
// layouts and leaves it at 0; here every record carries a non-zero value so a
// leaked 0 could not masquerade as "absent".
//
// Run: .fvm/flutter_sdk/bin/flutter test test/evaluation_rank_absent_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/chara_rank.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/chara_detail/spec/ranged_integer.dart';
import 'package:umacapture/src/chara_detail/spec/ranged_label.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/utils.dart';

import 'support/riverpod.dart';

// A synthetic rank ladder: evaluation < 300 -> index 0, < 1000 -> 1, < 5000 -> 2,
// otherwise the top index 3.
const _rankBorder = [300, 1000, 5000];

Character _chara(int card) => Character(0, 0, card, 0);

Parent _parent(int card) => Parent(_chara(card), _chara(0), _chara(0), null);

CharaDetailRecord _record({required RecordType type, required int evaluationValue}) {
  final metadata = Metadata(
    '1.0.0',
    'JPN',
    RecordId('id-${type.name}', null, null),
    'trainer',
    '2026-01-01T00:00:00+0900',
    '2026-01-01T00:00:00+0900',
    RecordStage.active,
    0,
    null,
    type,
  );
  return CharaDetailRecord(
    metadata,
    _chara(1),
    evaluationValue,
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

RangedIntegerColumnSpec _evaluationSpec() {
  return RangedIntegerColumnSpec(
    id: 'eval-id',
    title: 'Evaluation',
    parser: EvaluationValueParser(),
    predicate: IsInRangeIntegerPredicate(),
  );
}

CharaRankColumnSpec _rankSpec() {
  return CharaRankColumnSpec(
    id: 'rank-id',
    title: 'Rank',
    parser: EvaluationValueParser(),
    labelKey: LabelKeys.charaRank,
    predicate: IsInRangeIntegerPredicate(),
  );
}

RefBase _refWithBorder() {
  final container = ProviderContainer.test(overrides: [charaRankBorderProvider.overrideWithValue(_rankBorder)]);
  addTearDown(container.dispose);
  return container.read(refBaseProvider);
}

void main() {
  setUpAll(initializeMappers);

  group('isInheritanceOnly', () {
    test('is true only for inheritance-only and friend-inheritance', () {
      expect(_record(type: RecordType.standard, evaluationValue: 1).isInheritanceOnly, isFalse);
      expect(_record(type: RecordType.inheritanceOnly, evaluationValue: 1).isInheritanceOnly, isTrue);
      expect(_record(type: RecordType.friendStandard, evaluationValue: 1).isInheritanceOnly, isFalse);
      expect(_record(type: RecordType.friendInheritance, evaluationValue: 1).isInheritanceOnly, isTrue);
    });
  });

  group('evaluation column parse', () {
    test('yields the sentinel for inheritance records and the real value otherwise', () {
      final ref = _refWithBorder();
      final records = [
        _record(type: RecordType.standard, evaluationValue: 4200),
        _record(type: RecordType.inheritanceOnly, evaluationValue: 4200),
        _record(type: RecordType.friendStandard, evaluationValue: 4200),
        _record(type: RecordType.friendInheritance, evaluationValue: 4200),
      ];
      expect(_evaluationSpec().parse(ref, records), [4200, evaluationValueAbsent, 4200, evaluationValueAbsent]);
    });
  });

  group('rank column parse', () {
    test('yields the sentinel for inheritance records and the computed index otherwise', () {
      final ref = _refWithBorder();
      final records = [
        _record(type: RecordType.standard, evaluationValue: 4200), // < 5000 -> index 2
        _record(type: RecordType.inheritanceOnly, evaluationValue: 4200),
        _record(type: RecordType.friendStandard, evaluationValue: 250), // < 300 -> index 0
        _record(type: RecordType.friendInheritance, evaluationValue: 4200),
        _record(type: RecordType.standard, evaluationValue: 9000), // above every border -> top index 3
      ];
      expect(_rankSpec().parse(ref, records), [2, evaluationValueAbsent, 0, evaluationValueAbsent, 3]);
    });

    test('renders an empty cell for the sentinel without touching the label map', () {
      final ref = _refWithBorder();
      // The sentinel path must short-circuit before the base `labels[value]`
      // lookup, so no labelMapProvider override is needed here.
      final cell = _rankSpec().plutoCell(ref, evaluationValueAbsent);
      expect(cell.getUserData<RangedLabelCellData>()!.label, absentValueLabel);
    });
  });

  group('single-record display', () {
    test('evaluationValueLabel is the placeholder for inheritance records only', () {
      expect(_record(type: RecordType.standard, evaluationValue: 4200).evaluationValueLabel, 4200.toNumberString());
      expect(_record(type: RecordType.inheritanceOnly, evaluationValue: 4200).evaluationValueLabel, absentValueLabel);
      expect(
        _record(type: RecordType.friendStandard, evaluationValue: 4200).evaluationValueLabel,
        4200.toNumberString(),
      );
      expect(_record(type: RecordType.friendInheritance, evaluationValue: 4200).evaluationValueLabel, absentValueLabel);
    });
  });

  group('csv export', () {
    test('the ranged-integer cell exports the placeholder for the sentinel', () {
      expect(RangedIntegerCellData(evaluationValueAbsent).csv, absentValueLabel);
      expect(RangedIntegerCellData(4200).csv, '4200');
    });
  });
}
