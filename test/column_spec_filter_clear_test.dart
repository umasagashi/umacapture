// Regression test for the per-column "reset filter" action (approach B):
// withFilterReset restores a column's DEFAULT filter — the preset for a
// preset-built column (rebuilt via builderSpecOf), or "accept every row" otherwise
// — while preserving the display settings (title, width, hidden, description).
// Run: .fvm/flutter_sdk/bin/flutter test test/column_spec_filter_clear_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/builder.dart';
import 'package:umacapture/src/chara_detail/spec/factor.dart';
import 'package:umacapture/src/chara_detail/spec/logic.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/chara_detail/spec/ranged_label.dart';
import 'package:umacapture/src/chara_detail/spec/ranged_integer.dart';
import 'package:umacapture/src/chara_detail/spec/script.dart';
import 'package:umacapture/src/chara_detail/spec/simple_label.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/utils.dart';

/// Exposes a [RefBase] so `builderSpecOf` (which takes one) can run in tests.
final _refBaseProvider = Provider<RefBase>((ref) => ref.base);

void main() {
  setUpAll(initializeMappers);

  group('preset columns reset to their rebuilt preset (approach B)', () {
    test('a ranged-label preset restores its min, keeping display settings', () {
      // Stub the builder catalog with a single preset builder; its build() needs
      // no providers, so no label/game data env is required.
      final container = ProviderContainer.test(
        overrides: [
          columnBuilderProvider.overrideWithValue([
            RangedLabelColumnBuilder(
              title: 'apt',
              category: ColumnCategory.aptitude,
              labelKey: LabelKeys.aptitude,
              parser: EvaluationValueParser(),
              min: 7,
              builderId: 'apt_mid',
            ),
          ]),
        ],
      );
      addTearDown(container.dispose);
      final ref = container.read(_refBaseProvider);

      // A column created from that preset, but with the filter edited away.
      final spec = RangedLabelColumnSpec(
        id: 'id-1',
        title: '中距離',
        parser: EvaluationValueParser(),
        labelKey: LabelKeys.aptitude,
        predicate: IsInRangeIntegerPredicate(min: 2),
        hidden: true,
        description: 'note',
        width: 240.0,
        builderId: 'apt_mid',
      );

      final preset = builderSpecOf(ref, spec);
      final reset = spec.withFilterReset(preset) as RangedLabelColumnSpec;
      expect(reset.predicate.min, 7); // restored to the preset, not accept-all
      // Display settings + the preset link survive the reset.
      expect(reset.title, '中距離');
      expect(reset.hidden, isTrue);
      expect(reset.description, 'note');
      expect(reset.width, 240.0);
      expect(reset.builderId, 'apt_mid');
    });

    test('a factor preset restores its query (dynamic ids rebuilt from the builder)', () {
      final container = ProviderContainer.test(
        overrides: [
          columnBuilderProvider.overrideWithValue([
            FilteredFactorColumnBuilder(
              title: 'f',
              category: ColumnCategory.factor,
              parser: FactorSetParser(),
              initialIds: {1, 2},
              initialStar: 1,
              builderId: 'factor_x',
            ),
          ]),
        ],
      );
      addTearDown(container.dispose);
      final ref = container.read(_refBaseProvider);

      final spec = FactorColumnSpec(
        id: 'id-2',
        title: '青因子',
        parser: FactorSetParser(),
        predicate: AggregateFactorSetPredicate.any(),
        builderId: 'factor_x',
      );

      final reset = spec.withFilterReset(builderSpecOf(ref, spec)) as FactorColumnSpec;
      expect(reset.predicate.query, unorderedEquals({1, 2}));
    });

    test('an unknown builderId falls back to accept-all', () {
      final container = ProviderContainer.test(overrides: [columnBuilderProvider.overrideWithValue([])]);
      addTearDown(container.dispose);
      final ref = container.read(_refBaseProvider);

      final spec = RangedLabelColumnSpec(
        id: 'id-3',
        title: 'x',
        parser: EvaluationValueParser(),
        labelKey: LabelKeys.aptitude,
        predicate: IsInRangeIntegerPredicate(min: 3),
        builderId: 'gone',
      );
      // builderSpecOf returns null (no matching builder) → accept-all.
      expect(builderSpecOf(ref, spec), isNull);
      final reset = spec.withFilterReset(null) as RangedLabelColumnSpec;
      expect(reset.predicate.min, isNull);
    });
  });

  group('non-preset filters reset to accept-all', () {
    test('a column with builderId=null resets to accept-all', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final ref = container.read(_refBaseProvider);

      final spec = SimpleLabelColumnSpec(
        id: 'id-4',
        title: 's',
        parser: EvaluationValueParser(),
        labelKey: LabelKeys.raceStrategy,
        predicate: SimpleLabelPredicate(rejects: {1, 2}),
      );
      expect(spec.builderId, isNull);
      expect(builderSpecOf(ref, spec), isNull); // no builderId → no rebuild
      final reset = spec.withFilterReset(null) as SimpleLabelColumnSpec;
      expect(reset.predicate.rejects, isEmpty);
    });

    test('RangedIntegerColumnSpec (no preset support) resets to accept-all', () {
      final spec = RangedIntegerColumnSpec(
        id: 'id-5',
        title: 'i',
        parser: EvaluationValueParser(),
        predicate: IsInRangeIntegerPredicate(min: 5, max: 9),
      );
      expect(spec.hasFilter, isTrue);
      final reset = spec.withFilterReset(null) as RangedIntegerColumnSpec;
      expect(reset.predicate.min, isNull);
      expect(reset.predicate.max, isNull);
    });
  });

  group('non-filtering specs expose no filter to reset', () {
    test('LogicColumnSpec has no filter and withFilterReset is a no-op', () {
      final spec = LogicColumnSpec(id: 'logic-id', title: '論理', logic: LogicMode.and);
      expect(spec.hasFilter, isFalse);
      expect(identical(spec, spec.withFilterReset(null)), isTrue);
    });

    test('ScriptColumnSpec has no filter and withFilterReset is a no-op', () {
      final spec = ScriptColumnSpec(
        id: 'script-id',
        title: 'スクリプト',
        source: 'bool filter(CharaRecord r) => true;\ndynamic display(CharaRecord r) => 0;',
      );
      expect(spec.hasFilter, isFalse);
      expect(identical(spec, spec.withFilterReset(null)), isTrue);
    });
  });

  group('builderId round-trips through the mapper', () {
    test('a preset column keeps its builderId; a plain one omits it', () {
      final preset = FactorColumnSpec(
        id: 'id-6',
        title: 'p',
        parser: FactorSetParser(),
        predicate: AggregateFactorSetPredicate.any(),
        builderId: 'factor_x',
      );
      final restored = ColumnSpecMapper.fromMap(preset.toMap()) as FactorColumnSpec;
      expect(restored.builderId, 'factor_x');

      final plain = FactorColumnSpec(
        id: 'id-7',
        title: 'q',
        parser: FactorSetParser(),
        predicate: AggregateFactorSetPredicate.any(),
      );
      // ignoreNull drops the key, so a plain column decodes (and stays) null.
      expect(plain.toMap().containsKey('builderId'), isFalse);
      expect((ColumnSpecMapper.fromMap(plain.toMap()) as FactorColumnSpec).builderId, isNull);
    });
  });
}
