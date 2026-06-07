// Provider test for the riskiest Phase 3 rewrite: ColumnSpecSelection, now an
// AsyncNotifier persisting to Hive. Verifies add/remove/reorder reflect in the
// thin currentColumnSpecsProvider and survive a fresh ProviderContainer (i.e.
// the rebuild()/entry.push() round-trips through storage).
// Run: .fvm/flutter_sdk/bin/flutter test test/column_spec_selection_test.dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/spec/logic.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/chara_detail/spec/ranged_integer.dart';
import 'package:umacapture/src/core/mapper_init.dart';

void main() {
  setUpAll(() async {
    // The column_spec box stores a plain JSON string, so no Hive type adapters
    // are required; an in-memory temp dir is enough.
    Hive.init(Directory.systemTemp.createTempSync('umacapture_cs_test').path);
    initializeMappers();
    await Hive.openBox('column_spec');
  });

  setUp(() async {
    await Hive.box('column_spec').clear();
  });

  ColumnSpec makeSpec(String id, String title) => ColumnSpecMapper.fromMap(<String, dynamic>{
    'type': 'RangedIntegerColumnSpec',
    'id': id,
    'title': title,
    'parser': <String, dynamic>{'type': 'FansParser'},
    'predicate': <String, dynamic>{'min': null, 'max': null},
    'cellAction': 'openCampaignPreview',
  });

  test('add / reorder / remove reflect in the sync view and persist', () async {
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(currentColumnSpecsLoaderProvider.notifier);

    expect(container.read(currentColumnSpecsProvider), isEmpty);

    final a = makeSpec('a', 'A');
    final b = makeSpec('b', 'B');
    notifier.add(a);
    notifier.add(b);
    expect(container.read(currentColumnSpecsProvider).map((e) => e.id).toList(), ['a', 'b']);

    // Move a to after b.
    notifier.moveTo(a, b);
    expect(container.read(currentColumnSpecsProvider).map((e) => e.id).toList(), ['b', 'a']);

    notifier.removeIfExists('b');
    expect(container.read(currentColumnSpecsProvider).map((e) => e.id).toList(), ['a']);

    // A fresh container must re-decode the persisted selection from Hive.
    final reopened = ProviderContainer.test();
    await reopened.read(currentColumnSpecsLoaderProvider.future);
    expect(reopened.read(currentColumnSpecsProvider).map((e) => e.id).toList(), ['a']);
  });

  test('parser nested under the spec round-trips through persistence', () async {
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    container.read(currentColumnSpecsLoaderProvider.notifier).add(makeSpec('x', 'X'));

    final reopened = ProviderContainer.test();
    await reopened.read(currentColumnSpecsLoaderProvider.future);
    final restored = reopened.read(currentColumnSpecsProvider).single;
    expect(restored, isA<RangedIntegerColumnSpec>());
    expect((restored as RangedIntegerColumnSpec).parser, isA<FansParser>());
  });

  LogicColumnSpec makeLogic(String id, LogicMode logic) =>
      LogicColumnSpec(id: id, title: id.toUpperCase(), logic: logic);

  // Top-level ids of the live selection, for compact assertions.
  List<String> topIds(ProviderContainer c) => c.read(currentColumnSpecsProvider).map((e) => e.id).toList();

  test('moveToSlot nests a column under a logic column and back to top level', () async {
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(currentColumnSpecsLoaderProvider.notifier);

    notifier.add(makeLogic('and', LogicMode.and));
    notifier.add(makeSpec('a', 'A'));
    notifier.add(makeSpec('b', 'B'));

    // Nest a into the AND column: a leaves the top level and nests under it.
    notifier.moveToSlot('a', 'and', 0);
    expect(topIds(container), ['and', 'b']);
    final and = notifier.getById('and')! as LogicColumnSpec;
    expect(and.children.map((e) => e.id).toList(), ['a']);

    // Persisted nesting survives a reopen.
    final reopened = ProviderContainer.test();
    await reopened.read(currentColumnSpecsLoaderProvider.future);
    final restoredAnd = reopened.read(currentColumnSpecsProvider).first as LogicColumnSpec;
    expect(restoredAnd.children.single.id, 'a');

    // Move a back to the end of the top level (index is against the detached tree).
    notifier.moveToSlot('a', null, 2);
    expect(topIds(container), ['and', 'b', 'a']);
    expect((notifier.getById('and')! as LogicColumnSpec).children, isEmpty);
  });

  test('removing a logic column lifts its children back to normal columns', () async {
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(currentColumnSpecsLoaderProvider.notifier);

    notifier.add(makeLogic('or', LogicMode.or));
    notifier.add(makeSpec('a', 'A'));
    notifier.add(makeSpec('b', 'B'));
    notifier.moveToSlot('a', 'or', 0);
    notifier.moveToSlot('b', 'or', 1);
    expect(topIds(container), ['or']);

    notifier.removeIfExists('or');
    // Children take the slot the logic column occupied.
    expect(topIds(container), ['a', 'b']);
  });

  test('moveToSlot reorders within the top level', () async {
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(currentColumnSpecsLoaderProvider.notifier);

    notifier.add(makeSpec('a', 'A'));
    notifier.add(makeLogic('or', LogicMode.or));
    notifier.add(makeSpec('c', 'C'));
    notifier.add(makeSpec('d', 'D'));

    // Move d to the top-level index 2 (computed against the tree without d).
    notifier.moveToSlot('d', null, 2);
    expect(topIds(container), ['a', 'or', 'd', 'c']);
  });

  test('moveToSlot injects a column under a logic column', () async {
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(currentColumnSpecsLoaderProvider.notifier);

    notifier.add(makeSpec('a', 'A'));
    notifier.add(makeLogic('or', LogicMode.or));
    notifier.add(makeSpec('b', 'B'));
    notifier.add(makeSpec('c', 'C'));
    notifier.add(makeSpec('d', 'D'));
    notifier.moveToSlot('b', 'or', 0);

    // Drop d into the OR column after b.
    notifier.moveToSlot('d', 'or', 1);
    expect(topIds(container), ['a', 'or', 'c']);
    expect((notifier.getById('or')! as LogicColumnSpec).children.map((e) => e.id).toList(), ['b', 'd']);
  });

  test('moveToSlot of a missing id is a no-op', () async {
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(currentColumnSpecsLoaderProvider.notifier);

    notifier.add(makeSpec('a', 'A'));
    notifier.add(makeSpec('b', 'B'));

    notifier.moveToSlot('missing', null, 0);
    expect(topIds(container), ['a', 'b']);
  });

  test('moveToSlot extracts an injected child back to the top level and persists', () async {
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(currentColumnSpecsLoaderProvider.notifier);

    notifier.add(makeLogic('or', LogicMode.or));
    notifier.add(makeSpec('a', 'A'));
    notifier.moveToSlot('a', 'or', 0);
    expect(topIds(container), ['or']);

    // Extracting is just a slot move to the end of the top-level list.
    notifier.moveToSlot('a', null, 1);
    expect(topIds(container), ['or', 'a']);
    expect((notifier.getById('or')! as LogicColumnSpec).children, isEmpty);

    final reopened = ProviderContainer.test();
    await reopened.read(currentColumnSpecsLoaderProvider.future);
    expect(reopened.read(currentColumnSpecsProvider).map((e) => e.id).toList(), ['or', 'a']);
  });

  test('nested logic columns round-trip through persistence', () async {
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(currentColumnSpecsLoaderProvider.notifier);

    notifier.add(makeLogic('outer', LogicMode.and));
    notifier.add(makeLogic('inner', LogicMode.or));
    notifier.add(makeSpec('leaf', 'Leaf'));
    notifier.moveToSlot('leaf', 'inner', 0);
    notifier.moveToSlot('inner', 'outer', 0);

    final reopened = ProviderContainer.test();
    await reopened.read(currentColumnSpecsLoaderProvider.future);
    final outer = reopened.read(currentColumnSpecsProvider).single as LogicColumnSpec;
    expect(outer.logic, LogicMode.and);
    final inner = outer.children.single as LogicColumnSpec;
    expect(inner.logic, LogicMode.or);
    expect(inner.children.single, isA<RangedIntegerColumnSpec>());
    expect(inner.children.single.id, 'leaf');
  });
}
