// Regression test for the factor cell notation (display) formatter.
// Run: .fvm/flutter_sdk/bin/flutter test test/factor_notation_test.dart
//
// The `count` metric must be evaluated per factor (presence per slot) and then
// summed. Summing stars first and thresholding afterwards would miscount
// factors that share a slot: two factors each with a star-2 self would collapse
// to a single self star-4 and count as one, not two.
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/factor.dart';

QueriedFactor _factor({int self = 0, int parent1 = 0, int parent2 = 0}) {
  return QueriedFactor(id: 1, self: self, parent1: parent1, parent2: parent2);
}

void main() {
  group('FactorNotationMode decomposition', () {
    test('showsName splits name modes from value-only modes', () {
      final withName = {
        FactorNotationMode.nameOnly,
        FactorNotationMode.nameStarTotal,
        FactorNotationMode.nameStarEach,
        FactorNotationMode.nameCountTotal,
        FactorNotationMode.nameCountEach,
      };
      for (final mode in FactorNotationMode.values) {
        expect(mode.showsName, withName.contains(mode), reason: '$mode');
      }
    });

    test('showsValue is false only for nameOnly', () {
      for (final mode in FactorNotationMode.values) {
        expect(mode.showsValue, mode != FactorNotationMode.nameOnly, reason: '$mode');
      }
    });

    test('metric and granularity map to the 2x2 grid', () {
      expect(FactorNotationMode.nameStarTotal.metric, FactorNotationMetric.star);
      expect(FactorNotationMode.nameStarTotal.granularity, FactorNotationGranularity.total);
      expect(FactorNotationMode.starEach.metric, FactorNotationMetric.star);
      expect(FactorNotationMode.starEach.granularity, FactorNotationGranularity.individual);
      expect(FactorNotationMode.countTotal.metric, FactorNotationMetric.count);
      expect(FactorNotationMode.countTotal.granularity, FactorNotationGranularity.total);
      expect(FactorNotationMode.nameCountEach.metric, FactorNotationMetric.count);
      expect(FactorNotationMode.nameCountEach.granularity, FactorNotationGranularity.individual);
    });
  });

  group('single-factor notation', () {
    final factor = _factor(self: 3, parent1: 1, parent2: 0);

    test('star total sums the slots', () {
      expect(factor.notation(FactorNotationMetric.star, FactorNotationGranularity.total), '4');
    });

    test('star individual keeps the slots', () {
      expect(factor.notation(FactorNotationMetric.star, FactorNotationGranularity.individual), '3/1/0');
    });

    test('count total counts present slots regardless of star', () {
      expect(factor.notation(FactorNotationMetric.count, FactorNotationGranularity.total), '2');
    });

    test('count individual is a per-slot presence flag', () {
      expect(factor.notation(FactorNotationMetric.count, FactorNotationGranularity.individual), '1/1/0');
    });
  });

  group('aggregate notation counts each factor before summing', () {
    // Two factors that both occupy the self slot with star 2.
    final factors = [_factor(self: 2), _factor(self: 2)];

    test('count total is the number of occupied slots, not the star sum', () {
      expect(QueriedFactor.notationOf(factors, FactorNotationMetric.count, FactorNotationGranularity.total), '2');
    });

    test('star total remains the star sum', () {
      expect(QueriedFactor.notationOf(factors, FactorNotationMetric.star, FactorNotationGranularity.total), '4');
    });

    test('count individual sums presence per slot across factors', () {
      final mixed = [_factor(self: 2, parent1: 1), _factor(self: 3)];
      expect(
        QueriedFactor.notationOf(mixed, FactorNotationMetric.count, FactorNotationGranularity.individual),
        '2/1/0',
      );
    });
  });
}
