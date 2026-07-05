// Covers the graded-race winning-count column: which race titles it counts
// (the selection intersected with the grade), how it counts wins, and the range
// filter. A stale selection left over after a game-data update must not count
// races that are no longer of the graded set.
//
// _targets is private, so its behavior is verified through parse().
//
// Run: .fvm/flutter_sdk/bin/flutter test test/race_grade_spec_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/spec/race_grade.dart';
import 'package:umacapture/src/chara_detail/spec/ranged_integer.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/utils.dart';

const _grade = 'grade_g1';

final _refBaseProvider = Provider<RefBase>((ref) => ref.base);

Character _chara(int card) => Character(0, 0, card, 0);

Parent _parent(int card) => Parent(_chara(card), _chara(0), _chara(0), null);

// A race in `title` that the trainee either won (finished 1st) or lost. Only the
// finishing position drives Race.won, so the other columns are dummy.
Race _race(int title, {required bool won}) => Race(title, won ? 1 : 2, 0, 0, 0, 0, 0, 0, won ? 1 : 2);

CharaDetailRecord makeRecord({required String id, required List<Race> races}) {
  final metadata = Metadata(
    '1.0.0',
    'JPN',
    RecordId(id, null, null),
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
    races,
  );
}

RaceGradeWinningCountColumnSpec makeSpec({
  IsInRangeIntegerPredicate? predicate,
  Set<int> selection = const {},
  bool hidden = false,
  String? description,
  double? width,
}) {
  return RaceGradeWinningCountColumnSpec(
    id: 'race-grade-id',
    title: 'G1 Wins',
    predicate: predicate ?? IsInRangeIntegerPredicate(),
    grade: _grade,
    selection: selection,
    hidden: hidden,
    description: description,
    width: width,
  );
}

// Runs `parse` with the grade's sid set overridden to [gradeSids].
List<int> parseWith(RaceGradeWinningCountColumnSpec spec, Set<int> gradeSids, List<CharaDetailRecord> records) {
  final container = ProviderContainer.test(overrides: [raceGradeSidProvider(_grade).overrideWithValue(gradeSids)]);
  addTearDown(container.dispose);
  return spec.parse(container.read(_refBaseProvider), records);
}

void main() {
  setUpAll(initializeMappers);

  group('RaceGradeWinningCountColumnSpec.parse targeting', () {
    final record = makeRecord(id: 'c', races: [_race(101, won: true), _race(102, won: true), _race(103, won: true)]);

    test('an empty selection counts every win of the grade', () {
      expect(parseWith(makeSpec(), {101, 102, 103}, [record]), [3]);
    });

    test('a selection narrows the count to the chosen races', () {
      expect(parseWith(makeSpec(selection: {101, 102}), {101, 102, 103}, [record]), [2]);
    });

    test('a stale selected sid no longer in the grade is not counted', () {
      // 103 was selected but the grade set now lacks it (data update).
      expect(parseWith(makeSpec(selection: {101, 103}), {101, 102}, [record]), [1]);
    });
  });

  group('RaceGradeWinningCountColumnSpec.parse counting', () {
    test('counts only wins whose title is in the target set', () {
      final record = makeRecord(
        id: 'c',
        races: [
          _race(101, won: true), // counted
          _race(101, won: false), // lost, not counted
          _race(102, won: true), // counted
          _race(999, won: true), // won but off-grade, not counted
        ],
      );
      expect(parseWith(makeSpec(), {101, 102}, [record]), [2]);
    });

    test('counts repeated wins of the same title separately', () {
      final record = makeRecord(id: 'c', races: [_race(101, won: true), _race(101, won: true)]);
      expect(parseWith(makeSpec(), {101}, [record]), [2]);
    });

    test('a record with no races counts zero', () {
      final record = makeRecord(id: 'c', races: const []);
      expect(parseWith(makeSpec(), {101}, [record]), [0]);
    });

    test('an empty record list yields an empty result', () {
      expect(parseWith(makeSpec(), {101}, const []), isEmpty);
    });
  });

  group('RaceGradeWinningCountColumnSpec.evaluate', () {
    test('an open range accepts every count', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final ref = container.read(_refBaseProvider);
      expect(makeSpec().evaluate(ref, [0, 1, 10]), [isTrue, isTrue, isTrue]);
    });

    test('a bounded range filters counts, inclusive of both ends', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final ref = container.read(_refBaseProvider);
      final spec = makeSpec(predicate: IsInRangeIntegerPredicate(min: 2, max: 5));
      expect(spec.evaluate(ref, [1, 2, 5, 6]), [isFalse, isTrue, isTrue, isFalse]);
    });
  });

  group('RaceGradeWinningCountColumnSpec.withFilterReset', () {
    test('clears the range and selection while keeping grade and display settings', () {
      final spec = makeSpec(
        predicate: IsInRangeIntegerPredicate(min: 2, max: 10),
        selection: {101, 102},
        hidden: true,
        description: 'keep me',
        width: 180.0,
      );

      final reset = spec.withFilterReset(null) as RaceGradeWinningCountColumnSpec;

      expect(reset.predicate.min, isNull);
      expect(reset.predicate.max, isNull);
      expect(reset.selection, isEmpty);
      expect(reset.grade, _grade);
      expect(reset.hidden, isTrue);
      expect(reset.description, 'keep me');
      expect(reset.width, 180.0);
    });
  });
}
