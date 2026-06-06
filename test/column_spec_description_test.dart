// Regression test for the user-editable `description` (chip tooltip) added to
// the rating / memo / script column specs.
// Run: .fvm/flutter_sdk/bin/flutter test test/column_spec_description_test.dart
//
// The backward-compat invariant: `description` is nullable and the spec classes
// are annotated `ignoreNull: true`, so a null description is omitted from the
// encoded map. That is what keeps a pre-existing spec (saved before the field
// existed, hence lacking the key) from being flagged broken by
// isSpecMapIncomplete — the make-or-break property this test pins.
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/memo.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/chara_detail/spec/rating.dart';
import 'package:umacapture/src/chara_detail/spec/script.dart';
import 'package:umacapture/src/core/mapper_init.dart';

void main() {
  setUpAll(initializeMappers);

  final specs = <String, ColumnSpec Function({String? description})>{
    'RatingColumnSpec': ({description}) => RatingColumnSpec(
      id: 'rating-id',
      title: 'レート',
      parser: EvaluationValueParser(),
      predicate: IsInRangeRatingPredicate(),
      storageKey: 'rating-key',
      description: description,
    ),
    'MemoColumnSpec': ({description}) => MemoColumnSpec(
      id: 'memo-id',
      title: 'メモ',
      parser: EvaluationValueParser(),
      predicate: RegExpPredicate(),
      storageKey: 'memo-key',
      description: description,
    ),
    'ScriptColumnSpec': ({description}) => ScriptColumnSpec(
      id: 'script-id',
      title: 'スクリプト',
      source: 'bool filter(CharaRecord r) => true;\ndynamic display(CharaRecord r) => 0;',
      description: description,
    ),
  };

  for (final entry in specs.entries) {
    final type = entry.key;
    final make = entry.value;

    test('$type without a description omits the key and is never flagged broken', () {
      final spec = make();
      final map = spec.toMap();
      // ignoreNull drops the null key, so legacy data (which never had it) and a
      // freshly-encoded null-description spec produce the same shape.
      expect(map.containsKey('description'), isFalse);

      final decoded = ColumnSpecMapper.fromMap(map);
      // A pre-existing spec lacking `description` must decode and must not be
      // reported as broken.
      expect(isSpecMapIncomplete(map, decoded.toMap()), isFalse);
    });

    test('$type round-trips a non-empty description', () {
      final spec = make(description: 'ホバーの説明');
      final map = spec.toMap();
      expect(map['description'], 'ホバーの説明');

      final decoded = ColumnSpecMapper.fromMap(map);
      expect((decoded as dynamic).description, 'ホバーの説明');
      expect(isSpecMapIncomplete(map, decoded.toMap()), isFalse);
    });

    test('$type can clear its description back to null via copyWith', () {
      final cleared = (make(description: 'temp') as dynamic).copyWith(description: null) as ColumnSpec;
      expect((cleared as dynamic).description, isNull);
      // Cleared description must round-trip as absent, not as an empty string.
      expect(cleared.toMap().containsKey('description'), isFalse);
    });
  }
}
