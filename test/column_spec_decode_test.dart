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
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/factor.dart';
import 'package:umacapture/src/chara_detail/spec/item_display.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/chara_detail/spec/ranged_integer.dart';
import 'package:umacapture/src/chara_detail/spec/script.dart';
import 'package:umacapture/src/core/mapper_init.dart';

/// The discriminator of every dart_mappable subclass of [ColumnSpec] declared under [lib], directly or through
/// another column type, read from the source.
///
/// Read from the source because nothing at run time can list them: the base mapper knows only the subclasses
/// already registered with it, which is the very thing under test.
Set<String> mappableColumnSpecDiscriminators(Directory lib) {
  final declaration = RegExp(
    r'((?:@\w+(?:\([^)]*\))?\s*)*)(?:(?:abstract|base|final|sealed|interface)\s+)*class\s+(\w+)\b([^{;]*)\{',
  );
  final generated = RegExp(r'\.(mapper|g|gr|freezed)\.dart$');
  final declared = <String, ({String extended, String discriminator})>{};
  for (final file in lib.listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.dart') || generated.hasMatch(file.path)) continue;
    for (final match in declaration.allMatches(file.readAsStringSync())) {
      final name = match.group(2) ?? '';
      final header = match.group(3) ?? '';
      final extended = RegExp(r'\bextends\s+(\w+)').firstMatch(header)?.group(1);
      if (extended == null || !RegExp('\\b${name}Mappable\\b').hasMatch(header)) continue;
      final annotations = match.group(1) ?? '';
      final discriminator = RegExp(r"discriminatorValue:\s*'([^']*)'").firstMatch(annotations)?.group(1);
      declared[name] = (extended: extended, discriminator: discriminator ?? name);
    }
  }
  bool isColumnSpec(String name) {
    if (name == 'ColumnSpec') return true;
    final extended = declared[name]?.extended;
    return extended != null && isColumnSpec(extended);
  }

  return {
    for (final MapEntry(:key, :value) in declared.entries)
      if (key != 'ColumnSpec' && isColumnSpec(value.extended)) value.discriminator,
  };
}

/// Which of [discriminators] the base mapper cannot route to a subclass mapper once [initializeMappers] has run.
List<String> unregisteredUnderBase(Set<String> discriminators) {
  initializeMappers();
  return [
    for (final type in discriminators)
      if (_baseCannotResolve(type)) type,
  ];
}

bool _baseCannotResolve(String type) {
  try {
    ColumnSpecMapper.fromMap(<String, dynamic>{'type': type});
    // Decoding succeeded from just the discriminator: clearly registered.
    return false;
  } catch (e) {
    // Decoding may still fail because required fields are absent from this minimal map; that proves the base routed
    // to the subclass mapper. Only the base failing to resolve the subclass at all is the regression.
    return e.toString().contains('Cannot instantiate class ColumnSpec');
  }
}

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
    'notation': <String, dynamic>{'mode': 'nameStarTotal'},
    'factorTags': <String>[],
    'skillTags': <String>[],
  },
  'showAllWhenQueryIsEmpty': true,
  'showAvailableOnly': true,
  'hiddenElements': <String>[],
  'selectByTag': false,
  'unmetRows': 'filterOut',
  'hidden': false,
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

  test('every ColumnSpec subclass mapper in lib is registered with the base', () async {
    final discriminators = mappableColumnSpecDiscriminators(Directory('lib'));
    // The two shapes a plain line match would miss: a declaration whose mixins continue on the next line, and a
    // column type that extends another one.
    expect(discriminators, containsAll(['FactorColumnSpec', 'CharaRankColumnSpec']), reason: 'the scan reads lib');

    // In a fresh isolate, so that initializeMappers is the only thing that has registered a mapper there. Encoding a
    // spec (toMap, ==, hashCode, toString) registers its own subclass on the way, so in this isolate an earlier test
    // that did so would hide a type initializeMappers leaves out; the app reads its saved columns before writing any.
    final unregistered = await Isolate.run(() => unregisteredUnderBase(discriminators));
    expect(unregistered, isEmpty, reason: 'Subclass mappers not registered in initializeMappers.');
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

  test('a legacy FactorColumnSpec without unmetRows decodes to filtering them out', () {
    final legacy = completeFactorMap()..remove('unmetRows');
    final spec = ColumnSpecMapper.fromMap(legacy);

    expect(spec, isA<FactorColumnSpec>());
    expect((spec as FactorColumnSpec).unmetRows, UnmetRows.filterOut);
    // And the non-default value round-trips through the mapper.
    final roundTripped =
        ColumnSpecMapper.fromMap(spec.copyWith(unmetRows: UnmetRows.markMissing).toMap()) as FactorColumnSpec;
    expect(roundTripped.unmetRows, UnmetRows.markMissing);
  });

  test('ScriptColumnSpec round-trips its source/title/apiVersion losslessly', () {
    final spec = ScriptColumnSpec(
      id: 'script-id',
      title: 'マイ列',
      source:
          'bool filter(CharaRecord r) => r.status.speed >= 1000;\n'
          'dynamic display(CharaRecord r) => r.status.speed;',
    );

    final decoded = ColumnSpecMapper.fromMap(spec.toMap());

    expect(decoded, isA<ScriptColumnSpec>());
    final script = decoded as ScriptColumnSpec;
    expect(script.id, spec.id);
    expect(script.title, spec.title);
    expect(script.source, spec.source);
    expect(script.apiVersion, scriptApiVersion);
    // A round-tripped spec must never be flagged broken (would prompt the user
    // to review a healthy column).
    expect(isSpecMapIncomplete(spec.toMap(), decoded.toMap()), isFalse);
    // ...nor obsolete: a freshly-encoded script carries the current contract.
    expect(script.isObsolete, isFalse);
  });

  test('ScriptColumnSpec saved against another contract version is obsolete', () {
    final spec = ScriptColumnSpec(
      id: 'script-id',
      title: 'old column',
      source:
          'bool filter(CharaRecord r) => true;\n'
          'dynamic display(CharaRecord r) => r.status.speed;',
    );

    // Simulate JSON persisted under a different facade contract version.
    final stale = spec.toMap()..['apiVersion'] = scriptApiVersion - 1;
    final decoded = ColumnSpecMapper.fromMap(stale) as ScriptColumnSpec;
    expect(decoded.apiVersion, scriptApiVersion - 1);
    expect(decoded.isObsolete, isTrue);

    // Re-stamping the version (as the dialog does on a passing check) heals it.
    final healed = decoded.copyWith(apiVersion: scriptApiVersion);
    expect(healed.isObsolete, isFalse);
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
