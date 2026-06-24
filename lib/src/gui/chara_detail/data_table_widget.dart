import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';
import 'package:trina_grid/trina_grid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/chara_detail/archive_record_dialog.dart';
import '/src/gui/chara_detail/column_preset_bar_widget.dart';
import '/src/gui/chara_detail/column_spec_tag_widget.dart';
import '/src/gui/chara_detail/delete_record_dialog.dart';
import '/src/gui/chara_detail/export_button.dart';
import '/src/gui/chara_detail/preview_dialog.dart';
import '/src/gui/chara_detail/regenerate_record_dialog.dart';
import '/src/gui/chara_detail/report_record_dialog.dart';
import '/src/gui/common.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_chara_detail = "pages.chara_detail";

final charaDetailInitialDataLoader = FutureProvider((ref) async {
  return Future.wait([ref.watch(pathInfoLoader.future)]).then((_) {
    return Future.wait([ref.watch(moduleInfoLoaders.future), ref.watch(charaDetailRecordStorageLoaderProvider.future)]);
  });
});

class _CharaDetailDataTableWidget extends ConsumerStatefulWidget {
  const _CharaDetailDataTableWidget();

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _CharaDetailDataTableWidgetState();
}

class _CharaDetailDataTableWidgetState extends ConsumerState<_CharaDetailDataTableWidget> {
  String? sortColumn;
  TrinaColumnSort sortOrder = TrinaColumnSort.none;
  late TrinaGridStateManager stateManager;

  // The grid widget is kept alive across rebuilds (stable key); all data changes
  // are pushed into the live stateManager imperatively via [_reconcile] instead
  // of recreating the grid. TrinaGrid reads columns/rows only at init time
  // (didUpdateWidget ignores them), so a fresh build's args would otherwise be
  // dropped.
  bool _loaded = false;

  // The grid contents last pushed into stateManager. Used to detect whether the
  // column set changed (and thus needs a structural replace) on the next update.
  Grid? _appliedGrid;

  // A grid update that arrived before onLoaded captured the stateManager. Applied
  // once the grid is ready.
  Grid? _pending;

  // The current theme and selection purpose, mirrored here so the long-lived
  // rowColorCallback/rowWrapper closures (captured once at grid init) read fresh
  // values through `this` instead of stale locals captured at first build.
  late ThemeData _theme;
  SelectionPurpose? _purpose;

