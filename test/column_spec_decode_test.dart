// Regression test for the dart_mappable polymorphic decoding of ColumnSpec.
// Run: .fvm/flutter_sdk/bin/flutter test test/column_spec_decode_test.dart
//
// ColumnSpec subclasses live in separate files, so dart_mappable does not
// auto-discover them; each subclass mapper must be registered explicitly in
// initializeMappers(). When that registration is missing, decoding a saved spec
// fails with MapperException.missingConstructor('ColumnSpec'). This test pins
// that behaviour so the registration cannot silently regress.
//
// Self-contained (no on-disk data), so it always runs in CI.
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/factor.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/chara_detail/spec/ranged_integer.dart';
import 'package:umacapture/src/core/mapper_init.dart';

// A complete, current-format FactorColumnSpec map.
Map<String, dynamic> completeFactorMap() => <String, dynamic>{
  'type': 'FactorColumnSpec',
  'id': 'factor-id',
  'title': '因子',
  'parser': <String, dynamic>{'type': 'FactorSetParser'},
  'predicate': <String, dynamic>{
    'query': <int>[],
    'logic': 'anyOf',
    'subject': 'family',
    'element': <String, dynamic>{'mode': 'starOnly', 'star': 1, 'count': 1},
    'notation': <String, dynamic>{'mode': 'sumOnly', 'max': 3},
    'factorTags': <String>[],
    'skillTags': <String>[],
  },
  'showAllWhenQueryIsEmpty': true,
  'showAvailableOnly': true,
  'hiddenElements': <String>[],
};

void main() {
  setUpAll(initializeMappers);

  test('the observed saved payload decodes to the concrete subclass', () {
    // The exact shape that crashed at startup (FansParser nested under a
    // RangedIntegerColumnSpec, with a null/null predicate).
    final map = <String, dynamic>{
      'type': 'RangedIntegerColumnSpec',
      'id': 'test-id',
      'title': 'ファン数',
      'parser': <String, dynamic>{'type': 'FansParser'},
      'predicate': <String, dynamic>{'min': null, 'max': null},
      'cellAction': 'openCampaignPreview',
    };

    final spec = ColumnSpecMapper.fromMap(map);

    expect(spec, isA<RangedIntegerColumnSpec>());
    expect((spec as RangedIntegerColumnSpec).parser, isA<FansParser>());
  });

  test('every ColumnSpec subclass mapper is registered with the base', () {
    // discriminatorValue of each subclass (== its class name).
    const discriminatorValues = <String>[
      'RangedIntegerColumnSpec',
      'RangedLabelColumnSpec',
      'CharaRankColumnSpec',
      'SimpleLabelColumnSpec',
      'SkillColumnSpec',
      'FactorColumnSpec',
      'CharacterCardColumnSpec',
      'DateTimeColumnSpec',
      'RatingColumnSpec',
      'MemoColumnSpec',
    ];

    for (final type in discriminatorValues) {
      try {
        ColumnSpecMapper.fromMap(<String, dynamic>{'type': type});
        // Decoding succeeded from just the discriminator: clearly registered.
      } catch (e) {
        // Decoding may still fail because required fields are absent from this
        // minimal map — that is fine and proves the base routed to the subclass
        // mapper. The regression we guard against is the base mapper being unable
        // to resolve the subclass at all.
        expect(
          e.toString(),
          isNot(contains('Cannot instantiate class ColumnSpec')),
          reason: 'Subclass mapper for "$type" is not registered (regression in initializeMappers).',
        );
      }
    }
  });

  test('legacy FactorColumnSpec missing factorTags/skillTags recovers with defaults', () {
    final legacy = completeFactorMap();
    (legacy['predicate'] as Map<String, dynamic>).remove('factorTags');
    (legacy['predicate'] as Map<String, dynamic>).remove('skillTags');

    final spec = ColumnSpecMapper.fromMap(legacy);

    expect(spec, isA<FactorColumnSpec>());
    expect((spec as FactorColumnSpec).predicate.factorTags, isEmpty);
    expect(spec.predicate.skillTags, isEmpty);
  });

  test('isSpecMapIncomplete flags only the legacy map, not the complete one', () {
    final complete = completeFactorMap();
    final completeSpec = ColumnSpecMapper.fromMap(complete);
    // A round-tripped complete spec must never be flagged as broken.
    expect(isSpecMapIncomplete(complete, completeSpec.toMap()), isFalse);
    expect(isSpecMapIncomplete(completeSpec.toMap(), completeSpec.toMap()), isFalse);

    final legacy = completeFactorMap();
    (legacy['predicate'] as Map<String, dynamic>).remove('factorTags');
    (legacy['predicate'] as Map<String, dynamic>).remove('skillTags');
    final legacySpec = ColumnSpecMapper.fromMap(legacy);
    expect(isSpecMapIncomplete(legacy, legacySpec.toMap()), isTrue);
  });
}
