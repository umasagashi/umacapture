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

  test('injectInto moves a column under a logic column; extract returns it to top level', () async {
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(currentColumnSpecsLoaderProvider.notifier);

    notifier.add(makeLogic('and', LogicMode.and));
    notifier.add(makeSpec('a', 'A'));
    notifier.add(makeSpec('b', 'B'));

    // Inject a into the AND column: a leaves the top level and nests under it.
    notifier.injectInto(notifier.getById('and')!, notifier.getById('a')!);
    expect(topIds(container), ['and', 'b']);
    final and = notifier.getById('and')! as LogicColumnSpec;
    expect(and.children.map((e) => e.id).toList(), ['a']);

    // Persisted nesting survives a reopen.
    final reopened = ProviderContainer.test();
    await reopened.read(currentColumnSpecsLoaderProvider.future);
    final restoredAnd = reopened.read(currentColumnSpecsProvider).first as LogicColumnSpec;
    expect(restoredAnd.children.single.id, 'a');

    // Extract a back to the top level (appended at the end).
    notifier.extract(notifier.getById('a')!);
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
    notifier.injectInto(notifier.getById('or')!, notifier.getById('a')!);
    notifier.injectInto(notifier.getById('or')!, notifier.getById('b')!);
    expect(topIds(container), ['or']);

    notifier.removeIfExists('or');
    // Children take the slot the logic column occupied.
    expect(topIds(container), ['a', 'b']);
  });

  test('NOT accepts only a single input', () async {
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(currentColumnSpecsLoaderProvider.notifier);

    notifier.add(makeLogic('not', LogicMode.not));
    notifier.add(makeSpec('a', 'A'));
    notifier.add(makeSpec('b', 'B'));

    notifier.injectInto(notifier.getById('not')!, notifier.getById('a')!);
    expect((notifier.getById('not')! as LogicColumnSpec).children.map((e) => e.id).toList(), ['a']);

    // Second injection is rejected; b stays at the top level.
    notifier.injectInto(notifier.getById('not')!, notifier.getById('b')!);
    expect((notifier.getById('not')! as LogicColumnSpec).children.map((e) => e.id).toList(), ['a']);
    expect(topIds(container), ['not', 'b']);
  });

  test('injecting an ancestor into its own descendant is rejected (cycle guard)', () async {
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(currentColumnSpecsLoaderProvider.notifier);

    notifier.add(makeLogic('outer', LogicMode.and));
    notifier.add(makeLogic('inner', LogicMode.or));
    notifier.injectInto(notifier.getById('outer')!, notifier.getById('inner')!);
    expect(topIds(container), ['outer']);

    // outer is an ancestor of inner; injecting outer into inner would form a cycle.
    notifier.injectInto(notifier.getById('inner')!, notifier.getById('outer')!);
    // Unchanged: outer still top-level, inner still its child.
    expect(topIds(container), ['outer']);
    expect((notifier.getById('outer')! as LogicColumnSpec).children.single.id, 'inner');
  });

  test('nested logic columns round-trip through persistence', () async {
    final container = ProviderContainer.test();
    await container.read(currentColumnSpecsLoaderProvider.future);
    final notifier = container.read(currentColumnSpecsLoaderProvider.notifier);

    notifier.add(makeLogic('outer', LogicMode.and));
    notifier.add(makeLogic('inner', LogicMode.or));
    notifier.add(makeSpec('leaf', 'Leaf'));
    notifier.injectInto(notifier.getById('inner')!, notifier.getById('leaf')!);
    notifier.injectInto(notifier.getById('outer')!, notifier.getById('inner')!);

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
