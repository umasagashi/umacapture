import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' hide mergeSort;

import '/src/chara_detail/spec/base.dart';

/// How one item of a skill or factor cell is painted.
enum ItemState {
  /// The record has the item (outline background). Normal display.
  normal,

  /// The record has the item and meets the query (no highlight). Absence display.
  held,

  /// The record lacks a queried item (red placeholder). Absence display.
  missing,

  /// The record has a queried item but below the per-item threshold (red). Absence display, factors only.
  short,

  /// Every record of the group has the item (no highlight, may be hidden). Difference display.
  common,

  /// Some records of the group have the item, this one included (green, shaded by strength). Difference display.
  partialHeld,

  /// Some records of the group have the item, this one not (red placeholder). Difference display.
  partialMissing,
}

/// One item drawn in a cell, compared by value.
@immutable
class CellItem {
  /// The text drawn: the name, or the name with its notation (e.g. `name(3)`).
  final String text;
  final ItemState state;

  /// Input to the [ItemState.partialHeld] shade; 0 for every other state.
  final int strength;

  /// Upper bound of [strength]; 0 for every other state.
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
  final String text;

  /// Whether the item passes the per-item threshold of the query (always true where there is none).
  final bool meetsQuery;

  /// Strength within the comparison scope (the star sum for a factor).
  final int strength;

  const OwnItem(this.id, this.text, {this.meetsQuery = true, this.strength = 0});
}

/// How many rows of a group hold each item of one column.
@immutable
class ItemTally {
  final int rowCount;

  /// Item id to the number of rows holding it, in the order the ids were first seen.
  final Map<int, int> holders;

  const ItemTally._(this.rowCount, this.holders);

  factory ItemTally.of(Iterable<Set<int>> heldPerRow) {
    var rowCount = 0;
    final holders = <int, int>{};
    for (final held in heldPerRow) {
      rowCount++;
      for (final id in held) {
        holders[id] = (holders[id] ?? 0) + 1;
      }
    }
    return ItemTally._(rowCount, Map.unmodifiable(holders));
  }

  int holdersOf(int id) => holders[id] ?? 0;
}

/// Cell data of a skill or factor column: the items to draw, each with its state.
///
/// Compared by value, and that value is its [paintState], so a change of state alone replaces the row.
@immutable
class ItemCellData implements RenderedCellData {
  /// Items in drawing order, with hiding and truncation already applied.
  final List<CellItem> items;

  /// The number of items the cell would list were it not cut to the display count: [items] and every item the
  /// cut dropped, but no item [ItemCellData.limited] hid as common. Equal to the length of [items] when nothing
  /// was cut; the renderer shows the omission counter against it.
  final int total;

  /// A value-only notation (e.g. a count). When non-null, [items] is empty.
  final String? summary;

  @override
  final String csv;

  ItemCellData({required List<CellItem> items, int? total, this.summary, required this.csv})
    : items = List.unmodifiable(items),
      total = total ?? items.length,
      assert(summary == null || items.isEmpty),
      assert(total == null || total >= items.length);

  /// Applies the column's display count to [items]: drops [ItemState.common] items first when [hideCommon], then
  /// keeps the first [max] of what remains in order, or all of it when [max] is null (see
  /// [ItemColumnSpec.hasQuerySelection]). No state is exempt from the cut, placeholders included. [total] is what
  /// remains after hiding, so a hidden common item is never counted as omitted.
  factory ItemCellData.limited(List<CellItem> items, int? max, {required bool hideCommon, required String csv}) {
    final shown = hideCommon ? items.where((e) => e.state != ItemState.common).toList() : items;
    return ItemCellData(
      items: max == null ? shown : shown.take(max < 0 ? 0 : max).toList(),
      total: shown.length,
      csv: csv,
    );
  }

  @override
  Object get paintState => this;

  @override
  CellSelectedCallback? get onSelected => null;

  static const _itemsEquality = ListEquality<CellItem>();

  @override
  bool operator ==(Object other) =>
      other is ItemCellData &&
      other.summary == summary &&
      other.csv == csv &&
      other.total == total &&
      _itemsEquality.equals(other.items, items);

  @override
  int get hashCode => Object.hash(summary, csv, total, _itemsEquality.hash(items));
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

/// Items of an absence-display cell: the record's own items and a [ItemState.missing] placeholder for each
/// queried item it lacks, together in [order]. [placeholderOf] gives a placeholder's text.
///
/// With [perItemThreshold], an own item that fails its threshold is [ItemState.short].
List<CellItem> absenceItems(
  List<OwnItem> own,
  Iterable<int> query,
  String Function(int) placeholderOf,
  ItemOrder order, {
  required bool perItemThreshold,
}) {
  final ownIds = {for (final item in own) item.id};
  final items = [
    for (final item in own)
      (item.id, CellItem(item.text, perItemThreshold && !item.meetsQuery ? ItemState.short : ItemState.held)),
    for (final id in query)
      if (!ownIds.contains(id)) (id, CellItem(placeholderOf(id), ItemState.missing)),
  ];
  return [for (final (_, item) in order.sort(items, (e) => e.$1)) item];
}

/// Items of a difference-display cell against the group's [tally]: the record's own items as
/// [ItemState.common] or [ItemState.partialHeld] and a [ItemState.partialMissing] placeholder for each item some
/// but not all rows of the group hold, together in [order], so a row's cell does not depend on the row order.
/// [placeholderOf] gives a placeholder's text.
List<CellItem> differenceItems(
  List<OwnItem> own,
  ItemTally tally,
  String Function(int) placeholderOf,
  ItemOrder order, {
  required int strengthMax,
}) {
  final ownIds = {for (final item in own) item.id};
  final items = [
    for (final item in own)
      if (tally.holdersOf(item.id) >= tally.rowCount)
        (item.id, CellItem(item.text, ItemState.common))
      else
        (item.id, CellItem(item.text, ItemState.partialHeld, strength: item.strength, strengthMax: strengthMax)),
    for (final id in tally.holders.keys)
      if (!ownIds.contains(id) && tally.holdersOf(id) < tally.rowCount)
        (id, CellItem(placeholderOf(id), ItemState.partialMissing)),
  ];
  return [for (final (_, item) in order.sort(items, (e) => e.$1)) item];
}
