// Tests the non-destructive "broken column" load path of ColumnSpecSelection.
// A spec whose stored JSON is incomplete (legacy data missing a field that is
// now required) or undecodable (unknown discriminator type) must NOT be dropped:
// it is flagged broken, its original raw is preserved on re-serialize until the
// user heals it via the settings dialog (replaceById), and an unknown type is
// kept as a BrokenPlaceholderSpec that round-trips verbatim.
// Run: .fvm/flutter_sdk/bin/flutter test test/column_spec_broken_test.dart
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/factor.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/spec/logic.dart';
import 'package:umacapture/src/chara_detail/spec/script.dart';
import 'package:umacapture/src/core/mapper_init.dart';

import 'support/hive.dart';

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
    'notation': <String, dynamic>{'mode': 'nameStarTotal', 'max': 3},
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

// A ScriptColumnSpec persisted against an earlier facade contract version.
Map<String, dynamic> staleScriptMap(String id) => <String, dynamic>{
  'type': 'ScriptColumnSpec',
  'id': id,
  'title': 'script',
  'source':
      'bool filter(CharaRecord r) => true;\n'
      'dynamic display(CharaRecord r) => 1;',
  'apiVersion': scriptApiVersion - 1,
};

// Seed the legacy single-configuration entry. On first read ColumnPresetIndex
// migrates it into the default preset (entry "specs_default"), so the specs
// surface through the providers exactly as before.
void seed(List<Map<String, dynamic>> maps) {
  Hive.box('column_spec').put('current_column_specs', jsonEncode(maps));
}

// Reads the live specs from the migrated default preset's entry, where all
// mutations are persisted after migration.
List<dynamic> storedSpecs() {
  return jsonDecode(Hive.box('column_spec').get('specs_default') as String) as List<dynamic>;
}

void main() {
  setUpAll(() async {
    initializeMappers();
  });
  useHiveForTest(['column_spec']);

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

  test('a spec saved before selectByTag existed loads healthy, not broken', () async {
    // completeFactorMap() carries every field except selectByTag (a non-null bool
    // added later). Its absence must decode to the default (false) without flagging
    // the column broken — the same grandfathering the 'hidden' flag relies on.
    seed([completeFactorMap('grandfathered')]);
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);

    final specs = container.read(currentColumnSpecsProvider);
    expect(specs.single, isA<FactorColumnSpec>());
    expect((specs.single as FactorColumnSpec).selectByTag, isFalse);
    expect(container.read(currentColumnSpecBrokenIdsProvider), isNot(contains('grandfathered')));
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

  test('moveToSlot preserves broken status and original raw', () async {
    seed([legacyFactorMap('legacy'), rangedIntegerMap('healthy')]);
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(currentColumnSpecsLoaderProvider.notifier);

    expect(container.read(currentColumnSpecBrokenIdsProvider), contains('legacy'));
    expect(container.read(currentColumnSpecBrokenIdsProvider), isNot(contains('healthy')));

    // Move legacy to after healthy (detach legacy, reinsert at the top-level end).
    notifier.moveToSlot('legacy', null, 1);

    expect(container.read(currentColumnSpecsProvider).map((e) => e.id).toList(), ['healthy', 'legacy']);
    expect(container.read(currentColumnSpecBrokenIdsProvider), contains('legacy'));
    // The reordered legacy entry is still persisted as its original incomplete raw.
    final stored = storedSpecs().firstWhere((e) => (e as Map)['id'] == 'legacy') as Map;
    expect(stored['predicate'], isNot(contains('factorTags')));
  });

  test('nesting a broken column under a logic column preserves its raw', () async {
    seed([LogicColumnSpec(id: 'and', title: 'AND', logic: LogicMode.and).toMap(), legacyFactorMap('legacy')]);
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(currentColumnSpecsLoaderProvider.notifier);

    expect(container.read(currentColumnSpecBrokenIdsProvider), contains('legacy'));

    // Drag the broken leaf into the AND column: it is now persisted via the
    // parent's children, not as a top-level entry.
    notifier.moveToSlot('legacy', 'and', 0);

    // The nested legacy entry is still persisted as its original incomplete raw,
    // not a healed full map that silently restores the dropped fields.
    final stored = storedSpecs();
    final and = stored.firstWhere((e) => (e as Map)['id'] == 'and') as Map;
    final child = (and['children'] as List).single as Map;
    expect(child['predicate'], isNot(contains('factorTags')));
  });

  test('a broken child already nested in storage is flagged at its own id, not the container', () async {
    // The logic column itself is complete; only its nested child is incomplete.
    final and = <String, dynamic>{
      'type': 'LogicColumnSpec',
      'id': 'and',
      'title': 'AND',
      'logic': 'and',
      'children': [legacyFactorMap('legacy'), rangedIntegerMap('healthy')],
    };
    seed([and]);
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(currentColumnSpecsLoaderProvider.notifier);

    // The broken flag lands on the child, NOT on the healthy container.
    final brokenIds = container.read(currentColumnSpecBrokenIdsProvider);
    expect(brokenIds, contains('legacy'));
    expect(brokenIds, isNot(contains('and')));
    expect(brokenIds, isNot(contains('healthy')));

    // Dragging the healthy sibling out of the container is a real structural edit
    // that must persist — the healthy container is not pinned to its stored raw.
    notifier.moveToSlot('healthy', null, 1);
    final stored = storedSpecs();
    final storedAnd = stored.firstWhere((e) => (e as Map)['id'] == 'and') as Map;
    expect((storedAnd['children'] as List).map((e) => (e as Map)['id']).toList(), ['legacy']);
    expect(stored.map((e) => (e as Map)['id']).toList(), ['and', 'healthy']);
    // The nested broken child still keeps its incomplete raw, not a healed map.
    final child = (storedAnd['children'] as List).single as Map;
    expect(child['predicate'], isNot(contains('factorTags')));
  });

  test('script column on an old contract version loads broken and heals on re-save', () async {
    seed([staleScriptMap('script')]);
    final c1 = ProviderContainer.test();
    await c1.read(currentColumnSpecsLoaderProvider.future);

    // Fully decodable (not a placeholder), but flagged broken via isObsolete.
    expect(c1.read(currentColumnSpecsProvider).single, isA<ScriptColumnSpec>());
    expect(c1.read(currentColumnSpecBrokenIdsProvider), contains('script'));

    // Heal: re-save with the current contract version stamped, as the dialog
    // does once the script passes its check.
    final n1 = c1.read(currentColumnSpecsLoaderProvider.notifier);
    final healed = (n1.getById('script')! as ScriptColumnSpec).copyWith(apiVersion: scriptApiVersion);
    n1.replaceById(healed);
    expect(c1.read(currentColumnSpecBrokenIdsProvider), isNot(contains('script')));

    // Reload after healing: no longer broken.
    final c2 = ProviderContainer.test();
    await c2.read(currentColumnSpecsLoaderProvider.future);
    expect(c2.read(currentColumnSpecBrokenIdsProvider), isEmpty);
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
