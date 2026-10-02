import 'package:dart_mappable/dart_mappable.dart';
import 'package:trina_grid/trina_grid.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/item_cell.dart';
import '/src/chara_detail/spec/item_cell_text.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/core/utils.dart';

part 'item_display.mapper.dart';

/// What a root skill or factor column does with a row that does not meet its query.
@MappableEnum()
enum UnmetRows {
  /// The row is filtered out (not listed).
  filterOut,

  /// The row is kept, and the queried items it lacks or holds short are marked red.
  markMissing,
}

/// Capability of a column whose cell lists items (skills, factors). Reached from the grid build through an
/// `is ItemColumnSpec` test, like [ContainerColumnSpec]. How the items are compared is the business of
/// [QueryItemColumnSpec] (against the column's query) or [DifferenceItemColumnSpec] (row against row).
mixin ItemColumnSpec<T> on ColumnSpec<T> {
  /// The items [value] holds within the column's comparison scope (the query, and for factors the subject), as
  /// item id to strength (for a factor the star sum, for a skill 1). A row's contribution to an [ItemTally], and the
  /// strength a difference cell shades the row's own items by.
  Map<int, int> heldItemStrengths(RefBase ref, T value);

  @override
  bool get takesItemColumnBounds => true;

  /// Measures the item boxes drawn, placeholders included, with the omission counter box the renderer adds when
  /// the items do not all fit the height the measurement is given (the table's cell height cap). A value-only
  /// summary is measured as the cell value, not as the summary text drawn.
  ///
  /// A cut for want of lines happens in the wrap row-height mode, which does not measure.
  @override
  MeasuredContent measuredContent(TrinaCell? cell, String formatted) {
    final data = cell?.getUserData<ItemCellData>();
    return data == null || data.summary != null ? super.measuredContent(cell, formatted) : ItemMeasuredContent(data);
  }

  /// [lines] rows of item boxes, so a fixed row height shows the minimum lines as whole rows of boxes; [lines]
  /// lines of text for a [cell] that draws the summary text. Read from the cell, which records what it draws.
  /// Without a cell, rows of boxes.
  @override
  double minContentHeight(int lines, CellMeasurement m, {TrinaCell? cell}) =>
      cell?.getUserData<ItemCellData>()?.summary != null
      ? super.minContentHeight(lines, m, cell: cell)
      : itemBoxesMinHeight(lines, m);
}

/// Capability of an item column that compares a row's items against the column's query. What it does with a row
/// that does not meet the query is its [unmetRows]: filter it out, or keep it and mark the missing items red.
mixin QueryItemColumnSpec<T> on ItemColumnSpec<T> {
  UnmetRows get unmetRows;

  /// Whether [UnmetRows.markMissing] is offered. A column whose items come from tags lists too many items to mark.
  bool get offersMarkMissing;

  QueryItemColumnSpec<T> withUnmetRows(UnmetRows value);

  /// Whether the cell marks the queried items a row lacks or holds short, instead of filtering the row out.
  bool get marksMissing => unmetRows == UnmetRows.markMissing;

  @override
  bool get filtersRows => !marksMissing;

  /// Whether the column's notation is a single value-only aggregate (a count, a summed metric) rather than the
  /// items named. The cell value and the CSV follow it either way.
  bool get notatesValueOnly;

  /// Whether the cell shows its value-only summary as text rather than item boxes: only while filtering, since a
  /// red mark belongs to an item.
  bool get drawsSummary => notatesValueOnly && !marksMissing;
}

/// Capability of an item column that compares the displayed rows against each other rather than against a query:
/// each cell marks the items only some displayed rows hold. It does not filter rows ([filtersRows] is false),
/// so it has no pass count and no container accepts it as a child.
mixin DifferenceItemColumnSpec<T> on ItemColumnSpec<T> {
  /// Whether common items ([ItemTally.common]: every compared row holds them with the same strength) are left out
  /// of the cell.
  bool get hideCommonItems;

  DifferenceItemColumnSpec<T> withHideCommonItems(bool hide);

  @override
  bool get filtersRows => false;

  /// Every row passes: the column lists every row it is given and hides none.
  @override
  List<bool> evaluate(RefBase ref, List<T> values) => List<bool>.filled(values.length, true);

  /// The cell of [value] compared against [tally], the item holdings of every displayed row.
  TrinaCell differenceCell(RefBase ref, T value, ItemTally tally);

  /// Outside the grid build there is no group to compare against, so the cell is drawn against the row alone.
  @override
  TrinaCell plutoCell(RefBase ref, T value) =>
      differenceCell(ref, value, ItemTally.of([heldItemStrengths(ref, value)]));
}

/// Whether the column [specId] is a root of the column forest, as opposed to one nested under a container.
bool isRootColumn(RefBase ref, String specId) => ref.read(currentColumnSpecsProvider).any((s) => s.id == specId);