  void showPopup(BuildContext context, WidgetRef ref, Offset offset, CharaDetailRecord record, int initialPage) {
    final theme = Theme.of(context);
    final source = ref.read(recordSourceProvider);
    final pathInfo = ref.read(pathInfoProvider);
    // While selecting rows (to archive or export), actions that rebuild the
    // table (and would drop the in-progress selection) are disabled.
    final selecting = ref.read(selectionModeProvider) != null;
    final isPinned = ref.read(pinnedRecordIdsProvider).contains(record.id);
    DirectoryPath dirOf(CharaDetailRecord r) => recordDirOf(pathInfo, source, r);
    final rect = offset & const Size(1, 1);
    const height = 40.0;
    final style = theme.textTheme.labelMedium;
    // The per-item Text overrides PopupMenuItem's built-in disabled coloring, so
    // grey the label ourselves for items disabled during selection.
    final disabledStyle = style?.copyWith(color: theme.disabledColor);
    showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(rect.left, rect.top, rect.right, rect.bottom),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: theme.colorScheme.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      items: [
        PopupMenuItem(
          height: height,
          onTap: () {
            final records = stateManager.getSortedRecords().toList();
            final index = records.indexOf(record);
            final directories = records.map(dirOf).toList();
            return CharaDetailPreviewDialog.show(ref.base, directories, index);
          },
          child: Text("$tr_chara_detail.context_menu.preview".tr(), style: style),
        ),
        PopupMenuItem(
          height: height,
          onTap: () => copyRecordImageToClipboard(ref.base, dirOf(record), CharaDetailRecordImageMode.skillPlain),
          child: Text("$tr_chara_detail.context_menu.copy_skill".tr(), style: style),
        ),
        PopupMenuItem(
          height: height,
          onTap: () => copyRecordImageToClipboard(ref.base, dirOf(record), CharaDetailRecordImageMode.factorPlain),
          child: Text("$tr_chara_detail.context_menu.copy_factor".tr(), style: style),
        ),
        PopupMenuItem(
          height: height,
          onTap: () => dirOf(record).launch(),
          child: Text("$tr_chara_detail.context_menu.open_in_explorer".tr(), style: style),
        ),
        // Pin/unpin the row to the top of the table. Disabled while selecting,
        // since toggling rebuilds the grid and would drop the in-progress
        // checkbox selection.
        PopupMenuItem(
          height: height,
          enabled: !selecting,
          onTap: () {
            final next = {...ref.read(pinnedRecordIdsProvider)};
            isPinned ? next.remove(record.id) : next.add(record.id);
            ref.read(pinnedRecordIdsProvider.notifier).set(next);
          },
          child: Text(
            "$tr_chara_detail.context_menu.${isPinned ? "unpin" : "pin_to_top"}".tr(),
            style: selecting ? disabledStyle : style,
          ),
        ),
        // Re-recognition only applies to active records; archived ones have lossy
        // or no images and are intentionally excluded.
        if (source == RecordSource.active)
          PopupMenuItem(
            height: height,
            enabled: !selecting,
            onTap: () async {
              final moduleVersion = await ref.read(moduleVersionLoader.future);
              if (moduleVersion == null) {
                sendModuleVersionCheckToast(ToastType.error, ModuleVersionCheckResultCode.noVersionAvailable);
                return;
              }
              if (!record.isSupported(moduleVersion)) {
                RegenerateRecordDialog.show(ref.base, recordId: record.id);
                return;
              }
              ref.read(charaDetailRecordRegenerationControllerProvider.notifier).start([record]);
            },
            child: Text(
              "$tr_chara_detail.context_menu.regenerate_record".tr(),
              style: selecting ? disabledStyle : style,
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          height: height,
          enabled: !selecting,
          onTap: () => DeleteRecordDialog.show(ref.base, recordId: record.id, source: source),
          child: Text("$tr_chara_detail.context_menu.delete_record".tr(), style: selecting ? disabledStyle : style),
        ),
        // Reports attach the recognition images for a bug repro; archived records
        // only keep lossy/no images, so the report is diagnostically useless there.
        // Active-only, like regenerate above.
        if (source == RecordSource.active && isSentryAvailable())
          PopupMenuItem(
            height: height,
            onTap: () => ReportRecordDialog.show(ref.base, dirOf(record)),
            child: Text("$tr_chara_detail.context_menu.report_record".tr(), style: style),
          ),
      ],
    );
  }

