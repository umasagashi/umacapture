// Tests that a root skill/factor column that does not filter rows — a difference
// column, or a column that keeps its unmet rows and marks them red — neither
// hides a row nor carries a pass count (so its chip shows no badge), while a
// filtering column nested under a logic column keeps filtering through its
// container and keeps its own pass count.
// Run: .fvm/flutter_sdk/bin/flutter test test/item_display_row_filter_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/factor.dart';
import 'package:umacapture/src/chara_detail/spec/item_display.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/spec/logic.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/chara_detail/spec/skill.dart';
import 'package:umacapture/src/chara_detail/spec/skill_difference.dart';

SkillColumnSpec _skill(String id, UnmetRows unmetRows) => SkillColumnSpec(
  id: id,
  title: 'skill',
  parser: SkillParser(),
  predicate: AggregateSkillPredicate.any(),
  unmetRows: unmetRows,
);

FactorColumnSpec _factor(String id, UnmetRows unmetRows) => FactorColumnSpec(
  id: id,
  title: 'factor',
  parser: FactorSetParser(),
  predicate: AggregateFactorSetPredicate.any(),
  unmetRows: unmetRows,
);

void main() {
  // Three records; each column's condition passes a different subset, so a
  // column that filters is visible in rowConditions.
  const rowCount = 3;

  group('a root item column that does not filter rows', () {
    final columns = <String, ColumnSpec>{
      'a skill column marking missing items': _skill('s', UnmetRows.markMissing),
      'a skill difference column': SkillDifferenceColumnSpec(id: 's', title: 'skill', parser: SkillParser()),
    };
    for (final MapEntry(key: name, value: column) in columns.entries) {
      test('$name keeps every row and has no pass count', () {
        final (:rowConditions, :filteredCounts) = filterRows(
          [column],
          {
            's': [true, false, false],
          },
          rowCount,
        );
        expect(rowConditions, [true, true, true]);
        expect(filteredCounts.containsKey('s'), isFalse);
      });
    }

    test('a factor column marking missing items stays out while a filtering column still filters', () {
      final (:rowConditions, :filteredCounts) = filterRows(
        [_factor('f', UnmetRows.markMissing), _skill('s', UnmetRows.filterOut)],
        {
          'f': [false, false, true],
          's': [true, true, false],
        },
        rowCount,
      );
      expect(rowConditions, [true, true, false]);
      expect(filteredCounts, {'s': 2});
    });

    test('a filtering column nested under a logic column filters through it and keeps its pass count', () {
      final child = _skill('s', UnmetRows.filterOut);
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
}
