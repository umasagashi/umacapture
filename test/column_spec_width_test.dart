// Regression test for the user-pinned column `width` added to every column spec.
// Run: .fvm/flutter_sdk/bin/flutter test test/column_spec_width_test.dart
//
// The width is nullable (null == auto-fit to content, a value == user-pinned) and
// every spec class is annotated `ignoreNull: true`, so a null width is omitted
// from the encoded map. That is the backward-compat invariant: a pre-existing spec
// saved before the field existed (hence lacking the key) decodes as auto width and
// must never be flagged broken by isSpecMapIncomplete. A pinned width must instead
// round-trip losslessly, and withWidth(null) must clear it back to absent.
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/chara_rank.dart';
import 'package:umacapture/src/chara_detail/spec/logic.dart';
import 'package:umacapture/src/chara_detail/spec/memo.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/chara_detail/spec/ranged_integer.dart';
import 'package:umacapture/src/chara_detail/spec/rating.dart';
import 'package:umacapture/src/chara_detail/spec/script.dart';
import 'package:umacapture/src/core/mapper_init.dart';

void main() {
  setUpAll(initializeMappers);

  // One leaf spec per construction shape, a container (logic), and an inherited
  // subclass (chara rank extends ranged label), so the field is exercised across
  // the spec hierarchy rather than a single representative.
  final specs = <String, ColumnSpec Function({double? width})>{
    'RatingColumnSpec': ({width}) => RatingColumnSpec(
      id: 'rating-id',
      title: 'レート',
      parser: EvaluationValueParser(),
      predicate: IsInRangeRatingPredicate(),
      storageKey: 'rating-key',
      width: width,
    ),
    'MemoColumnSpec': ({width}) => MemoColumnSpec(
      id: 'memo-id',
      title: 'メモ',
      parser: EvaluationValueParser(),
      predicate: RegExpPredicate(),
      storageKey: 'memo-key',
      width: width,
    ),
    'ScriptColumnSpec': ({width}) => ScriptColumnSpec(
      id: 'script-id',
      title: 'スクリプト',
      source: 'bool filter(CharaRecord r) => true;\ndynamic display(CharaRecord r) => 0;',
      width: width,
    ),
    'LogicColumnSpec': ({width}) => LogicColumnSpec(id: 'logic-id', title: '論理', logic: LogicMode.and, width: width),
    'CharaRankColumnSpec': ({width}) => CharaRankColumnSpec(
      id: 'chara-rank-id',
      title: 'キャラランク',
      parser: EvaluationValueParser(),
      labelKey: 'chara-rank-key',
      predicate: IsInRangeIntegerPredicate(),
      width: width,
    ),
  };

  for (final entry in specs.entries) {
    final type = entry.key;
    final make = entry.value;

    test('$type without a width omits the key and is never flagged broken', () {
      final spec = make();
      expect(spec.width, isNull);
      final map = spec.toMap();
      // ignoreNull drops the null key, so legacy data (which never had it) and a
      // freshly-encoded auto-width spec produce the same shape.
      expect(map.containsKey('width'), isFalse);

      final decoded = ColumnSpecMapper.fromMap(map);
      // A pre-existing spec lacking `width` must decode and must not be reported
      // as broken (which would prompt the user to review a healthy column).
      expect(decoded.width, isNull);
      expect(isSpecMapIncomplete(map, decoded.toMap()), isFalse);
    });

    test('$type round-trips a pinned width', () {
      final spec = make(width: 287.5);
      final map = spec.toMap();
      expect(map['width'], 287.5);

      final decoded = ColumnSpecMapper.fromMap(map);
      expect(decoded.width, 287.5);
      expect(isSpecMapIncomplete(map, decoded.toMap()), isFalse);
    });

    test('$type pins a width via withWidth', () {
      final pinned = make().withWidth(240.0);
      expect(pinned.width, 240.0);
      expect(pinned.toMap()['width'], 240.0);
    });

    test('$type can clear its width back to auto via withWidth(null)', () {
      final cleared = make(width: 300.0).withWidth(null);
      expect(cleared.width, isNull);
      // Cleared width must round-trip as absent, not as a sentinel value.
      expect(cleared.toMap().containsKey('width'), isFalse);
    });

    // clampedWidth guards the value applied to the grid column: trina enforces
    // minColumnWidth (80) only on interactive resize, not at construction, so a
    // corrupted persisted value must be sanitized before it reaches the layout.
    test('$type clampedWidth sanitizes corrupted persisted widths', () {
      // Unpinned stays null (the column keeps auto-fitting).
      expect(make().clampedWidth, isNull);
      // A healthy pinned value passes through untouched.
      expect(make(width: 287.5).clampedWidth, 287.5);
      // Too small / negative snaps up to trina's minimum column width.
      expect(make(width: -50.0).clampedWidth, 80.0);
      expect(make(width: 0.0).clampedWidth, 80.0);
      // Absurdly large snaps down to the pinned-width ceiling.
      expect(make(width: 99999.0).clampedWidth, 2000.0);
      // Non-finite values fall back to the default column width.
      expect(make(width: double.nan).clampedWidth, 200.0);
      expect(make(width: double.infinity).clampedWidth, 200.0);
    });
  }
}
