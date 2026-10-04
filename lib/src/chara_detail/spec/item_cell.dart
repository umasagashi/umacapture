import 'dart:collection' show ListBase;
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' hide mergeSort;

import '/src/chara_detail/spec/base.dart';

/// How one item of a skill or factor cell is painted.
enum ItemState {
  /// The record has the item (outline background), and nothing judges it on its own: every held item of a column
  /// that does not mark missing items, and a held item a marking column has no per-item judgement for.
  normal,

  /// The record has a queried item that passes the per-item judgement (green). A column that marks missing items:
  /// a held skill, or a factor that reaches the per-item threshold.
  met,

  /// The record lacks a queried item (red placeholder). A column that marks missing items.
  missing,

  /// The record has a queried item but below the per-item threshold (red). A column that marks missing items, factors only.
  short,

  /// Every compared record has the item with the same strength (green, shaded by strength, may be hidden). A
  /// difference column.
  common,

  /// Some compared records have the item, or every record does at differing strengths, this one included
  /// (green, shaded by strength). A difference column.
  partialHeld,

  /// Some compared records have the item, this one not (red placeholder). A difference column.
  partialMissing,
}

/// The text of one item: what is drawn, and the segments it is measured in. A factor drawn with its value is its
/// name followed by the value, measured apart so that a name is measured once for every value it is drawn with;
/// every other text is one segment. [whole] is made from the segments here and nowhere else, so what is drawn is
/// always what is measured.
@immutable
class ItemText {
  /// A text measured as one segment.
  const ItemText(this.whole) : name = whole, value = null;

  /// [name] followed by [value], which carries its own separator (e.g. ` (3)`).
  const ItemText.valued(this.name, String this.value) : whole = '$name$value';

  /// What is drawn: [name] followed by [value].
  final String whole;

  /// The first segment; the whole text when there is no [value].
  final String name;

  /// The second segment, measured apart from [name].
  final String? value;

  @override
  bool operator ==(Object other) => other is ItemText && other.name == name && other.value == value;

  @override
  int get hashCode => Object.hash(name, value);

  @override
  String toString() => whole;
}

/// One item drawn in a cell, compared by value.
@immutable
class CellItem {
  /// The text drawn: the name, or the name with its notation (e.g. `name (3)`).
  final ItemText text;
  final ItemState state;

  /// Input to the green shade of [ItemState.common] and [ItemState.partialHeld]; 0 for every other state.
  final int strength;

  /// Top of the shade scale for [strength]: the item's [ItemTally.maxStrengthOf] over the compared rows; 0 for every
  /// other state.
  final int strengthMax;

  const CellItem(this.text, this.state, {this.strength = 0, this.strengthMax = 0});

  @override
  bool operator ==(Object other) =>
      other is CellItem &&
      other.text == text &&
      other.state == state &&
      other.strength == strength &&
      other.strengthMax == strengthMax;

  @override
  int get hashCode => Object.hash(text, state, strength, strengthMax);

  @override
  String toString() => 'CellItem($text, ${state.name}, $strength/$strengthMax)';
}

/// An item the record itself has, before it is given a state.
@immutable
class OwnItem {
  final int id;

  /// The text drawn, notation included.
  final ItemText text;

  /// Whether the item passes the per-item judgement of the query, or null where nothing judges it on its own.
  final bool? meetsQuery;

  /// Strength within the comparison scope (the star sum for a factor).
  final int strength;

  const OwnItem(this.id, this.text, {this.meetsQuery, this.strength = 0});
}

/// How many of the compared rows hold each item of one column, the strongest holding of each, and which items
/// they have in common.
@immutable
class ItemTally {
  final int rowCount;

  /// Item id to the number of rows holding it, in the order the ids were first seen.
  final Map<int, int> holders;

  /// Ids of the items every compared row holds with the same strength (for a factor, the same star sum).
  /// An item every row holds at differing strengths is not common.
  final Set<int> common;

