import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/item_cell.dart';

String _name(int id) => 'n$id';

CellItem _held(String text) => CellItem(text, ItemState.held);

/// The order of an absence cell over [query] with no master: query position, then id.
ItemOrder _byQuery(List<int> query) => ItemOrder(query: query, masterRank: const {});

final _byId = ItemOrder(query: const [], masterRank: const {});

void main() {
  group('absenceItems', () {
    // Skill, any logic: no per-item threshold, so every own item is held.
    test('skill: own items are held, unheld query items are missing placeholders, all in query order', () {
      final items = absenceItems(
        [const OwnItem(1, 'n1'), const OwnItem(3, 'n3', meetsQuery: false)],
        [1, 2, 3, 4],
        _name,
        _byQuery([1, 2, 3, 4]),
        perItemThreshold: false,
      );
      expect(items, [
        _held('n1'),
        const CellItem('n2', ItemState.missing),
        _held('n3'),
        const CellItem('n4', ItemState.missing),
      ]);
    });

    // Factor anyOf/allOf, starOnly: meetsQuery is `sum >= star`.
    test('factor starOnly: an item below the star floor is short, one at it is held', () {
      final items = absenceItems(
        [const OwnItem(1, 'n1(2)', meetsQuery: false), const OwnItem(2, 'n2(3)')],
        [1, 2, 5],
        _name,
        _byQuery([1, 2, 5]),
        perItemThreshold: true,
      );
      expect(items, [
        const CellItem('n1(2)', ItemState.short),
        _held('n2(3)'),
        const CellItem('n5', ItemState.missing),
      ]);
    });

    // Factor anyOf/allOf, countOnly (R3): too few slots is red too.
    test('factor countOnly: an item held in too few slots is short', () {
      final items = absenceItems(
        [const OwnItem(7, 'n7(1)', meetsQuery: false), const OwnItem(8, 'n8(3)')],
        [7, 8],
        _name,
        _byQuery([7, 8]),
        perItemThreshold: true,
      );
      expect(items, [const CellItem('n7(1)', ItemState.short), _held('n8(3)')]);
    });

    // Factor anyOf/allOf, starAndCount: meetsQuery is the count of slots meeting the star floor.
    test('factor starAndCount: an item with too few slots at the star floor is short', () {
      final items = absenceItems(
        [const OwnItem(4, 'n4(6)', meetsQuery: false), const OwnItem(9, 'n9(2)')],
        [9, 4, 6],
        _name,
        _byQuery([9, 4, 6]),
        perItemThreshold: true,
      );
      expect(items, [
        _held('n9(2)'),
        const CellItem('n4(6)', ItemState.short),
        const CellItem('n6', ItemState.missing),
      ]);
    });

    // Factor mixed: the threshold is on the whole query, so no item is short.
    test('factor mixed: own items are held whatever their per-item result', () {
      final items = absenceItems(
        [const OwnItem(1, 'n1(1)', meetsQuery: false)],
        [1, 2],
        _name,
        _byQuery([1, 2]),
        perItemThreshold: false,
      );
      expect(items, [_held('n1(1)'), const CellItem('n2', ItemState.missing)]);
    });

    test('an empty query shows no placeholder', () {
      expect(absenceItems([const OwnItem(1, 'n1')], const [], _name, _byId, perItemThreshold: true), [_held('n1')]);
    });
  });

  group('differenceItems', () {
    final tally = ItemTally.of([
      {1, 2, 3},
      {1, 2},
      {1, 4},
    ]);

    test('tally counts holders per item in first-seen order', () {
      expect(tally.rowCount, 3);
      expect(tally.holders, {1: 3, 2: 2, 3: 1, 4: 1});
    });

    test('an item every row holds is common; one some rows hold is partialHeld with its strength', () {
      final items = differenceItems(
        [const OwnItem(1, 'n1', strength: 5), const OwnItem(2, 'n2', strength: 4)],
        tally,
        _name,
        _byId,
        strengthMax: 9,
      );
      expect(items.take(2), [
        const CellItem('n1', ItemState.common),
        const CellItem('n2', ItemState.partialHeld, strength: 4, strengthMax: 9),
      ]);
    });

    test('an item some other rows hold is a partialMissing placeholder; one no row lacks is not', () {
      final items = differenceItems(
        [const OwnItem(1, 'n1'), const OwnItem(2, 'n2')],
        tally,
        _name,
        _byId,
        strengthMax: 1,
      );
      expect(items.skip(2), [
        const CellItem('n3', ItemState.partialMissing),
        const CellItem('n4', ItemState.partialMissing),
      ]);
    });

    test('items are in master order whatever the row order, held and placeholder interleaved', () {
      const own = [OwnItem(1, 'n1')];
      final order = ItemOrder(query: const [], masterRank: const {9: 0, 4: 1, 1: 2, 2: 3});
      final forward = ItemTally.of([
        {1},
        {9},
        {4, 1},
        {2},
      ]);
      final reversed = ItemTally.of([
        {2},
        {4, 1},
        {9},
        {1},
      ]);
      const expected = [
        CellItem('n9', ItemState.partialMissing),
        CellItem('n4', ItemState.partialMissing),
        CellItem('n1', ItemState.partialHeld, strengthMax: 1),
        CellItem('n2', ItemState.partialMissing),
      ];
      expect(differenceItems(own, forward, _name, order, strengthMax: 1), expected);
      expect(differenceItems(own, reversed, _name, order, strengthMax: 1), expected);
    });

    test('a one-row group makes every item common and shows no placeholder', () {
      final single = ItemTally.of([
        {5, 6},
      ]);
      final items = differenceItems(
        [const OwnItem(5, 'n5', strength: 3), const OwnItem(6, 'n6', strength: 1)],
        single,
        _name,
        _byId,
        strengthMax: 3,
      );
      expect(items, [const CellItem('n5', ItemState.common), const CellItem('n6', ItemState.common)]);
    });
  });

  group('ItemCellData.limited', () {
    const own1 = CellItem('a', ItemState.partialHeld, strength: 1, strengthMax: 3);
    const common = CellItem('c', ItemState.common);
    const own2 = CellItem('b', ItemState.held);
    const red1 = CellItem('x', ItemState.missing);
    const red2 = CellItem('y', ItemState.partialMissing);

    ItemCellData limited(List<CellItem> items, int? max, {bool hideCommon = false}) =>
        ItemCellData.limited(items, max, hideCommon: hideCommon, csv: '');

    test('max applies to the whole list and can cut placeholders; the total counts what it cut', () {
      final data = limited([own1, own2, red1, red2], 3);
      expect(data.items, [own1, own2, red1]);
      expect(data.total, 4);
    });

    test('hideCommon removes common items before max is applied, and the total does not count them', () {
      final data = limited([common, own1, common, red1, red2], 2, hideCommon: true);
      expect(data.items, [own1, red1]);
      expect(data.total, 3);
    });

    test('without hideCommon, common items count toward max and the total', () {
      final data = limited([common, own1, red1], 2);
      expect(data.items, [common, own1]);
      expect(data.total, 3);
    });

    test('all-held items are cut exactly like the normal display', () {
      final items = [
        for (final t in ['p', 'q', 'r', 's']) _held(t),
      ];
      expect(limited(items, 3).items, items.sublist(0, 3));
      expect(limited(items, 3).total, 4);
      expect(limited(items, 10).items, items);
      expect(limited(items, 10).total, 4);
    });

    test('a null max keeps every item, after hideCommon, and cuts nothing', () {
      expect(limited([own1, own2, red1, red2], null).items, [own1, own2, red1, red2]);
      expect(limited([own1, own2, red1, red2], null).total, 4);
      final hidden = limited([common, own1, red1], null, hideCommon: true);
      expect(hidden.items, [own1, red1]);
      expect(hidden.total, 2);
    });
  });

  group('ItemOrder', () {
    final order = ItemOrder(query: const [7, 3], masterRank: const {5: 0, 3: 1, 1: 2, 7: 3});

    test('query position first, then master position, then id for an id in neither', () {
      expect(order.sort([1, 12, 5, 3, 10, 7], (e) => e), [7, 3, 5, 1, 10, 12]);
    });

    test('an id the master lacks and the query names still sorts by its query position', () {
      final lagging = ItemOrder(query: const [8, 5], masterRank: const {5: 0});
      expect(lagging.sort([5, 8, 6], (e) => e), [8, 5, 6]);
    });

    test('sorting is stable for repeated ids', () {
      final items = [(1, 'a'), (5, 'b'), (1, 'c')];
      expect(order.sort(items, (e) => e.$1), [(5, 'b'), (1, 'a'), (1, 'c')]);
    });
  });

  group('value equality', () {
    ItemCellData cell({String text = 'a', ItemState state = ItemState.held, String? summary, String csv = 'csv'}) =>
        ItemCellData(items: summary == null ? [CellItem(text, state)] : const [], summary: summary, csv: csv);

    test('equal content is == with the same hashCode', () {
      expect(cell(), cell());
      expect(cell().hashCode, cell().hashCode);
      expect(cell().paintState, cell().paintState);
    });

    test('one differing field makes cells unequal', () {
      expect(cell(state: ItemState.missing), isNot(cell()));
      expect(cell(text: 'b'), isNot(cell()));
      expect(cell(csv: 'other'), isNot(cell()));
      expect(cell(summary: '3'), isNot(cell(summary: '4')));
      expect(cell().paintState, isNot(cell(state: ItemState.short).paintState));
    });

    test('CellItem compares all four fields', () {
      const base = CellItem('a', ItemState.partialHeld, strength: 1, strengthMax: 3);
      expect(const CellItem('a', ItemState.partialHeld, strength: 1, strengthMax: 3), base);
      expect(const CellItem('a', ItemState.partialHeld, strength: 1, strengthMax: 3).hashCode, base.hashCode);
      expect(const CellItem('a', ItemState.partialHeld, strength: 2, strengthMax: 3), isNot(base));
      expect(const CellItem('a', ItemState.partialHeld, strength: 1, strengthMax: 9), isNot(base));
      expect(const CellItem('a', ItemState.common, strength: 1, strengthMax: 3), isNot(base));
    });

    test('the total is part of the value, and defaults to the items listed', () {
      final items = [_held('a'), _held('b')];
      expect(ItemCellData(items: items, csv: '').total, 2);
      expect(ItemCellData(items: items, csv: ''), ItemCellData(items: items, total: 2, csv: ''));
      expect(ItemCellData(items: items, total: 5, csv: ''), isNot(ItemCellData(items: items, total: 4, csv: '')));
    });
  });
}
