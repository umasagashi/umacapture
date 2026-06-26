// Regression test for [TrinaGridStateManagerExtension.refreshColumnRenderers],
// the non-structural reconcile path used when a column's spec changes without
// changing the column set (e.g. editing a skill column's display count).
// Run: .fvm/flutter_sdk/bin/flutter test test/refresh_column_renderers_test.dart
//
// The bug: refreshColumnRenderers used to copy only the renderer and title, so
// the live column kept a stale [ColumnSpec] in its user data. A later resize or
// width reset reads that spec back off the live column and persists it, which
// reverted the user's edit (the skill display count snapped back to its default).
// The fix re-seats the rebuilt spec onto the live column; the checkbox column,
// which carries no spec, must be left untouched.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/chara_detail/spec/skill.dart';

SkillColumnSpec _skillSpec({required int notationMax}) {
  return SkillColumnSpec(
    id: 'skill',
    title: 'Skill',
    parser: SkillParser(),
    predicate: AggregateSkillPredicate(notation: SkillNotation(max: notationMax)),
  );
}

TrinaColumn _column(String field, {ColumnSpec? spec}) {
  final column = TrinaColumn(title: field, field: field, type: TrinaColumnType.text());
  if (spec != null) {
    column.setUserData(spec);
  }
  return column;
}

TrinaGridStateManager _stateManager(List<TrinaColumn> columns) {
  return TrinaGridStateManager(
    columns: columns,
    rows: [],
    gridFocusNode: FocusNode(),
    scroll: TrinaGridScrollController(),
  );
}

void main() {
  test('re-seats the rebuilt spec onto the matching live column', () {
    final liveSkill = _column('skill', spec: _skillSpec(notationMax: 3));
    final manager = _stateManager([liveSkill]);

    final nextSkill = _column('skill', spec: _skillSpec(notationMax: 5));
    manager.refreshColumnRenderers([nextSkill]);

    final spec = liveSkill.getUserData<ColumnSpec>();
    expect(spec, isA<SkillColumnSpec>());
    expect((spec! as SkillColumnSpec).predicate.notation.max, 5);
  });

  test('leaves a spec-less column (the checkbox column) untouched', () {
    final liveCheck = _column(checkColumnField);
    final manager = _stateManager([liveCheck]);

    // The rebuilt checkbox column also carries no spec, so nothing is re-seated.
    manager.refreshColumnRenderers([_column(checkColumnField)]);

    expect(liveCheck.getUserData<ColumnSpec>(), isNull);
  });
}