  /// Item id to the largest strength any compared row holds it at (for a factor, the largest star sum).
  final Map<int, int> maxStrengths;

  const ItemTally._(this.rowCount, this.holders, this.common, this.maxStrengths);

  /// [heldPerRow] gives each row's held items as item id to strength.
  factory ItemTally.of(Iterable<Map<int, int>> heldPerRow) {
    var rowCount = 0;
    final holders = <int, int>{};
    final strengths = <int, int>{};
    final maxStrengths = <int, int>{};
    final uneven = <int>{};
    for (final held in heldPerRow) {
      rowCount++;
      for (final MapEntry(key: id, value: strength) in held.entries) {
        holders[id] = (holders[id] ?? 0) + 1;
        if (strengths.putIfAbsent(id, () => strength) != strength) {
          uneven.add(id);
        }
        maxStrengths[id] = math.max(maxStrengths[id] ?? strength, strength);
      }
    }
    final common = {
      for (final MapEntry(key: id, value: count) in holders.entries)
        if (count >= rowCount && !uneven.contains(id)) id,
    };
    return ItemTally._(rowCount, Map.unmodifiable(holders), Set.unmodifiable(common), Map.unmodifiable(maxStrengths));
  }

  int holdersOf(int id) => holders[id] ?? 0;

  bool isCommon(int id) => common.contains(id);

  /// Whether some but not all compared rows hold [id]: the items a difference cell marks where a row lacks them.
  bool isPartial(int id) {
    final count = holdersOf(id);
    return count > 0 && count < rowCount;
  }

  int maxStrengthOf(int id) => maxStrengths[id] ?? 0;
}

/// Cell data of a skill or factor column: the items to draw, each with its state.
///
/// Compared by value, and that value is its [paintState], so a change of state alone replaces the row.
@immutable
class ItemCellData implements RenderedCellData {
  /// Every item of the cell in drawing order, with common items already hidden where the column hides them.
  final List<CellItem> items;

  /// A value-only notation (e.g. a count). When non-null, [items] is empty.
  final String? summary;

  @override
  final String csv;

  ItemCellData({required List<CellItem> items, this.summary, required this.csv})
    : items = List.unmodifiable(items),
      assert(summary == null || items.isEmpty);

  /// [items], less the [ItemState.common] ones when [hideCommon]. Every remaining item is kept, placeholders
  /// included; how many are shown is decided when the cell is drawn.
  factory ItemCellData.listing(List<CellItem> items, {required bool hideCommon, required String csv}) {
    return ItemCellData(items: hideCommon ? items.where((e) => e.state != ItemState.common).toList() : items, csv: csv);
  }

  /// A difference-display cell: the record's [own] items against the compared rows' tally, as
  /// [ItemState.common] or [ItemState.partialHeld], both shaded by the item's strength against the strongest holding
  /// of that item among them ([ItemTally.maxStrengthOf]), and the column's [placeholders] the record does not hold,
  /// together in the placeholders' order, so a row's cell does not depend on the row order. The common items are
  /// left out when [hideCommon]. The placeholders are shared with every row of the build, not copied into [items].
  ItemCellData.difference(
    List<OwnItem> own,
    DifferencePlaceholders placeholders, {
    required bool hideCommon,
    required this.csv,
  }) : items = _DifferenceItems(own, placeholders, hideCommon: hideCommon),
       summary = null;

  @override
  Object get paintState => this;

  @override
  CellSelectedCallback? get onSelected => null;

  @override
  bool operator ==(Object other) =>
      other is ItemCellData && other.summary == summary && other.csv == csv && _itemsEqual(other.items, items);

  /// Hashes [items] less the [ItemState.partialMissing] ones: equal lists have equal such subsequences, and a
  /// difference cell's is its own items, so it hashes without reading the placeholders it shares.
  @override
  int get hashCode => Object.hash(
    summary,
    csv,
    Object.hashAll(switch (items) {
      final _DifferenceItems difference => difference._own.map((e) => e.$2),
      final other => other.where((e) => e.state != ItemState.partialMissing),
    }),
  );

