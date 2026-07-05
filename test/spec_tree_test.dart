// Unit tests for the pure forest algebra that backs column-selection tree edits
// (insert/detach/lift/replace/flatten). These helpers are Flutter- and Hive-free;
// only the mappers are needed to build leaf specs via ColumnSpecMapper.fromMap.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/spec_tree_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/logic.dart';
import 'package:umacapture/src/chara_detail/spec/spec_tree.dart';
import 'package:umacapture/src/core/mapper_init.dart';

void main() {
  setUpAll(initializeMappers);

  ColumnSpec leaf(String id) => ColumnSpecMapper.fromMap(<String, dynamic>{
    'type': 'RangedIntegerColumnSpec',
    'id': id,
    'title': id.toUpperCase(),
    'parser': <String, dynamic>{'type': 'FansParser'},
    'predicate': <String, dynamic>{'min': null, 'max': null},
    'cellAction': 'openCampaignPreview',
  });

  LogicColumnSpec container(String id, List<ColumnSpec> children) =>
      LogicColumnSpec(id: id, title: id.toUpperCase(), logic: LogicMode.and, children: children);

  List<String> ids(List<ColumnSpec> specs) => [for (final s in specs) s.id];

  group('findInForest', () {
    test('finds a top-level spec', () {
      expect(findInForest([leaf('a'), leaf('b')], 'b')?.id, 'b');
    });

    test('finds a deeply nested spec', () {
      final forest = [
        leaf('a'),
        container('g', [
          leaf('b'),
          container('h', [leaf('c')]),
        ]),
      ];
      expect(findInForest(forest, 'c')?.id, 'c');
    });

    test('returns null for an absent id and an empty forest', () {
      expect(findInForest([leaf('a')], 'x'), isNull);
      expect(findInForest(const [], 'a'), isNull);
    });
  });

  group('detachFromForest', () {
    test('removes a top-level spec and reports it', () {
      final (forest, removed) = detachFromForest([leaf('a'), leaf('b')], 'a');
      expect(ids(forest), ['b']);
      expect(removed?.id, 'a');
    });

    test('removes a nested spec, rebuilding only its parent branch', () {
      final (forest, removed) = detachFromForest([
        container('g', [leaf('b'), leaf('c')]),
      ], 'b');
      expect(removed?.id, 'b');
      final group = forest.single as LogicColumnSpec;
      expect(ids(group.children), ['c']);
    });

    test('leaves the forest unchanged and reports null when absent', () {
      final input = [leaf('a'), leaf('b')];
      final (forest, removed) = detachFromForest(input, 'x');
      expect(removed, isNull);
      expect(ids(forest), ['a', 'b']);
    });
  });

  group('insertIntoForest', () {
    test('inserts into the top level at the given index', () {
      final result = insertIntoForest([leaf('a'), leaf('c')], null, 1, leaf('b'));
      expect(ids(result), ['a', 'b', 'c']);
    });

    test('clamps an out-of-range index to the ends', () {
      expect(ids(insertIntoForest([leaf('a')], null, 99, leaf('z'))), ['a', 'z']);
      expect(ids(insertIntoForest([leaf('a')], null, -5, leaf('z'))), ['z', 'a']);
    });

    test('inserts into a target container by id', () {
      final result = insertIntoForest(
        [
          container('g', [leaf('b')]),
        ],
        'g',
        1,
        leaf('d'),
      );
      final group = result.single as LogicColumnSpec;
      expect(ids(group.children), ['b', 'd']);
    });

    test('does not mutate the input list', () {
      final input = [leaf('a'), leaf('c')];
      insertIntoForest(input, null, 1, leaf('b'));
      expect(ids(input), ['a', 'c']);
    });
  });

  group('removeLifting', () {
    test('dissolves a container, lifting its children into its slot', () {
      final result = removeLifting([
        leaf('a'),
        container('g', [leaf('b'), leaf('c')]),
        leaf('d'),
      ], 'g');
      expect(ids(result!), ['a', 'b', 'c', 'd']);
    });

    test('lifts a nested container in place', () {
      final result = removeLifting([
        container('outer', [
          leaf('a'),
          container('inner', [leaf('b')]),
        ]),
      ], 'inner');
      final outer = result!.single as LogicColumnSpec;
      expect(ids(outer.children), ['a', 'b']);
    });

    test('returns null when the id is absent', () {
      expect(removeLifting([leaf('a')], 'x'), isNull);
    });
  });

  group('replaceInForest', () {
    test('replaces a top-level spec with the given instance', () {
      final replacement = leaf('a');
      final result = replaceInForest([leaf('a'), leaf('b')], replacement);
      expect(identical(result![0], replacement), isTrue);
    });

    test('replaces a nested spec sharing the replacement id', () {
      final replacement = leaf('b');
      final result = replaceInForest([
        container('g', [leaf('b')]),
      ], replacement);
      final group = result!.single as LogicColumnSpec;
      expect(identical(group.children.single, replacement), isTrue);
    });

    test('returns null when no spec has the replacement id', () {
      expect(replaceInForest([leaf('a')], leaf('x')), isNull);
    });
  });

  group('flattenForest', () {
    test('emits each parent immediately before its children, depth-first', () {
      final forest = [
        leaf('a'),
        container('g', [
          leaf('b'),
          container('h', [leaf('c')]),
        ]),
        leaf('d'),
      ];
      expect(ids(flattenForest(forest)), ['a', 'g', 'b', 'h', 'c', 'd']);
    });

    test('an empty forest flattens to empty', () {
      expect(flattenForest(const []), isEmpty);
    });
  });
}
