import 'package:dart_mappable/dart_mappable.dart';
import 'package:trina_grid/trina_grid.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/item_cell.dart';
import '/src/chara_detail/spec/item_cell_text.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/core/utils.dart';

part 'item_display.mapper.dart';

/// How a column that lists items (skills, factors) presents its query.
///
/// [normal] filters rows by the query. [absence] and [difference] keep every
/// row and instead annotate the cells: [absence] marks the queried items a row
/// lacks, [difference] compares the displayed rows against each other. Only a
/// root column honours a non-normal mode; see [effectiveItemDisplayMode].
@MappableEnum()
enum ItemDisplayMode { normal, absence, difference }

/// Capability of a column whose cell lists items (skills, factors) and can be
/// shown in a display mode other than filtering. Reached from the grid build
/// through an `is ItemColumnSpec` test, like [ContainerColumnSpec].
mixin ItemColumnSpec<T> on ColumnSpec<T> {
  /// The stored display mode. Inert while the column is nested under a
  /// container; read [effectiveItemDisplayMode] for the mode that applies.
  ItemDisplayMode get displayMode;

  /// Whether items every compared row shares are left out of the cell. Only
  /// meaningful in [ItemDisplayMode.difference].
  bool get hideCommonItems;

  /// Whether [ItemDisplayMode.absence] is offered. A column whose items are
  /// resolved from tags lists too many items for a per-item absence mark.
  bool get offersAbsenceDisplay;

  /// Whether the column's query, once resolved (a tag-driven column included), selects any item. A selecting
  /// column draws every selected item it has in any display mode; only a column that selects nothing is cut to
  /// its display count ([itemLimit]).
  bool hasQuerySelection(RefBase ref);

  /// The number of items a cell keeps out of [max], the stored display count: null (every item) while the
  /// column [hasQuerySelection]. The cell, its sort value and its CSV all follow it.
  int? itemLimit(RefBase ref, int max) => hasQuerySelection(ref) ? null : max;

  /// Whether the column's notation is a single value-only aggregate (a count, a summed metric) rather than the
  /// items named. The cell value and the CSV follow it in every display mode.
  bool get notatesValueOnly;

  /// Whether a cell drawn in [mode] shows its value-only summary as text rather than item boxes: only a
  /// [notatesValueOnly] column in the normal display, since a highlight belongs to an item.
  bool drawsSummary(ItemDisplayMode mode) => notatesValueOnly && mode == ItemDisplayMode.normal;

  ColumnSpec withDisplayMode(ItemDisplayMode mode);

  ColumnSpec withHideCommonItems(bool hide);

  /// Ids of the items [value] holds within the column's comparison scope (the
  /// query, and for factors the subject). A row's contribution to an [ItemTally].
  Set<int> heldItemIds(RefBase ref, T value);

  /// The cell of [value] drawn in [context]. [ColumnSpec.plutoCell] is this in
  /// [ItemCellContext.normal]; the grid build calls it directly for a column
  /// that annotates its cells.
  TrinaCell itemCell(RefBase ref, T value, ItemCellContext context);

  /// Measures the item boxes drawn, placeholders included, with the omission
  /// counter box the renderer adds after a cell cut to its display count. A
  /// value-only summary is measured as the cell value, not as the summary text
  /// drawn.
  ///
  /// Only the display count is known here; a cut for want of lines happens in
  /// the wrap row-height mode, which does not measure.
  @override
  MeasuredContent measuredContent(TrinaCell? cell, String formatted) {
    final data = cell?.getUserData<ItemCellData>();
    return data == null || data.summary != null ? super.measuredContent(cell, formatted) : ItemMeasuredContent(data);
  }

  /// [lines] rows of item boxes, so a fixed row height shows the minimum lines as whole rows of boxes; [lines]
  /// lines of text for a [cell] that draws the summary text ([drawsSummary]). Read from the cell, not from the
  /// stored [displayMode]: a column nested under a container draws its cells in the normal display whatever mode
  /// it stores ([effectiveItemDisplayMode]), and the grid build, which knows where the column sits in the column
  /// forest, records in the cell what it draws. Without a cell, rows of boxes.
  @override
  double minContentHeight(int lines, CellMeasurement m, {TrinaCell? cell}) =>
      cell?.getUserData<ItemCellData>()?.summary != null
      ? super.minContentHeight(lines, m, cell: cell)
      : itemBoxesMinHeight(lines, m);
}

/// What an item cell is drawn against.
sealed class ItemCellContext {
  const ItemCellContext();

  /// The display mode the cell is drawn in.
  ItemDisplayMode get mode;

  const factory ItemCellContext.normal() = NormalItemCellContext;

  const factory ItemCellContext.absence() = AbsenceItemCellContext;

  const factory ItemCellContext.difference(ItemTally tally) = DifferenceItemCellContext;
}

/// Plain filtering display: the record's items, no highlight.
class NormalItemCellContext extends ItemCellContext {
  const NormalItemCellContext();

  @override
  ItemDisplayMode get mode => ItemDisplayMode.normal;
}

/// Absence display: the queried items the record lacks are marked.
class AbsenceItemCellContext extends ItemCellContext {
  const AbsenceItemCellContext();

  @override
  ItemDisplayMode get mode => ItemDisplayMode.absence;
}

/// Difference display against [tally], the item holdings of the row's group.
class DifferenceItemCellContext extends ItemCellContext {
  final ItemTally tally;

  const DifferenceItemCellContext(this.tally);

  @override
  ItemDisplayMode get mode => ItemDisplayMode.difference;
}

/// Whether the column [specId] is a root of the column forest, as opposed to one
/// nested under a container. Only a root column honours a non-normal display mode.
bool isRootColumn(RefBase ref, String specId) => ref.read(currentColumnSpecsProvider).any((s) => s.id == specId);

/// The display mode that actually applies: the stored [mode] for a root column,
/// normal for a column nested under a container (its stored mode is kept but inert).
ItemDisplayMode effectiveItemDisplayMode(RefBase ref, String specId, ItemDisplayMode mode) =>
    isRootColumn(ref, specId) ? mode : ItemDisplayMode.normal;
