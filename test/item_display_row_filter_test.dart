// Tests that a root skill/factor column in a non-normal display mode annotates
// its cells instead of filtering rows: it neither hides a row nor carries a
// pass count (so its chip shows no badge), while the same column nested under a
// logic column keeps filtering through its container. Also pins the effective
// display mode (stored for a root column, normal for a nested one).
// Run: .fvm/flutter_sdk/bin/flutter test test/item_display_row_filter_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/factor.dart';
import 'package:umacapture/src/chara_detail/spec/item_display.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/spec/logic.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/chara_detail/spec/skill.dart';

import 'support/riverpod.dart';

SkillColumnSpec _skill(String id, ItemDisplayMode mode) => SkillColumnSpec(
  id: id,
  title: 'skill',
  parser: SkillParser(),
  predicate: AggregateSkillPredicate.any(),
  displayMode: mode,
);

FactorColumnSpec _factor(String id, ItemDisplayMode mode) => FactorColumnSpec(
  id: id,
  title: 'factor',
  parser: FactorSetParser(),
  predicate: AggregateFactorSetPredicate.any(),
  displayMode: mode,
);

void main() {
  // Three records; each column's condition passes a different subset, so a
  // column that filters is visible in rowConditions.
  const rowCount = 3;

  group('a root item column in a non-normal mode does not filter rows', () {
    for (final mode in [ItemDisplayMode.absence, ItemDisplayMode.difference]) {
      test('skill column in $mode keeps every row and has no pass count', () {
        final (:rowConditions, :filteredCounts) = filterRows(
          [_skill('s', mode)],
          {
            's': [true, false, false],
          },
          rowCount,
        );
        expect(rowConditions, [true, true, true]);
        expect(filteredCounts.containsKey('s'), isFalse);
      });
    }

    test('factor column in absence stays out while a normal column still filters', () {
      final (:rowConditions, :filteredCounts) = filterRows(
        [_factor('f', ItemDisplayMode.absence), _skill('s', ItemDisplayMode.normal)],
        {
          'f': [false, false, true],
          's': [true, true, false],
        },
        rowCount,
      );
      expect(rowConditions, [true, true, false]);
      expect(filteredCounts, {'s': 2});
    });

    test('the same column nested under a logic column keeps filtering', () {
      final child = _skill('s', ItemDisplayMode.difference);
      final and = LogicColumnSpec(id: 'and', title: 'AND', logic: LogicMode.and, children: [child]);
      final (:rowConditions, :filteredCounts) = filterRows(
        [and],
        {
          'and': [true, false, false],
          's': [true, false, false],
        },
        rowCount,
      );
      expect(rowConditions, [true, false, false]);
      expect(filteredCounts, {'and': 1, 's': 1});
    });
  });

  group('effectiveItemDisplayMode', () {
    final child = _factor('child', ItemDisplayMode.difference);
    final root = _skill('root', ItemDisplayMode.absence);
    final and = LogicColumnSpec(id: 'and', title: 'AND', logic: LogicMode.and, children: [child]);

    ProviderContainer containerWith(List<ColumnSpec> specs) {
      final container = ProviderContainer.test(overrides: [currentColumnSpecsProvider.overrideWithValue(specs)]);
      addTearDown(container.dispose);
      return container;
    }

    test('a root column gets its stored mode', () {
      final ref = containerWith([root, and]).read(containerRefProvider);
      expect(effectiveItemDisplayMode(ref, root.id, root.displayMode), ItemDisplayMode.absence);
    });

    test('a nested column gets normal while keeping its stored mode', () {
      final ref = containerWith([root, and]).read(containerRefProvider);
      expect(effectiveItemDisplayMode(ref, child.id, child.displayMode), ItemDisplayMode.normal);
      expect(child.displayMode, ItemDisplayMode.difference);
    });
  });
}