  /// Whether two column lists describe the same columns in the same order.
  ///
  /// Compared by field id (not object identity): the provider hands back fresh
  /// TrinaColumn objects on every rebuild, so identity would always differ.
  bool _sameColumns(List<TrinaColumn> a, List<TrinaColumn> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i].field != b[i].field) {
        return false;
      }
    }
    return true;
  }

  /// Pushes a freshly built [Grid] into the live grid instead of recreating it.
  ///
  /// When the column set/order changed (preset/column edits, entering or leaving
  /// selection mode), the columns are structurally replaced and the rows rebuilt
  /// wholesale. Otherwise columns keep their width and sort indicator — only
  /// their renderers are refreshed (for columns whose renderer captured provider
  /// data, e.g. ratings) — and the rows are diffed by record id so an unchanged
  /// row keeps its identity, preserving the scroll offset across a cell edit.
  void _reconcile(Grid next) {
    if (!_loaded) {
      _pending = next;
      return;
    }
    // Remember the highlighted row's record so the selection survives the update.
    // The row diff keeps an unchanged row's identity on its own, but a structural
    // column change rebuilds every row and clears the current cell.
    final selectedRecord = stateManager.currentRecord;
    final columnsChanged = _appliedGrid == null || !_sameColumns(_appliedGrid!.columns, next.columns);
    if (columnsChanged) {
      // Clear rows first so the column replace operates on an empty row set (no
      // wasted per-row cell fill/remove, no transient cell/column mismatch).
      stateManager.removeAllRows(notify: false);
      stateManager.removeColumns(stateManager.columns.toList());
      stateManager.insertColumns(0, next.columns);
      stateManager.appendRows(next.rows);
      // appendRows overwrites the canonical sortIdx; restore it so a later "reset
      // sort" reproduces the default (-capturedDate) order.
      stateManager.restoreCanonicalSortIdx(next.rows);
      if (sortColumn != null) {
        stateManager.sortColumnByField(sortColumn!, sortOrder);
      }
      // autoFitColumns measures via gridKey.currentContext, which needs the new
      // columns laid out first, so defer it one frame. Guard on _loaded too: the
      // grid may have left the tree (empty columns) before the frame, disposing
      // its stateManager.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _loaded) {
          stateManager.autoFitColumns();
        }
      });
    } else {
      stateManager.refreshColumnRenderers(next.columns);
      // _reconcile notifies once at the end (after restoreCurrentRecord), so the
      // row diff and the restored selection land in a single repaint.
      stateManager.reconcileRows(next.rows, sortColumn: sortColumn, sortOrder: sortOrder, notify: false);
    }
    // Re-highlight the same record (skips the checkbox cell so the highlight
    // lands on a data cell). No-op when it is still current or now filtered out.
    stateManager.restoreCurrentRecord(selectedRecord, ignoreField: checkColumnField);
    _appliedGrid = next;
    stateManager.notifyListeners();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grid = ref.watch(currentGridProvider);
    // Drives the per-row overlay's color/label so a checked row reads as either
    // "archive" or "export". Non-null whenever the checkbox column is present.
    final purpose = ref.watch(selectionModeProvider);
    // Mirror the latest theme/purpose so the grid's long-lived row callbacks read
    // current values. A theme change won't touch currentGridProvider, so nudge the
    // live grid to repaint the rows with the new colors.
    final themeChanged = _loaded && _theme != theme;
    _theme = theme;
    _purpose = purpose;
    if (themeChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Skip when the grid has since left the tree (empty columns): its
        // stateManager is then disposed and notifyListeners would throw.
        if (mounted && _loaded) {
          stateManager.notifyListeners();
        }
      });
    }
    // Apply subsequent grid changes to the live stateManager rather than letting
    // the watch above rebuild a fresh grid (TrinaGrid ignores changed columns/rows
    // after init). The watch stays only to seed the initial grid and the empty
    // checks below.
    ref.listen(currentGridProvider, (_, next) => _reconcile(next));
    if (grid.columns.isEmpty) {
      // The grid leaves the tree here, disposing its stateManager. Mark it
      // unloaded so a grid update (via the listen above) or theme repaint won't
      // touch the dead manager; onLoaded re-initializes it when columns return.
      _loaded = false;
      return Container();
    }
    return Expanded(
      child: Stack(
        alignment: Alignment.center,
        children: [
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              // Back the grid with a solid surface so gridBackgroundColor can be
              // transparent. That transparency is what keeps the selected row's
              // current cell highlighted when the grid loses focus: TrinaGrid
              // repaints the unfocused current cell with gridBackgroundColor
              // (trina_base_cell.dart), which would otherwise punch a hole in the
              // row highlight. Transparent lets the row color show through instead.
              return ColoredBox(
                color: theme.colorScheme.surface,
                child: TrinaGrid(
                  // Stable key keeps one grid (and its stateManager) alive across
                  // rebuilds. Data changes are pushed in imperatively via
                  // [_reconcile]; the columns/rows below only seed the initial grid.
                  key: const ValueKey("chara_detail_grid"),
                  columns: grid.columns,
                  rows: grid.rows,
                  mode: TrinaGridMode.select,
                  // Paint the selected row ourselves so the highlight stays
                  // visible even when the grid loses focus (e.g. the app is
                  // deactivated). TrinaGrid's built-in activatedColor is gated on
                  // hasFocus, so it disappears otherwise. Setting rowColorCallback
                  // overrides the default striping, so reproduce it for other rows.
                  rowColorCallback: (rowContext) {
                    final theme = _theme;
                    // Detect the highlighted row by record id, not row index. With
                    // pinned (frozen) rows present, currentRowIdx is an index into
                    // the full refRows while rowContext.rowIdx is a display index
                    // (frozen rows render in a separate block), so an index compare
                    // would highlight the wrong row.
                    final currentId = rowContext.stateManager.currentRecord?.id;
                    final rowId = rowContext.row.getUserData<CharaDetailRecord>()?.id;
                    if (currentId != null && rowId == currentId) {
                      return theme.colorScheme.primaryContainer;
                    }
                    return rowContext.rowIdx.isEven ? theme.colorScheme.surface : theme.colorScheme.stripedRowColor;
                  },
                  // Checked rows get a translucent amber overlay that dims the
                  // cells and is labeled "archive", so the destructive (lossy,
                  // irreversible) intent of the bulk selection is unmistakable.
                  rowWrapper: (context, rowWidget, rowData, stateManager) {
                    final theme = _theme;
                    final purpose = _purpose;
                    Widget row = rowWidget;
                    if (rowData.checked == true && purpose != null) {
                      row = _SelectionRowOverlay(purpose: purpose, child: row);
                    }
                    // Frozen (pinned) rows bypass rowColorCallback and the normal
                    // row border, so reproduce both here: the same alternating
                    // stripe (and current-row highlight) as rowColorCallback above,
                    // a normal-weight separator between pinned rows, and a single
                    // thick rule only at the boundary with the scrollable rows.
                    if (rowData.frozen == TrinaRowFrozen.start) {
                      final pinned = stateManager.refRows.originalList
                          .where((r) => r.frozen == TrinaRowFrozen.start)
                          .toList();
                      final pinnedIdx = pinned.indexOf(rowData);
                      if (pinnedIdx >= 0) {
                        final isLast = pinnedIdx == pinned.length - 1;
                        // Match the highlighted row by record id (see rowColorCallback):
                        // currentRowIdx and pinnedIdx live in different index spaces.
                        final currentId = stateManager.currentRecord?.id;
                        final isCurrent =
                            currentId != null && rowData.getUserData<CharaDetailRecord>()?.id == currentId;
                        final Color background = isCurrent
                            ? theme.colorScheme.primaryContainer
                            : (pinnedIdx.isEven ? theme.colorScheme.surface : theme.colorScheme.stripedRowColor);
                        final separator = isLast
                            ? BorderSide(color: theme.colorScheme.primary, width: 3)
                            : BorderSide(
                                color: theme.focusColor,
                                width: stateManager.configuration.style.cellHorizontalBorderWidth,
                              );
                        row = DecoratedBox(
                          decoration: BoxDecoration(color: background),
                          child: DecoratedBox(
                            position: DecorationPosition.foreground,
                            decoration: BoxDecoration(border: Border(bottom: separator)),
                            child: row,
                          ),
                        );
                      }
                    }
                    return row;
                  },
                  configuration: TrinaGridConfiguration(
                    enterKeyAction: TrinaGridEnterKeyAction.toggleEditing,
                    // Never auto-select the first row. In select mode TrinaGrid
                    // otherwise highlights row 0 on (re)mount whenever no cell is
                    // current, which would override the user's row selection and
                    // make it appear to jump to the top.
                    enableAutoSelectFirstRow: false,
                    scrollbar: const TrinaGridScrollbarConfig(isAlwaysShown: true, radius: 8, thickness: 12),
                    style: TrinaGridStyleConfig(
                      enableCellBorderVertical: false,
                      gridBackgroundColor: Colors.transparent,
                      // Not the per-row striping (rowColorCallback overrides that),
                      // but the body background painted behind/around the rows,
                      // e.g. the empty space right of the last column. Without it
                      // this falls back to TrinaGrid's default Colors.white.
                      rowColor: theme.colorScheme.surface,
                      // Keep the checked-row background neutral; the amber cue is
                      // drawn as an overlay via rowWrapper instead (see below).
                      rowCheckedColor: Colors.transparent,
                      activatedColor: theme.colorScheme.primaryContainer,
                      // TrinaGrid paints frozen (pinned) rows from these and
                      // bypasses rowColorCallback for them, so its single
                      // frozenRowColor can't reproduce the normal alternating
                      // stripe. Make both transparent and paint the stripe + the
                      // row separators ourselves in rowWrapper instead, so pinned
                      // rows match normal rows except for the block boundary.
                      frozenRowColor: Colors.transparent,
                      frozenRowBorderColor: Colors.transparent,
                      gridBorderColor: theme.colorScheme.outline,
                      borderColor: theme.focusColor,
                      activatedBorderColor: theme.focusColor,
                      inactivatedBorderColor: theme.focusColor,
                      columnTextStyle: theme.textTheme.titleSmall!,
                      cellTextStyle: theme.textTheme.bodyMedium!,
                    ),
                  ),
                  onLoaded: (TrinaGridOnLoadedEvent event) {
                    stateManager = event.stateManager;
                    _loaded = true;
                    _appliedGrid = grid;
                    event.stateManager.autoFitColumns();
                    if (sortColumn != null) {
                      event.stateManager.sortColumnByField(sortColumn!, sortOrder);
                    }
                    // A grid change may have arrived before the stateManager was
                    // ready; apply the latest one now.
                    if (_pending != null) {
                      final pending = _pending!;
                      _pending = null;
                      _reconcile(pending);
                    }
                  },
                  onRowSecondaryTap: (TrinaGridOnRowSecondaryTapEvent event) {
                    // event.row (== getRowByIdx(rowIdx)) is unreliable once any
                    // row is frozen (pinned): TrinaGrid renders frozen rows in a
                    // separate block with positional indices that don't map back
                    // through refRows, so it would return a different record.
                    // The tapped cell's own row is always correct.
                    final record = event.cell.row.getUserData<CharaDetailRecord>()!;
                    final spec = event.cell.column.getUserData<ColumnSpec>();
                    showPopup(context, ref, event.offset, record, spec!.cellAction?.tabIdx ?? 0);
                  },
                  onRowChecked: (TrinaGridOnRowCheckedEvent event) {
                    // Recompute the whole checked set (covers single + select-all
                    // toggles) so the toolbar's archive action reads a live set.
                    final ids = stateManager.checkedRows
                        .map((row) => row.getUserData<CharaDetailRecord>()?.id)
                        .nonNulls
                        .toSet();
                    ref.read(selectedRecordIdsProvider.notifier).set(ids);
                    // The amber overlay is drawn by rowWrapper, which only re-runs
                    // when the row list repaints — not when a single checkbox cell
                    // updates itself. Nudge the grid to repaint its rows (this
                    // reuses the existing rows, so checked state is preserved).
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      // The page may be torn down before the next frame; skip the
                      // notify rather than poke a disposed stateManager.
                      if (!mounted) {
                        return;
                      }
                      stateManager.notifyListeners();
                    });
                  },
                  onSelected: (TrinaGridOnSelectedEvent event) {
                    try {
                      final data = event.cell?.getUserData<CellData>();
                      if (!(data?.onSelected?.call(event) ?? false)) {
                        final source = ref.read(recordSourceProvider);
                        final pathInfo = ref.read(pathInfoProvider);
                        // event.rowIdx is unreliable once any row is frozen
                        // (pinned): frozen rows render in a separate block and
                        // shift the scrollable rows' indices, so it no longer maps
                        // to getSortedRecords. Resolve the tapped record from its
                        // own cell row and find its position by identity instead.
                        final sorted = stateManager.getSortedRecords().toList();
                        final record = event.cell?.row.getUserData<CharaDetailRecord>();
                        final index = record == null ? -1 : sorted.indexOf(record);
                        if (index < 0) {
                          return;
                        }
                        final records = sorted.map((e) => recordDirOf(pathInfo, source, e)).toList();
                        CharaDetailPreviewDialog.show(ref.base, records, index);
                      }
                    } catch (error, stackTrace) {
                      logger.e(
                        "Failed to handle cell selected. row=${event.row}, cell=${event.cell}",
                        error,
                        stackTrace,
                      );
                      captureException(error, stackTrace);
                    }
                  },
                  onSorted: (TrinaGridOnSortedEvent event) {
                    if (event.column.sort == TrinaColumnSort.none) {
                      sortColumn = null;
                      sortOrder = TrinaColumnSort.none;
                    } else {
                      sortColumn = event.column.field;
                      sortOrder = event.column.sort;
                    }
                  },
                ),
              );
            },
          ),
          if (grid.rows.isEmpty) Text("$tr_chara_detail.no_row_message".tr()),
        ],
      ),
    );
  }
}

