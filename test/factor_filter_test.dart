// Regression test for the factor aggregate filter element modes, focused on the
// `countOnly` ("因子数") mode.
// Run: .fvm/flutter_sdk/bin/flutter test test/factor_filter_test.dart
//
// `countOnly` counts factor possession while ignoring the star rating: a slot
// holding the factor counts as one regardless of its star, so it behaves like a
// star>=1 threshold on the count metric. In `mixed` logic it sums the presence
// of every selected factor, giving an "M of N selected factors" filter.
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/spec/factor.dart';

AggregateFactorSetPredicate _predicate({
  required Set<int> query,
  required FactorSetLogicMode logic,
  required FactorSearchSubjectMode subject,
  required FactorSearchElementMode mode,
  int star = 1,
  int count = 1,
}) {
  return AggregateFactorSetPredicate(
    query: query,
    logic: logic,
    subject: subject,
    element: FactorSearchElement(mode: mode, star: star, count: count),
    notation: FactorNotation(mode: FactorNotationMode.nameStarTotal, max: 3),
  );
}

FactorSet _set({List<Factor> self = const [], List<Factor> parent1 = const [], List<Factor> parent2 = const []}) {
  return FactorSet(self, parent1, parent2);
}

void main() {
  group('countOnly is an M-of-N filter that ignores star magnitude', () {
    test('mixed + trainee counts distinct possessed factors among the selection', () {
      final predicate = _predicate(
        query: {1, 2, 3},
        logic: FactorSetLogicMode.mixed,
        subject: FactorSearchSubjectMode.trainee,
        mode: FactorSearchElementMode.countOnly,
        count: 2,
      );
      // Trainee holds factors 1 and 2 (parents are ignored for trainee subject).
      final record = _set(self: [const Factor(1, 1), const Factor(2, 3)], parent1: [const Factor(3, 3)]);
      expect(predicate.apply(record), isTrue);
      expect(predicate.copyWith(element: predicate.element.copyWith(count: 3)).apply(record), isFalse);
    });

    test('a high star counts the same as a single star', () {
      final predicate = _predicate(
        query: {1, 2},
        logic: FactorSetLogicMode.mixed,
        subject: FactorSearchSubjectMode.trainee,
        mode: FactorSearchElementMode.countOnly,
        count: 1,
      );
      // Only factor 1 present, at star 5: still counts as one possessed factor.
      expect(predicate.apply(_set(self: [const Factor(1, 5)])), isTrue);
      expect(
        predicate.copyWith(element: predicate.element.copyWith(count: 2)).apply(_set(self: [const Factor(1, 5)])),
        isFalse,
      );
    });

    test('family subject counts possession across self and parent slots', () {
      final predicate = _predicate(
        query: {1},
        logic: FactorSetLogicMode.anyOf,
        subject: FactorSearchSubjectMode.family,
        mode: FactorSearchElementMode.countOnly,
        count: 2,
      );
      final record = _set(self: [const Factor(1, 1)], parent1: [const Factor(1, 1)]);
      expect(predicate.apply(record), isTrue);
      expect(predicate.copyWith(element: predicate.element.copyWith(count: 3)).apply(record), isFalse);
    });

    test('count 1 is equivalent to "possesses the factor"', () {
      final predicate = _predicate(
        query: {7},
        logic: FactorSetLogicMode.anyOf,
        subject: FactorSearchSubjectMode.trainee,
        mode: FactorSearchElementMode.countOnly,
        count: 1,
      );
      expect(predicate.apply(_set(self: [const Factor(7, 1)])), isTrue);
      expect(predicate.apply(_set(self: [const Factor(8, 3)])), isFalse);
    });
  });

  test('countOnly is coerced to starOnly when count modes are not allowed', () {
    // anyOf + trainee is a single-factor context: count modes are disabled and
    // any attempt to use them is normalized away by checked().
    final coerced = _predicate(
      query: {1},
      logic: FactorSetLogicMode.anyOf,
      subject: FactorSearchSubjectMode.trainee,
      mode: FactorSearchElementMode.countOnly,
      count: 2,
    ).copyWith();
    expect(coerced.element.mode, FactorSearchElementMode.starOnly);
  });
}
