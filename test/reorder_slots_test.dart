// Unit tests for the pure reorder slot model that drives the live chip drag.
// computeReorderSlots is Flutter- and Hive-free, so these only need the mappers
// initialised to build leaf specs.
// Run: .fvm/flutter_sdk/bin/flutter test test/reorder_slots_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/logic.dart';
import 'package:umacapture/src/chara_detail/spec/reorder_slots.dart';
import 'package:umacapture/src/core/mapper_init.dart';

void main() {
  setUpAll(() {
    initializeMappers();
  });

  ColumnSpec leaf(String id) => ColumnSpecMapper.fromMap(<String, dynamic>{
    'type': 'RangedIntegerColumnSpec',
    'id': id,
    'title': id.toUpperCase(),
    'parser': <String, dynamic>{'type': 'FansParser'},
    'predicate': <String, dynamic>{'min': null, 'max': null},
    'cellAction': 'openCampaignPreview',
  });

  LogicColumnSpec logic(String id, LogicMode mode, List<ColumnSpec> children) =>
      LogicColumnSpec(id: id, title: id.toUpperCase(), logic: mode, children: children);

  test('A OR(B) C with dragged D yields the six canonical slots in order', () {
    final specs = [
      leaf('a'),
      logic('or', LogicMode.or, [leaf('b')]),
      leaf('c'),
      leaf('d'),
    ];

    final slots = computeReorderSlots(specs, 'd');

    // Reading right-to-left reproduces the requirement's "drag D leftward" steps.
    expect(slots, const [
      ReorderSlot(null, 0), // D A OR(B) C
      ReorderSlot(null, 1), // A D OR(B) C
      ReorderSlot('or', 0), // A OR(D B) C
      ReorderSlot('or', 1), // A OR(B D) C
      ReorderSlot(null, 2), // A OR(B) D C
      ReorderSlot(null, 3), // A OR(B) C D
    ]);
  });

  test('a dragged id that is not present yields no slots', () {
    final specs = [leaf('a'), leaf('b')];

    expect(computeReorderSlots(specs, 'missing'), isEmpty);
  });

  test('an empty container contributes exactly one inner slot', () {
    final specs = [logic('and', LogicMode.and, const []), leaf('l'), leaf('d')];

    final slots = computeReorderSlots(specs, 'd');

    expect(slots, const [ReorderSlot(null, 0), ReorderSlot('and', 0), ReorderSlot(null, 1), ReorderSlot(null, 2)]);
  });

  test('a NOT already holding a (non-dragged) child exposes no inner slot', () {
    final specs = [
      logic('not', LogicMode.not, [leaf('x')]),
      leaf('d'),
    ];

    final slots = computeReorderSlots(specs, 'd');

    expect(slots.where((s) => s.parentId == 'not'), isEmpty);
    expect(slots, const [ReorderSlot(null, 0), ReorderSlot(null, 1)]);
  });

  test('an empty NOT exposes a single inner slot', () {
    final specs = [logic('not', LogicMode.not, const []), leaf('d')];

    final slots = computeReorderSlots(specs, 'd');

    expect(slots, const [ReorderSlot(null, 0), ReorderSlot('not', 0), ReorderSlot(null, 1)]);
  });

  test('nested containers recurse parent-gap, descend, child-gaps, ascend', () {
    final specs = [
      logic('and', LogicMode.and, [
        logic('or', LogicMode.or, [leaf('x')]),
      ]),
      leaf('d'),
    ];

    final slots = computeReorderSlots(specs, 'd');

    expect(slots, const [
      ReorderSlot(null, 0),
      ReorderSlot('and', 0),
      ReorderSlot('or', 0),
      ReorderSlot('or', 1),
      ReorderSlot('and', 1),
      ReorderSlot(null, 1),
    ]);
  });

  test('dragging a non-empty container removes its whole subtree from the slots', () {
    final specs = [
      leaf('a'),
      logic('or', LogicMode.or, [leaf('b')]),
    ];

    final slots = computeReorderSlots(specs, 'or');

    // No slot references the dragged container or its child b.
    expect(slots, const [ReorderSlot(null, 0), ReorderSlot(null, 1)]);
  });
}