  /// Two difference cells over equal placeholders with equal own items are equal without walking either; any
  /// other pair is compared item by item.
  static bool _itemsEqual(List<CellItem> a, List<CellItem> b) {
    if (a is _DifferenceItems && b is _DifferenceItems && a._equalsByParts(b)) {
      return true;
    }
    return a.length == b.length && const IterableEquality<CellItem>().equals(a, b);
  }
}

/// The placeholders of one difference column for one grid build: an [ItemState.partialMissing] item for each item
/// some but not all rows of [tally] hold ([ItemTally.isPartial]), in [order]. A row's cell shows the ones the row does
/// not hold itself ([ItemCellData.difference]), so every row of the build shares these, made once for the column.
@immutable
class DifferencePlaceholders {
  final ItemTally tally;
  final ItemOrder order;

  /// The placeholder ids in [order], and the placeholder of each at the same index.
  final List<int> _ids;
  final List<CellItem> _items;

  /// Placeholders this one was compared with by value ([_equals]), to the result. A rebuild compares every row of
  /// the new build with the previous build's, all with the same two placeholders, so the comparison is made once.
  final _compared = Expando<bool>();

  DifferencePlaceholders._(this.tally, this.order, this._ids, this._items);

  /// [placeholderOf] gives a placeholder's text.
  factory DifferencePlaceholders.of(ItemTally tally, ItemOrder order, ItemText Function(int) placeholderOf) {
    final ids = order.sort(tally.holders.keys.where(tally.isPartial), (id) => id);
    return DifferencePlaceholders._(
      tally,
      order,
      List.unmodifiable(ids),
      List.unmodifiable([for (final id in ids) CellItem(placeholderOf(id), ItemState.partialMissing)]),
    );
  }

  /// Whether [other] has the same placeholders in an order that ranks every id alike, so that the same own items
  /// make the same cell against either.
  bool _equals(DifferencePlaceholders other) {
    if (identical(this, other)) {
      return true;
    }
    return _compared[other] ??= other._compared[this] =
        const ListEquality<int>().equals(_ids, other._ids) &&
        const ListEquality<CellItem>().equals(_items, other._items) &&
        order._ranksAlike(other.order);
  }
}

/// The items of a difference-display cell: the record's own items merged with the column's [DifferencePlaceholders]
/// the record does not hold, in their order. Each read walks the two sorted lists; no item is copied per row.
class _DifferenceItems extends ListBase<CellItem> {
  _DifferenceItems._(this._own, this._placeholders, this._length);

  factory _DifferenceItems(List<OwnItem> own, DifferencePlaceholders placeholders, {required bool hideCommon}) {
    final tally = placeholders.tally;
    final shown = [
      for (final item in placeholders.order.sort(own, (e) => e.id))
        if (!(hideCommon && tally.isCommon(item.id)))
          (
            item.id,
            CellItem(
              item.text,
              tally.isCommon(item.id) ? ItemState.common : ItemState.partialHeld,
              strength: item.strength,
              strengthMax: tally.maxStrengthOf(item.id),
            ),
          ),
    ];
    final heldPlaceholders = {
      for (final (id, _) in shown)
        if (tally.isPartial(id)) id,
    };
    return _DifferenceItems._(shown, placeholders, shown.length + placeholders._ids.length - heldPlaceholders.length);
  }

  /// The record's own items in the placeholders' order, each with its id, the common ones left out when hidden.
  final List<(int, CellItem)> _own;
  final DifferencePlaceholders _placeholders;
  final int _length;

  /// Every item, made on the first read by index; drawing and measuring read the items in order instead.
  late final List<CellItem> _all = List.unmodifiable(_merged());

  @override
  int get length => _length;