/// The shared per-purpose presentation: row-overlay color/icon/label and the
/// scrim confirm-button label. Centralized so the row overlay and the confirm
/// button cannot drift out of sync.
typedef _SelectionStyle = ({Color color, Color onColor, IconData icon, String rowLabelKey, String actionLabelKey});

extension _SelectionPurposeStyle on SelectionPurpose {
  _SelectionStyle style(ThemeData theme) => switch (this) {
    SelectionPurpose.archive => (
      color: Colors.amber,
      onColor: Colors.black87,
      icon: Symbols.archive_rounded,
      rowLabelKey: "$tr_chara_detail.archive_records.row_overlay",
      actionLabelKey: "$tr_chara_detail.archive_records.overlay.archive",
    ),
    SelectionPurpose.export => (
      color: theme.colorScheme.primary,
      onColor: theme.colorScheme.onPrimary,
      icon: Symbols.download_rounded,
      rowLabelKey: "$tr_chara_detail.export.row_overlay",
      actionLabelKey: "$tr_chara_detail.export.overlay.export",
    ),
    SelectionPurpose.delete => (
      color: theme.colorScheme.error,
      onColor: theme.colorScheme.onError,
      icon: Symbols.delete_rounded,
      rowLabelKey: "$tr_chara_detail.delete_record.row_overlay",
      actionLabelKey: "$tr_chara_detail.delete_record.overlay.delete",
    ),
  };
}

