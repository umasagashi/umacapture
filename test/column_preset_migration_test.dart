// Tests the column preset layer: migration of the legacy single configuration
// into a default preset, and the create/duplicate/rename/delete/select
// operations of ColumnPresetIndexNotifier. Switching the selected preset must
// swap the specs surfaced by currentColumnSpecsProvider, and broken specs must
// stay flagged per-preset.
// Run: .fvm/flutter_sdk/bin/flutter test test/column_preset_migration_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/spec/preset.dart';
import 'package:umacapture/src/core/mapper_init.dart';

Map<String, dynamic> rangedIntegerMap(String id) => <String, dynamic>{
  'type': 'RangedIntegerColumnSpec',
  'id': id,
  'title': 'ファン数',
  'parser': <String, dynamic>{'type': 'FansParser'},
  'predicate': <String, dynamic>{'min': null, 'max': null},
  'cellAction': 'openCampaignPreview',
};

// A FactorColumnSpec missing now-required fields: recovered but flagged broken.
Map<String, dynamic> legacyFactorMap(String id) => <String, dynamic>{
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
  },
  'showAllWhenQueryIsEmpty': true,
  'showAvailableOnly': true,
  'hiddenElements': <String>[],
};

void seedLegacy(List<Map<String, dynamic>> maps) {
  Hive.box('column_spec').put('current_column_specs', jsonEncode(maps));
}

void main() {
  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('umacapture_preset_test').path);
    initializeMappers();
    await Hive.openBox('column_spec');
  });

  setUp(() async {
    await Hive.box('column_spec').clear();
  });

  test('legacy single configuration migrates into a selected default preset', () async {
    seedLegacy([rangedIntegerMap('a'), legacyFactorMap('broken')]);

    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);

    final index = container.read(columnPresetIndexProvider);
    expect(index.presets, hasLength(1));
    expect(index.selectedKey, index.presets.single.key);

    // Migrated specs surface through the synchronous view, broken one flagged.
    expect(container.read(currentColumnSpecsProvider).map((e) => e.id).toList(), ['a', 'broken']);
    expect(container.read(currentColumnSpecBrokenIdsProvider), contains('broken'));

    // Legacy entry is preserved verbatim as a safety net (copied, not moved).
    expect(Hive.box('column_spec').get('current_column_specs'), isNotNull);
  });

  test('migration is idempotent across fresh containers', () async {
    seedLegacy([rangedIntegerMap('a')]);

    final c1 = ProviderContainer.test();
    await c1.read(currentColumnSpecsLoaderProvider.future);
    final key = c1.read(columnPresetIndexProvider).presets.single.key;

    final c2 = ProviderContainer.test();
    await c2.read(currentColumnSpecsLoaderProvider.future);
    final index = c2.read(columnPresetIndexProvider);
    expect(index.presets, hasLength(1));
    expect(index.presets.single.key, key);
  });

  test('first run without legacy data yields one empty default preset', () async {
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);

    expect(container.read(columnPresetIndexProvider).presets, hasLength(1));
    expect(container.read(currentColumnSpecsProvider), isEmpty);
  });

  test('selecting a preset swaps the specs the grid sees', () async {
    seedLegacy([rangedIntegerMap('a')]);
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(columnPresetIndexProvider.notifier);
    final defaultKey = container.read(columnPresetIndexProvider).selectedKey;

    // New preset starts empty and becomes selected.
    final newKey = notifier.create('Other');
    expect(container.read(columnPresetIndexProvider).selectedKey, newKey);
    expect(container.read(currentColumnSpecsProvider), isEmpty);

    // Edits land in the selected preset only.
    container.read(currentColumnSpecsLoaderProvider.notifier).add(ColumnSpecMapper.fromMap(rangedIntegerMap('b')));
    expect(container.read(currentColumnSpecsProvider).map((e) => e.id).toList(), ['b']);

    // Switching back restores the original preset's specs.
    notifier.select(defaultKey);
    expect(container.read(currentColumnSpecsProvider).map((e) => e.id).toList(), ['a']);
  });

  test('duplicate copies the source preset specs verbatim', () async {
    seedLegacy([rangedIntegerMap('a')]);
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(columnPresetIndexProvider.notifier);
    final sourceKey = container.read(columnPresetIndexProvider).selectedKey;

    notifier.duplicate(sourceKey, 'Copy');
    expect(container.read(columnPresetIndexProvider).presets, hasLength(2));
    // The duplicate is selected and shows the same columns.
    expect(container.read(currentColumnSpecsProvider).map((e) => e.id).toList(), ['a']);
  });

  test('rename updates the preset title', () async {
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(columnPresetIndexProvider.notifier);
    final key = container.read(columnPresetIndexProvider).selectedKey;

    notifier.rename(key, 'Renamed');
    expect(container.read(columnPresetIndexProvider).selected!.title, 'Renamed');
  });

  test('deleting the selected preset falls back to another and drops its specs', () async {
    seedLegacy([rangedIntegerMap('a')]);
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(columnPresetIndexProvider.notifier);
    final defaultKey = container.read(columnPresetIndexProvider).selectedKey;

    final otherKey = notifier.create('Other');
    container.read(currentColumnSpecsLoaderProvider.notifier).add(ColumnSpecMapper.fromMap(rangedIntegerMap('b')));
    expect(Hive.box('column_spec').get(ColumnPresetIndex.specEntryKey(otherKey)), isNotNull);

    notifier.delete(otherKey);
    final index = container.read(columnPresetIndexProvider);
    expect(index.presets, hasLength(1));
    expect(index.selectedKey, defaultKey);
    expect(container.read(currentColumnSpecsProvider).map((e) => e.id).toList(), ['a']);
    // The deleted preset's specs entry is removed.
    expect(Hive.box('column_spec').get(ColumnPresetIndex.specEntryKey(otherKey)), isNull);
  });

  test('the last preset cannot be deleted', () async {
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(columnPresetIndexProvider.notifier);
    final key = container.read(columnPresetIndexProvider).selectedKey;

    notifier.delete(key);
    expect(container.read(columnPresetIndexProvider).presets, hasLength(1));
  });
}