  @override
  set length(int newLength) => throw UnsupportedError('Cannot change the length of an unmodifiable list');

  @override
  CellItem operator [](int index) => _all[index];

  @override
  void operator []=(int index, CellItem value) => throw UnsupportedError('Cannot modify an unmodifiable list');

  @override
  Iterator<CellItem> get iterator => _merged().iterator;

  @override
  CellItem get first => _merged().first;

  bool _equalsByParts(_DifferenceItems other) =>
      _placeholders._equals(other._placeholders) && const ListEquality<(int, CellItem)>().equals(_own, other._own);

  /// A placeholder is skipped where the record holds its id: the order ranks no two ids alike, so the id is the one
  /// it compares equal to.
  Iterable<CellItem> _merged() sync* {
    final order = _placeholders.order;
    final ids = _placeholders._ids;
    final placeholders = _placeholders._items;
    var next = 0;
    for (final (id, item) in _own) {
      for (; next < ids.length; next++) {
        final c = order.compare(ids[next], id);
        if (c > 0) {
          break;
        }
        if (c < 0) {
          yield placeholders[next];
        }
      }
      yield item;
    }
    for (; next < ids.length; next++) {
      yield placeholders[next];
    }
  }
}

/// The order of the items in a skill or factor cell, held and placeholder alike: position in the query first,
/// then position in the master (its `sortKey` order), then id. An id in neither sorts after every ranked one, by
/// id, so an item a lagging master does not list still has a fixed place.
///
/// The order within the record is not a key: an enhancement can append a factor to a record, so it is not stable.
@immutable
class ItemOrder {
  final Map<int, int> _queryRank;
  final Map<int, int> masterRank;

  ItemOrder({required Iterable<int> query, required this.masterRank})
    : _queryRank = {for (final (i, id) in query.indexed) id: i};

  int compare(int a, int b) {
    final byQuery = _compareRank(_queryRank[a], _queryRank[b]);
    if (byQuery != 0) {
      return byQuery;
    }
    final byMaster = _compareRank(masterRank[a], masterRank[b]);
    return byMaster != 0 ? byMaster : a.compareTo(b);
  }

  /// Whether [other] ranks every id as this one does.
  bool _ranksAlike(ItemOrder other) =>
      identical(this, other) ||
      (const MapEquality<int, int>().equals(_queryRank, other._queryRank) &&
          const MapEquality<int, int>().equals(masterRank, other.masterRank));

  /// [items] sorted by the id [idOf] gives each, stably.
  List<T> sort<T>(Iterable<T> items, int Function(T) idOf) {
    final sorted = items.toList();
    mergeSort(sorted, compare: (T a, T b) => compare(idOf(a), idOf(b)));
    return sorted;
  }

  static int _compareRank(int? a, int? b) {
    if (a == null || b == null) {
      return a == null ? (b == null ? 0 : 1) : -1;
    }
    return a.compareTo(b);
  }
}

/// Items of a cell that marks missing items: the record's own items and a [ItemState.missing] placeholder for each
/// queried item it lacks, together in [order]. [placeholderOf] gives a placeholder's text.
///
/// An own item is [ItemState.met] or [ItemState.short] by its [OwnItem.meetsQuery], and [ItemState.normal] where
/// nothing judges it.
List<CellItem> missingMarkedItems(
  List<OwnItem> own,
  Iterable<int> query,
  ItemText Function(int) placeholderOf,
  ItemOrder order,
) {
  final ownIds = {for (final item in own) item.id};
  final items = [
    for (final item in own)
      (
        item.id,
        CellItem(item.text, switch (item.meetsQuery) {
          null => ItemState.normal,
          true => ItemState.met,
          false => ItemState.short,
        }),
      ),
    for (final id in query)
      if (!ownIds.contains(id)) (id, CellItem(placeholderOf(id), ItemState.missing)),
  ];
  return [for (final (_, item) in order.sort(items, (e) => e.$1)) item];
}