/// Translucent overlay drawn over a checked row to mark it for the pending bulk
/// action.
///
/// Dims the underlying cells and stamps a label so the action is obvious:
/// amber/"archive" for the (irreversible) archive flow, primary/"export" for the
/// export flow. [IgnorePointer] lets taps fall through to the checkbox beneath,
/// so the row can still be unchecked.
class _SelectionRowOverlay extends StatelessWidget {
  final SelectionPurpose purpose;
  final Widget child;

  const _SelectionRowOverlay({required this.purpose, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = purpose.style(theme);
    final color = style.color;
    final onColor = style.onColor;
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              color: color.withValues(alpha: 0.45),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              // A denser chip behind the label keeps it legible over the cell
              // content showing through the translucent row overlay.
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.95), borderRadius: BorderRadius.circular(6)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(style.icon, size: 16, color: onColor),
                    const SizedBox(width: 4),
                    Text(
                      style.rowLabelKey.tr(),
                      style: theme.textTheme.labelMedium?.copyWith(color: onColor, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The preset bar + column chips, with a hit-absorbing scrim overlaid while
/// bulk-archive selection is active.
///
/// During selection every top control (presets, source switch, column chips)
/// must be inert — changing any of them rebuilds the grid and would drop the
/// in-progress checkbox selection. The scrim blocks them and surfaces the only
/// two valid actions: archive the selection, or cancel.
class _TopControlsLayer extends ConsumerWidget {
  const _TopControlsLayer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final purpose = ref.watch(selectionModeProvider);
    final selectedCount = ref.watch(selectedRecordIdsProvider).length;
    return Stack(
      children: [
        const Column(mainAxisSize: MainAxisSize.min, children: [ColumnPresetBarWidget(), ColumnSpecTagWidget()]),
        if (purpose != null)
          Positioned.fill(
            child: Stack(
              children: [
                // Scrim absorbs taps so the controls underneath are inert.
                Positioned.fill(
                  child: AbsorbPointer(child: ColoredBox(color: theme.colorScheme.surface.withValues(alpha: 0.85))),
                ),
                // The two valid actions sit above the scrim and stay interactive.
                Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        // Purpose-neutral ("selecting N records; columns/presets
                        // are frozen"), so it is shared by both flows.
                        "$tr_chara_detail.archive_records.overlay.message".tr(namedArgs: {"count": "$selectedCount"}),
                        style: theme.textTheme.labelLarge,
                      ),
                      const SizedBox(width: 16),
                      _SelectionConfirmButton(purpose: purpose, selectedCount: selectedCount),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        icon: const Icon(Symbols.cancel_rounded, size: 20),
                        label: Text("$tr_chara_detail.archive_records.cancel.label".tr()),
                        onPressed: () => exitSelection(ref),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The scrim's primary action, which opens the purpose's confirmation dialog
/// ([ArchiveRecordDialog] or [ExportRecordDialog]) for the checked rows. Disabled
/// until at least one row is checked.
class _SelectionConfirmButton extends ConsumerWidget {
  final SelectionPurpose purpose;
  final int selectedCount;

  const _SelectionConfirmButton({required this.purpose, required this.selectedCount});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = purpose.style(Theme.of(context));
    return FilledButton.icon(
      icon: Icon(style.icon, size: 20),
      label: Text(style.actionLabelKey.tr()),
      onPressed: selectedCount == 0
          ? null
          : () {
              final recordIds = ref.read(selectedRecordIdsProvider).toList();
              switch (purpose) {
                case SelectionPurpose.archive:
                  ArchiveRecordDialog.show(ref.base, recordIds: recordIds);
                case SelectionPurpose.export:
                  ExportRecordDialog.show(ref.base, recordIds: recordIds);
                case SelectionPurpose.delete:
                  BulkDeleteRecordDialog.show(ref.base, recordIds: recordIds, source: ref.read(recordSourceProvider));
              }
            },
    );
  }
}

class _CharaDetailDataTablePreCheckLayer extends ConsumerWidget {
  const _CharaDetailDataTablePreCheckLayer();

  Widget progressWidget(BuildContext context, Progress progress, String messageKey) {
    final theme = Theme.of(context);
    final footer = Padding(padding: const EdgeInsets.only(top: 8), child: Text(messageKey.tr()));
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // A batch with no per-record callback (archive) can't advance a count;
          // show a spinning indicator instead of a determinate ring stuck at 0%.
          if (progress.indeterminate)
            Column(mainAxisSize: MainAxisSize.min, children: [const CircularProgressIndicator(), footer])
          else
            CircularPercentIndicator(
              radius: 32.0,
              lineWidth: 6.0,
              animation: true,
              animateFromLastPercent: true,
              animationDuration: 200,
              percent: progress.progress,
              center: Text("${progress.percent}%"),
              footer: footer,
              backgroundColor: theme.colorScheme.secondaryContainer,
              progressColor: theme.colorScheme.primary,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final regenerationProgress = ref.watch(charaDetailRecordRegenerationControllerProvider);
    if (!regenerationProgress.isEmpty) {
      return progressWidget(context, regenerationProgress, "$tr_chara_detail.regenerating_message");
    }
    final archiveProgress = ref.watch(charaArchiveControllerProvider);
    if (!archiveProgress.isEmpty) {
      return progressWidget(context, archiveProgress, "$tr_chara_detail.archive_records.progress_message");
    }
    if (ref.watch(displayedRecordsProvider).isEmpty) {
      return Expanded(child: ErrorMessageWidget(message: "$tr_chara_detail.no_record_message".tr()));
    }
    // Guard on visible columns, not raw spec count: hidden specs still filter rows
    // but render no column, so a preset whose specs are all hidden (e.g. only logic
    // filters, which default to hidden) would otherwise fall through to a grid with
    // zero columns and paint blank. grid.columns is exactly the visible set, so this
    // matches the empty-grid check in _CharaDetailDataTableWidget below.
    if (ref.watch(currentGridProvider).columns.isEmpty) {
      return Expanded(child: ErrorMessageWidget(message: "$tr_chara_detail.no_column_message".tr()));
    }
    return const _CharaDetailDataTableWidget();
  }
}

/// Persistent banner shown at the top of the chara_detail tab while one or more
/// records sit in the quarantine folder, with a shortcut to open that folder.
class _QuarantineBannerWidget extends ConsumerWidget {
  const _QuarantineBannerWidget();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(charaDetailQuarantineCountProvider);
    if (count == 0) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final quarantineDir = ref.watch(pathInfoProvider).charaDetailQuarantineDir;
    // Flat buttons tinted with the banner's own foreground color so they read as
    // part of the error-themed banner rather than standing out as separate chips.
    final buttonStyle = TextButton.styleFrom(foregroundColor: theme.colorScheme.onErrorContainer);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(Symbols.warning_rounded, color: theme.colorScheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  "$tr_chara_detail.quarantine_banner.message".tr(namedArgs: {"count": "$count"}),
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () => ref.invalidate(charaDetailQuarantineCountProvider),
                icon: const Icon(Symbols.refresh_rounded),
                label: Text("$tr_chara_detail.quarantine_banner.refresh".tr()),
                style: buttonStyle,
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () => quarantineDir.launch(),
                icon: const Icon(Symbols.folder_open_rounded),
                label: Text("$tr_chara_detail.quarantine_banner.open".tr()),
                style: buttonStyle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CharaDetailDataTableLoaderLayer extends ConsumerWidget {
  const CharaDetailDataTableLoaderLayer({super.key});

  Widget loading() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: const [CircularProgressIndicator(), SizedBox(height: 8), Text("Loading")],
      ),
    );
  }

  Widget error(Object? errorMessage, Object? stackTrace, ThemeData theme) {
    return Center(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            "$tr_chara_detail.loading_error".tr(),
            style: TextStyle(color: theme.colorScheme.error),
            textAlign: TextAlign.center,
          ),
          const Divider(),
          Text(errorMessage.toString()),
          const Divider(),
          Text(stackTrace.toString()),
        ],
      ),
    );
  }

  Widget data(BuildContext context, WidgetRef ref) {
    return Column(
      children: const [
        _QuarantineBannerWidget(),
        _TopControlsLayer(),
        SizedBox(height: 4),
        _CharaDetailDataTablePreCheckLayer(),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final loader = ref.watch(charaDetailInitialDataLoader);
    return loader.when(
      // A background reload of an upstream loader (path/module/record storage)
      // must not tear down the whole table subtree: doing so remounts the grid,
      // resetting its scroll offset and dropping the row selection. Keep showing
      // the existing data across reloads; only the very first load shows the
      // spinner (no previous value to keep).
      skipLoadingOnReload: true,
      loading: () => loading(),
      error: (errorMessage, stackTrace) => error(errorMessage, stackTrace, theme),
      data: (_) => data(context, ref),
    );
  }
}
