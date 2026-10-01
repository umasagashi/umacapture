// Regression test for the backward-compatible migration of pre-content-mode
// factor/skill notation payloads.
// Run: .fvm/flutter_sdk/bin/flutter test test/legacy_notation_migration_test.dart
//
// Before notation gained an explicit content `mode`, both factor and skill
// columns overloaded `max == 0` to mean "show an aggregate value instead of
// names". `migrateLegacyColumnSpecMap` rewrites those stored maps in place so
// they (a) decode into the current enums and (b) match the freshly encoded spec,
// so `isSpecMapIncomplete` does not flag them broken.
//
// The fixtures carry the column keys a v0.1.0 build wrote, the shape these
// notations were stored in.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/factor.dart';
import 'package:umacapture/src/chara_detail/spec/skill.dart';
import 'package:umacapture/src/core/mapper_init.dart';

Map<String, dynamic> _factorMap(Map<String, dynamic> notation) => <String, dynamic>{
  'type': 'FactorColumnSpec',
  'id': 'factor-id',
  'title': '因子',
  'parser': <String, dynamic>{'type': 'FactorSetParser'},
  'predicate': <String, dynamic>{
    'query': <int>[],
    'logic': 'anyOf',
    'subject': 'family',
    'element': <String, dynamic>{'mode': 'starOnly', 'star': 1, 'count': 1},
    'notation': notation,
    'factorTags': <String>[],
    'skillTags': <String>[],
  },
  'showAllWhenQueryIsEmpty': true,
  'showAvailableOnly': true,
  'hiddenElements': <String>[],
  'hidden': false,
};

Map<String, dynamic> _skillMap(Map<String, dynamic> notation) => <String, dynamic>{
  'type': 'SkillColumnSpec',
  'id': 'skill-id',
  'title': 'スキル',
  'parser': <String, dynamic>{'type': 'SkillParser'},
  'predicate': <String, dynamic>{
    'query': <int>[],
    'logic': 'anyOf',
    'min': 1,
    'notation': notation,
    'tags': <String>[],
  },
  'showAllWhenQueryIsEmpty': true,
  'showAvailableOnly': true,
  'hiddenElements': <String>[],
  'hidden': false,
};

// The freshly encoded map, without the column keys added after v0.1.0. Their
// absence decodes to the default, and the load path does not flag it broken.
Map<String, dynamic> _encoded(ColumnSpec spec) => spec.toMap()
  ..remove('selectByTag')
  ..remove('unmetRows');

