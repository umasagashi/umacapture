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
}
