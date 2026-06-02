// Tests the non-destructive "broken column" load path of ColumnSpecSelection.
// A spec whose stored JSON is incomplete (legacy data missing a field that is
// now required) or undecodable (unknown discriminator type) must NOT be dropped:
// it is flagged broken, its original raw is preserved on re-serialize until the
// user heals it via the settings dialog (replaceById), and an unknown type is
// kept as a BrokenPlaceholderSpec that round-trips verbatim.
// Run: .fvm/flutter_sdk/bin/flutter test test/column_spec_broken_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/factor.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/core/mapper_init.dart';

Map<String, dynamic> completeFactorMap(String id) => <String, dynamic>{
  'type': 'FactorColumnSpec',
  'id': id,
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

Map<String, dynamic> legacyFactorMap(String id) {
  final map = completeFactorMap(id);
  (map['predicate'] as Map<String, dynamic>).remove('factorTags');
  (map['predicate'] as Map<String, dynamic>).remove('skillTags');
  return map;
}

Map<String, dynamic> rangedIntegerMap(String id) => <String, dynamic>{
  'type': 'RangedIntegerColumnSpec',
  'id': id,
  'title': 'ファン数',
  'parser': <String, dynamic>{'type': 'FansParser'},
  'predicate': <String, dynamic>{'min': null, 'max': null},
  'cellAction': 'openCampaignPreview',
};

void seed(List<Map<String, dynamic>> maps) {
  Hive.box('column_spec').put('current_column_specs', jsonEncode(maps));
}

List<dynamic> storedSpecs() {
  return jsonDecode(Hive.box('column_spec').get('current_column_specs') as String) as List<dynamic>;
}

void main() {
  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('umacapture_broken_test').path);
    initializeMappers();
    await Hive.openBox('column_spec');
  });

  setUp(() async {
    await Hive.box('column_spec').clear();
  });

  test('legacy spec is recovered (not dropped) and flagged broken', () async {
    seed([legacyFactorMap('legacy')]);
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);

    final specs = container.read(currentColumnSpecsProvider);
    expect(specs.map((e) => e.id).toList(), ['legacy']);
    expect(specs.single, isA<FactorColumnSpec>());
    expect((specs.single as FactorColumnSpec).predicate.factorTags, isEmpty);
    expect(container.read(currentColumnSpecBrokenIdsProvider), contains('legacy'));
  });

  test('broken flag survives reload until the user heals via replaceById', () async {
    seed([legacyFactorMap('legacy')]);

    final c1 = ProviderContainer.test();
    await c1.read(currentColumnSpecsLoaderProvider.future);
    // Re-commit without healing (e.g. a reorder happened): original raw is preserved.
    c1.read(currentColumnSpecsLoaderProvider.notifier).rebuild();
    expect((storedSpecs().single as Map)['predicate'], isNot(contains('factorTags')));

    // Reload: still broken because the stored data is still incomplete.
    final c2 = ProviderContainer.test();
    await c2.read(currentColumnSpecsLoaderProvider.future);
    expect(c2.read(currentColumnSpecBrokenIdsProvider), contains('legacy'));

    // Heal: re-saving the recovered spec via the settings dialog path.
    final n2 = c2.read(currentColumnSpecsLoaderProvider.notifier);
    n2.replaceById(n2.getById('legacy')!);
    expect(c2.read(currentColumnSpecBrokenIdsProvider), isNot(contains('legacy')));
    expect((storedSpecs().single as Map)['predicate'], contains('factorTags'));

    // Reload after healing: no longer broken.
    final c3 = ProviderContainer.test();
    await c3.read(currentColumnSpecsLoaderProvider.future);
    expect(c3.read(currentColumnSpecBrokenIdsProvider), isEmpty);
  });

  test('moveTo preserves broken status and original raw', () async {
    seed([legacyFactorMap('legacy'), rangedIntegerMap('healthy')]);
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(currentColumnSpecsLoaderProvider.notifier);

    expect(container.read(currentColumnSpecBrokenIdsProvider), contains('legacy'));
    expect(container.read(currentColumnSpecBrokenIdsProvider), isNot(contains('healthy')));

    final legacy = notifier.getById('legacy')!;
    final healthy = notifier.getById('healthy')!;
    notifier.moveTo(legacy, healthy);

    expect(container.read(currentColumnSpecsProvider).map((e) => e.id).toList(), ['healthy', 'legacy']);
    expect(container.read(currentColumnSpecBrokenIdsProvider), contains('legacy'));
    // The reordered legacy entry is still persisted as its original incomplete raw.
    final stored = storedSpecs().firstWhere((e) => (e as Map)['id'] == 'legacy') as Map;
    expect(stored['predicate'], isNot(contains('factorTags')));
  });

  test('unknown type is kept as a placeholder that round-trips and can be removed', () async {
    final ghost = <String, dynamic>{'type': 'NonexistentColumnSpec', 'id': 'ghost', 'title': 'Ghost'};
    seed([ghost]);
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(currentColumnSpecsLoaderProvider.notifier);

    final specs = container.read(currentColumnSpecsProvider);
    expect(specs.single, isA<BrokenPlaceholderSpec>());
    expect(specs.single.id, 'ghost');
    expect(container.read(currentColumnSpecBrokenIdsProvider), contains('ghost'));

    // Re-serializing must preserve the unknown map verbatim.
    notifier.rebuild();
    expect(storedSpecs().single, equals(ghost));

    // The existing right-click delete removes it cleanly.
    notifier.removeIfExists('ghost');
    expect(container.read(currentColumnSpecsProvider), isEmpty);
    expect(container.read(currentColumnSpecBrokenIdsProvider), isEmpty);
    expect(storedSpecs(), isEmpty);
  });
}