void main() {
  setUpAll(initializeMappers);

  group('factor notation migration', () {
    test('legacy sumOnly with a name limit becomes name + star total', () {
      final map = _factorMap({'mode': 'sumOnly', 'max': 3});
      migrateLegacyColumnSpecMap(map);
      final spec = ColumnSpecMapper.fromMap(map) as FactorColumnSpec;
      expect(spec.predicate.notation.mode, FactorNotationMode.nameStarTotal);
      expect(spec.predicate.notation.max, 3);
      expect(isSpecMapIncomplete(map, _encoded(spec)), isFalse);
    });

    test('legacy each with a name limit becomes name + star each', () {
      final map = _factorMap({'mode': 'each', 'max': 5});
      migrateLegacyColumnSpecMap(map);
      final spec = ColumnSpecMapper.fromMap(map) as FactorColumnSpec;
      expect(spec.predicate.notation.mode, FactorNotationMode.nameStarEach);
      expect(spec.predicate.notation.max, 5);
      expect(isSpecMapIncomplete(map, _encoded(spec)), isFalse);
    });

    test('legacy max==0 becomes the value-only mode with max reset to a valid value', () {
      final map = _factorMap({'mode': 'each', 'max': 0});
      migrateLegacyColumnSpecMap(map);
      final spec = ColumnSpecMapper.fromMap(map) as FactorColumnSpec;
      expect(spec.predicate.notation.mode, FactorNotationMode.starEach);
      expect(spec.predicate.notation.max, 3);
      expect(isSpecMapIncomplete(map, _encoded(spec)), isFalse);
    });

    test('dropped traineeAndParents folds into the total granularity', () {
      final map = _factorMap({'mode': 'traineeAndParents', 'max': 2});
      migrateLegacyColumnSpecMap(map);
      final spec = ColumnSpecMapper.fromMap(map) as FactorColumnSpec;
      expect(spec.predicate.notation.mode, FactorNotationMode.nameStarTotal);
      expect(isSpecMapIncomplete(map, _encoded(spec)), isFalse);
    });

    test('a current-format map is left untouched (idempotent)', () {
      final map = _factorMap({'mode': 'countTotal', 'max': 4});
      migrateLegacyColumnSpecMap(map);
      final spec = ColumnSpecMapper.fromMap(map) as FactorColumnSpec;
      expect(spec.predicate.notation.mode, FactorNotationMode.countTotal);
      expect(spec.predicate.notation.max, 4);
      expect(isSpecMapIncomplete(map, _encoded(spec)), isFalse);
    });
  });

  group('skill notation migration', () {
    test('legacy map with only max becomes the names mode', () {
      final map = _skillMap({'max': 3});
      migrateLegacyColumnSpecMap(map);
      final spec = ColumnSpecMapper.fromMap(map) as SkillColumnSpec;
      expect(spec.predicate.notation.mode, SkillNotationMode.names);
      expect(spec.predicate.notation.max, 3);
      expect(isSpecMapIncomplete(map, _encoded(spec)), isFalse);
    });

    test('legacy max==0 becomes the count mode with max reset to a valid value', () {
      final map = _skillMap({'max': 0});
      migrateLegacyColumnSpecMap(map);
      final spec = ColumnSpecMapper.fromMap(map) as SkillColumnSpec;
      expect(spec.predicate.notation.mode, SkillNotationMode.count);
      expect(spec.predicate.notation.max, 3);
      expect(isSpecMapIncomplete(map, _encoded(spec)), isFalse);
    });

    test('a current-format map is left untouched (idempotent)', () {
      final map = _skillMap({'mode': 'count', 'max': 5});
      migrateLegacyColumnSpecMap(map);
      final spec = ColumnSpecMapper.fromMap(map) as SkillColumnSpec;
      expect(spec.predicate.notation.mode, SkillNotationMode.count);
      expect(spec.predicate.notation.max, 5);
      expect(isSpecMapIncomplete(map, _encoded(spec)), isFalse);
    });
  });

  group('migration scope', () {
    test('a notation map under an unrelated spec type is not mutated', () {
      // Only factor/skill ever carried the legacy `max == 0` overload; a future
      // spec type with its own notation shape must survive a load unchanged
      // (no `mode` injection, no `max` rewrite).
      final map = <String, dynamic>{
        'type': 'SomeFutureColumnSpec',
        'id': 'future-id',
        'predicate': <String, dynamic>{
          'notation': <String, dynamic>{'max': 0},
        },
      };
      final before = jsonDecode(jsonEncode(map));
      migrateLegacyColumnSpecMap(map);
      expect(map, before);
    });

    test('a factor map with a missing notation mode is not healed', () {
      // A factor notation always carried `mode`; its absence means genuinely
      // malformed data, which must stay as-is and decode into a broken
      // placeholder rather than being silently repaired as a skill map would be.
      final map = _factorMap({'max': 3});
      migrateLegacyColumnSpecMap(map);
      expect((map['predicate'] as Map<String, dynamic>)['notation'], {'max': 3});
    });

    test('the type gate still recurses into container children', () {
      final child = _factorMap({'mode': 'sumOnly', 'max': 0});
      final container = <String, dynamic>{
        'type': 'LogicColumnSpec',
        'id': 'logic-id',
        'children': [child],
      };
      migrateLegacyColumnSpecMap(container);
      expect((child['predicate'] as Map<String, dynamic>)['notation'], {'mode': 'starTotal', 'max': 3});
    });
  });
}
