import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';
import 'package:trina_grid/trina_grid.dart';

import '/const.dart';
import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/sentry_util.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/storage/storage_delete_request.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/core/video_import.dart';
import '/src/gui/chara_detail/archive_record_dialog.dart';
import '/src/gui/chara_detail/column_preset_bar_widget.dart';
import '/src/gui/chara_detail/column_spec_tag_widget.dart';
import '/src/gui/chara_detail/delete_record_dialog.dart';
import '/src/gui/chara_detail/export_button.dart';
import '/src/gui/chara_detail/preview_dialog.dart';
import '/src/gui/chara_detail/regenerate_record_dialog.dart';
import '/src/gui/chara_detail/report_record_dialog.dart';
import '/src/gui/chara_detail/side_preview.dart';
import '/src/gui/chara_detail/storage_status_banner.dart';
import '/src/gui/common.dart';
import '/src/gui/record_store_banner.dart';
import '/src/gui/storage_tree.dart';
import '/src/gui/theme_extensions.dart';
import '/src/gui/toast.dart';
import '/src/preference/settings_state.dart';
import '/src/preference/storage_box.dart';

// ignore: constant_identifier_names
const tr_chara_detail = "pages.chara_detail";

// Same retry policy as the stores it awaits: this loader inherits their
// rejection, and riverpod would otherwise keep re-running it (staying *loading*
// with the error attached) long after the store below it has given up.
final charaDetailInitialDataLoader = FutureProvider(retry: retryUnlessStoreOutage, (ref) async {
  final pathInfo = await ref.watch(pathInfoLoader.future);
  // One-time repair of archived records whose geometry json predates being kept in
  // sync with the downscaled image. Runs before the stores load so the preview
  // reads the corrected geometry. Idempotent and gated, so it is a no-op after the
  // first launch.
  await runArchiveGeometryMigrationIfNeeded(
    pathInfo,
    declaration: archiveGeometryRepairLongReadDeclaration(ref.base, pathInfo),
  );
  return Future.wait([ref.watch(moduleInfoLoaders.future), ref.watch(charaDetailRecordStorageLoaderProvider.future)]);
});

class _CharaDetailDataTableWidget extends ConsumerStatefulWidget {
  const _CharaDetailDataTableWidget();

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _CharaDetailDataTableWidgetState();
}

class _CharaDetailDataTableWidgetState extends ConsumerState<_CharaDetailDataTableWidget>
    with SingleTickerProviderStateMixin {
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

  // field -> the width each live column had right after the last build, autoFit,
  // or resize-persist. On pointer-up, a column whose live width drifts from this
  // was dragged by the user, so it is pinned (spec.width persisted); columns that
  // match are left as auto. Refreshed after every autoFit so a content-driven
  // width change is never mistaken for a user drag.
  Map<String, double> _appliedWidths = const {};

  // The current theme and selection purpose, mirrored here so the long-lived
  // rowColorCallback/rowWrapper closures (captured once at grid init) read fresh
  // values through `this` instead of stale locals captured at first build.
  late ThemeData _theme;
  SelectionPurpose? _purpose;

  // Record id -> index within the pinned (frozen) block, rebuilt from the live
  // grid by [_indexPinnedRows] after every reconcile. rowWrapper reads it O(1)
  // per row instead of rescanning every frozen row (where().toList() + indexOf)
  // on each row's paint. [_pinnedRowCount] is the frozen-row count (not the map
  // size, which collapses on a duplicate/missing id) so isLast stays correct.
  Map<String, int> _pinnedIndexById = const {};
  int _pinnedRowCount = 0;

  // Width of the side preview panel, adjusted by dragging the splitter between
  // the grid and the panel. Clamped against the available width at paint time. A
  // ValueNotifier (not setState) so a splitter drag rebuilds only the splitter +
  // panel, not the whole table body (which re-derives the grid order each build).
  final ValueNotifier<double> _panelWidth = ValueNotifier(sidePreviewDefaultPanelWidth);

  // Persists the panel width across launches. The live value stays a ValueNotifier
  // (not a watched provider) so a splitter drag rebuilds only the splitter + panel;
  // this entry just seeds it at launch and is written back when a drag ends.
  StorageEntry<double>? _panelWidthEntry;

  // Id of the grid's current (highlighted) record, mirrored from onActiveCellChanged
  // so the side preview panel can follow the grid selection without storing its own
  // record id. The panel subtree listens to this; the grid body does not rebuild.
  final ValueNotifier<String?> _currentRecordId = ValueNotifier(null);

  // Drives the side preview panel's open/close slide: 0 = closed (subtree
  // unmounted), 1 = fully open. The panel never floats over the grid — it shares
  // the row with it — so opening/closing animates a horizontal reveal while the
  // grid smoothly takes back (or yields) the freed width.
  late final AnimationController _sidePanelController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late final CurvedAnimation _sidePanelReveal = CurvedAnimation(
    parent: _sidePanelController,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  // The last shown side-preview state, retained so the panel keeps rendering its
  // content while it slides closed — by then [sidePreviewProvider] has already
  // gone null, so build falls back to this until the slide settles.
  SidePreviewState? _lastSidePreview;

  @override
  void initState() {
    super.initState();
    // Seed the slide to match the persisted open state so a panel restored open at
    // launch is shown already-open, not sliding in. The slide only plays on later
    // toggles.
    final restored = ref.read(sidePreviewProvider);
    if (restored != null) {
      _lastSidePreview = restored;
      _sidePanelController.value = 1;
    }
    // Seed the panel width from storage (lower-bounded here; the upper bound
    // against the window width is clamped at paint time). Written back on drag end.
    _panelWidthEntry = StorageEntry<double>(
      box: ref.read(storageBoxProvider),
      key: SettingsEntryKey.sidePreviewWidth.name,
    );
    final storedWidth = _panelWidthEntry?.pull();
    if (storedWidth != null) {
      _panelWidth.value = Math.max(sidePreviewMinPanelWidth, storedWidth);
    }
    // Drop the panel subtree once the closing slide finishes. Build gates the
    // subtree on the controller value, and only a rebuild re-evaluates that gate,
    // so the dismissed edge needs an explicit setState to unmount it.
    _sidePanelController.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _sidePanelReveal.dispose();
    _sidePanelController.dispose();
    _panelWidth.dispose();
    _currentRecordId.dispose();
    super.dispose();
  }

  /// The live display order and the position of the record with [id] within it,
  /// or null when the grid is not loaded. The index is -1 when [id] is not in the
  /// sorted set (filtered out / removed).
  (List<CharaDetailRecord>, int)? _locateSorted(String id) {
    if (!_loaded) {
      return null;
    }
    final sorted = stateManager.getSortedRecords().toList();
    return (sorted, sorted.indexWhere((r) => r.id == id));
  }

  /// Highlights and scrolls to the record with [id] (e.g. the existing record a capture duplicates).
  ///
  /// Returns whether the request was handled: false only when the grid is not loaded yet (so the
  /// caller keeps it pending for onLoaded). A record that is filtered out of the current view counts
  /// as handled — there is simply nothing to focus.
  bool _focusRecord(String id) {
    if (!_loaded) {
      return false;
    }
    // Sum the real heights of the scroll-body rows before the target to land exactly on its top edge.
    // Rows are variable height here (a rowWrapper disables trina's fixed itemExtent), so a uniform
    // rowTotalHeight * index lands mid-row and clips the target; frozen rows render outside the scroll
    // body, so they must not count toward the offset.
    final border = stateManager.configuration.style.cellHorizontalBorderWidth;
    TrinaRow? target;
    double offset = 0;
    for (final row in stateManager.refRows) {
      if (stateManager.recordIdOf(row) == id) {
        target = row;
        break;
      }
      if (row.frozen == TrinaRowFrozen.none) {
        offset += (row.height ?? stateManager.rowHeight) + border;
      }
    }
    if (target == null) {
      return true; // filtered out of the current view; nothing to focus.
    }
    final record = target.getUserData<CharaDetailRecord>();
    if (record != null) {
      stateManager.restoreCurrentRecord(record, ignoreField: checkColumnField);
      stateManager.notifyListeners();
    }
    // A frozen (pinned) target is already parked at the top, so only scroll for scroll-body rows.
    if (target.frozen == TrinaRowFrozen.none) {
      final vertical = stateManager.scroll.vertical;
      if (vertical != null) {
        // After layout so the scroll is attached; jumpTo settles any overshoot back to the end bound.
        _afterFrame(() => vertical.jumpTo(offset));
      }
    }
    return true;
  }

  /// Consumes a pending focus request (set when the capture screen navigates here on a duplicate),
  /// resetting it to null once handled so it fires once and does not re-focus on later rebuilds.
  void _consumeFocusRequest() {
    final id = ref.read(charaDetailFocusRecordProvider);
    if (id != null && _focusRecord(id)) {
      ref.read(charaDetailFocusRecordProvider.notifier).set(null);
    }
  }

  /// Moves the grid's current record [delta] rows away in display order; the side
  /// preview panel follows it (it tracks the current record). Keeps the current
  /// column so the highlight stays in place.
  ///
  /// No-op until the grid is loaded, when no record is current, or when the current
  /// record is no longer in the sorted set (filtered out).
  void _navigateSidePreview(int delta) {
    final current = _loaded ? stateManager.currentRecord : null;
    if (current == null) {
      return;
    }
    final located = _locateSorted(current.id);
    if (located == null) {
      return;
    }
    final (sorted, i) = located;
    if (i < 0) {
      return;
    }
    final j = Math.clamp(0, i + delta, sorted.length - 1);
    if (j == i) {
      return;
    }
    // Move the grid selection; restoreCurrentRecord's setCurrentCell fires
    // onActiveCellChanged, which updates _currentRecordId and so the panel.
    stateManager.restoreCurrentRecord(
      sorted[j],
      preferField: stateManager.currentColumnField,
      ignoreField: checkColumnField,
    );
    stateManager.notifyListeners();
  }

  /// Switches the side preview to the image [delta] steps away in the
  /// skill ⇔ factor ⇔ campaign order, keeping the shown record.
  void _changeSidePreviewMode(int delta) {
    final state = ref.read(sidePreviewProvider);
    if (state == null) {
      return;
    }
    final next = sidePreviewModeStep(state.mode, delta);
    if (next == null) {
      return;
    }
    ref.read(sidePreviewProvider.notifier).set(SidePreviewState(mode: next));
  }

  void showPopup(BuildContext context, WidgetRef ref, Offset offset, CharaDetailRecord record, int initialPage) {
    final theme = Theme.of(context);
    final source = ref.read(recordSourceProvider);
    final pathInfo = ref.read(pathInfoProvider);
    // While selecting rows (to archive or export), actions that rebuild the
    // table (and would drop the in-progress selection) are disabled.
    final selecting = ref.read(selectionModeProvider) != null;
    // Re-recognition is disabled while a video import runs, on exactly the predicate the capture
    // button is gated on, so the two halves of import mutual exclusion cannot drift. A batch started
    // now would have every record refused by the worker (the import owns the event loop and runs on
    // its own storage root) and would then reach the batch teardown with the import still decoding.
    // Read rather than watched because a context menu is built afresh each time it is opened.
    final importing = videoImportState.value.isRunning;
    // Re-recognition is also withheld while a registered long reader holds a
    // folder the batch writes: an archive move, a zip or a relocation is reading
    // or renaming that very directory. `CharaDetailRecordRegenerationController.start`
    // refuses the same thing where all five entrances funnel, which is what covers
    // the two that are not controls; this is the half that lets the menu show the
    // entry as unavailable rather than accepting a press that quietly does
    // nothing.
    //
    // Asked over `regenerateRecordLongReadPaths` — the derivation the batch itself
    // claims — and not over the record id: the batch writes `active/<id>` and, on
    // web, the write transaction journal it publishes through, and that function's
    // doc carries why. `source` does not enter it because the entry is active-only
    // and the batch names the active directory whatever the page shows. Read
    // rather than watched for the same reason [importing] is: a context menu is
    // built afresh each time it is opened.
    final regenerationHeld =
        storageDeleteBlockedBy(
          StorageDeletePathsRequest(regenerateRecordLongReadPaths(pathInfo: pathInfo, recordIds: [record.id])),
          ref.read(longReadRegistryProvider).values,
        ) !=
        null;
    final isPinned = ref.read(pinnedRecordIdsProvider).contains(record.id);
    DirectoryPath dirOf(CharaDetailRecord r) => recordDirOf(pathInfo, source, r);
    const constraints = BoxConstraints(minHeight: 40);
    final style = theme.textTheme.labelMedium;
    // The per-item Text/Icon overrides MenuItem's built-in disabled coloring, so
    // grey both the label and the leading icon ourselves for items disabled
    // during selection.
    final disabledStyle = style?.copyWith(color: theme.disabledColor);
    final disabledIconColor = selecting ? theme.disabledColor : null;
    // Material Symbols are a variable font; bump the wght axis so the thin
    // default strokes read clearly at the 16px menu icon size.
    const iconWeight = 700.0;
    final menu = ContextMenu(
      position: offset,
      entries: <ContextMenuEntry>[
        // Pin/unpin the row to the top of the table. Disabled while selecting,
        // since toggling rebuilds the grid and would drop the in-progress
        // checkbox selection.
        MenuItem(
          constraints: constraints,
          enabled: !selecting,
          icon: Icon(isPinned ? Symbols.keep_off : Symbols.keep, weight: iconWeight, color: disabledIconColor),
          onSelected: (_) {
            final next = {...ref.read(pinnedRecordIdsProvider)};
            isPinned ? next.remove(record.id) : next.add(record.id);
            ref.read(pinnedRecordIdsProvider.notifier).set(next);
          },
          label: Text(
            "$tr_chara_detail.context_menu.${isPinned ? "unpin" : "pin_to_top"}".tr(),
            style: selecting ? disabledStyle : style,
          ),
        ),
        MenuItem(
          constraints: constraints,
          icon: const Icon(Symbols.visibility, weight: iconWeight),
          onSelected: (_) {
            final records = stateManager.getSortedRecords().toList();
            final index = records.indexOf(record);
            final directories = records.map(dirOf).toList();
            return CharaDetailPreviewDialog.show(ref.base, directories, index);
          },
          label: Text("$tr_chara_detail.context_menu.preview".tr(), style: style),
        ),
        // File group: open the record's folder and copy the recognition images.
        MenuItem.submenu(
          constraints: constraints,
          icon: const Icon(Symbols.folder, weight: iconWeight),
          label: Text("$tr_chara_detail.context_menu.group_file".tr(), style: style),
          items: [
            MenuItem(
              constraints: constraints,
              icon: const Icon(Symbols.content_copy, weight: iconWeight),
              onSelected: (_) =>
                  copyRecordImageToClipboard(ref.base, dirOf(record), CharaDetailRecordImageMode.skillPlain),
              label: Text("$tr_chara_detail.context_menu.copy_skill".tr(), style: style),
            ),
            MenuItem(
              constraints: constraints,
              icon: const Icon(Symbols.content_copy, weight: iconWeight),
              onSelected: (_) =>
                  copyRecordImageToClipboard(ref.base, dirOf(record), CharaDetailRecordImageMode.factorPlain),
              label: Text("$tr_chara_detail.context_menu.copy_factor".tr(), style: style),
            ),
            // Revealing the record folder needs an OS file manager; on web the
            // paths are virtual (OPFS) and there is nothing to open, so the
            // entry is absent rather than present and inert.
            if (CurrentPlatform.canRevealInFileManager())
              MenuItem(
                constraints: constraints,
                icon: const Icon(Symbols.folder_open, weight: iconWeight),
                onSelected: (_) => dirOf(record).launch(),
                label: Text("$tr_chara_detail.context_menu.open_in_explorer".tr(), style: style),
              ),
          ],
        ),
        // Destructive record actions, set off by a divider: archive (active-only;
        // archived records cannot be archived again) then delete (both sources).
        const MenuDivider(),
        if (source == RecordSource.active)
          MenuItem(
            constraints: constraints,
            enabled: !selecting,
            icon: Icon(Symbols.archive, weight: iconWeight, color: disabledIconColor),
            onSelected: (_) => ArchiveRecordDialog.show(ref.base, recordId: record.id, source: source),
            label: Text("$tr_chara_detail.context_menu.archive_record".tr(), style: selecting ? disabledStyle : style),
          ),
        MenuItem(
          constraints: constraints,
          enabled: !selecting,
          icon: Icon(Symbols.delete, weight: iconWeight, color: disabledIconColor),
          onSelected: (_) => DeleteRecordDialog.show(ref.base, recordId: record.id, source: source),
          label: Text("$tr_chara_detail.context_menu.delete_record".tr(), style: selecting ? disabledStyle : style),
        ),
        // Recognition actions, listed inline (active records only), so the
        // trailing divider that sets them off is active-only too — otherwise an
        // archived record would end on a dangling separator. Re-recognize, then
        // report a misrecognition (Sentry builds only).
        if (source == RecordSource.active) const MenuDivider(),
        if (source == RecordSource.active)
          MenuItem(
            constraints: constraints,
            enabled: !selecting && !importing && !regenerationHeld,
            icon: Icon(
              Symbols.autorenew,
              weight: iconWeight,
              color: (selecting || importing || regenerationHeld) ? theme.disabledColor : null,
            ),
            onSelected: (_) async {
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
            label: Text(
              "$tr_chara_detail.context_menu.regenerate_record".tr(),
              // Greyed with no sentence beside it, which is a known gap and not a
              // choice made here: `MenuItem` takes no tooltip, so none of this
              // menu's withheld entries can say why. The dialog this entry opens
              // for an unsupported version does carry the sentence.
              style: (selecting || importing || regenerationHeld) ? disabledStyle : style,
            ),
          ),
        if (source == RecordSource.active && isSentryAvailable())
          MenuItem(
            constraints: constraints,
            icon: const Icon(Symbols.flag, weight: iconWeight),
            onSelected: (_) => ReportRecordDialog.show(ref.base, dirOf(record)),
            label: Text("$tr_chara_detail.context_menu.report_record".tr(), style: style),
          ),
      ],
    );
    showContextMenu(
      context,
      contextMenu: menu,
      routeOptions: const MenuRouteOptions(
        transitionDuration: Duration(milliseconds: 120),
        reverseTransitionDuration: Duration(milliseconds: 120),
      ),
    );
  }

  /// Records the live width of every column as the baseline against which the
  /// next pointer-up detects a user drag. Called right after every autoFit (and
  /// the initial load) so a content-driven re-fit resets the baseline rather than
  /// reading as a manual resize.
  void _snapshotColumnWidths() {
    if (!_loaded) {
      return;
    }
    _appliedWidths = {for (final col in stateManager.columns) col.field: col.width};
  }

  /// Reflows row heights for the current row-height mode and minimum line count:
  /// wrap fixes rows at the floor, autoPerRow grows each row to its text, and
  /// autoUniform grows all rows to the tallest. Runs after every autoFit/resize
  /// since wrapping depends on the final column widths, and on a setting change.
  /// Re-indexes the pinned block because the height pass replaces the row objects
  /// it touches.
  void _applyRowHeights() {
    if (!_loaded) {
      return;
    }
    final mode = ref.read(charaDetailRowHeightModeProvider);
    final minLines = ref.read(charaDetailMinRowLinesProvider);
    if (stateManager.applyRowHeights(mode: mode, minLines: minLines)) {
      _indexPinnedRows();
      stateManager.notifyListeners();
    }
  }

  /// Pins any column the user just dragged: a live width that drifts from the
  /// recorded baseline persists onto its spec as an explicit width, which makes
  /// [autoFitColumns] skip it thereafter. The live column's user data is updated
  /// in lockstep so a later content re-fit keeps skipping the now-pinned column
  /// rather than measuring it back to auto. The replaceById below also rebuilds
  /// the grid, and refreshColumnRenderers re-seats this same spec onto the live
  /// column, so the user data stays in sync with the loader either way.
  void _persistResizedColumns() {
    if (!_loaded) {
      return;
    }
    final resized = <(TrinaColumn, ColumnSpec)>[];
    for (final col in stateManager.columns) {
      final previous = _appliedWidths[col.field];
      if (previous == null || (col.width - previous).abs() < 0.5) {
        continue;
      }
      final spec = col.getUserData<ColumnSpec>();
      if (spec != null) {
        resized.add((col, spec.withWidth(col.width)));
      }
    }
    if (resized.isEmpty) {
      return;
    }
    final selection = ref.read(currentColumnSpecsLoaderProvider.notifier);
    for (final (col, spec) in resized) {
      col.setUserData(spec);
      selection.replaceById(spec);
    }
    _snapshotColumnWidths();
    _applyRowHeights();
  }

  /// The column whose header occupies the content-space x offset [dx] (grid
  /// inset already removed by the caller), accounting for frozen columns and the
  /// horizontal scroll offset. Returns null outside any column (e.g. past the
  /// last column or in an empty grid).
  TrinaColumn? _columnAtHeaderOffset(double dx) {
    final sm = stateManager;
    if (sm.showFrozenColumn) {
      var acc = 0.0;
      for (final col in sm.leftFrozenColumns) {
        acc += col.width;
        if (dx < acc) {
          return col;
        }
      }
      final bodyDx = dx - sm.leftFrozenColumnsWidth + (sm.scroll.horizontal?.offset ?? 0);
      var bodyAcc = 0.0;
      for (final col in sm.bodyColumns) {
        bodyAcc += col.width;
        if (bodyDx < bodyAcc) {
          return col;
        }
      }
      return null;
    }
    final scrolledDx = dx + (sm.scroll.horizontal?.offset ?? 0);
    var acc = 0.0;
    for (final col in sm.columns) {
      acc += col.width;
      if (scrolledDx < acc) {
        return col;
      }
    }
    return null;
  }

  /// Opens the column-header context menu (right-click on a header) offering to
  /// sort the column (ascending/descending/clear, via a submenu) or revert it to
  /// content-driven auto width.
  void _showColumnHeaderMenu(BuildContext context, Offset position, TrinaColumn column) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium;
    final disabledStyle = style?.copyWith(color: theme.disabledColor);
    const constraints = BoxConstraints(minHeight: 40);
    const iconWeight = 700.0;
    final pinned = column.getUserData<ColumnSpec>()?.width != null;
    final menu = ContextMenu(
      position: position,
      entries: <ContextMenuEntry>[
        MenuItem(
          constraints: constraints,
          enabled: pinned,
          icon: Icon(Symbols.restart_alt, weight: iconWeight, color: pinned ? null : theme.disabledColor),
          onSelected: (_) => _resetColumnWidth(column),
          label: Text("$tr_chara_detail.column_context_menu.reset_width".tr(), style: pinned ? style : disabledStyle),
        ),
        MenuItem.submenu(
          constraints: constraints,
          icon: const Icon(Symbols.swap_vert, weight: iconWeight),
          label: Text("$tr_chara_detail.column_context_menu.sort.label".tr(), style: style),
          items: [
            MenuItem(
              constraints: constraints,
              icon: const Icon(Symbols.arrow_upward, weight: iconWeight),
              onSelected: (_) => _sortColumn(column, TrinaColumnSort.ascending),
              label: Text("$tr_chara_detail.column_context_menu.sort.ascending".tr(), style: style),
            ),
            MenuItem(
              constraints: constraints,
              icon: const Icon(Symbols.arrow_downward, weight: iconWeight),
              onSelected: (_) => _sortColumn(column, TrinaColumnSort.descending),
              label: Text("$tr_chara_detail.column_context_menu.sort.descending".tr(), style: style),
            ),
            MenuItem(
              constraints: constraints,
              icon: const Icon(Symbols.close, weight: iconWeight),
              onSelected: (_) => _sortColumn(column, TrinaColumnSort.none),
              label: Text("$tr_chara_detail.column_context_menu.sort.none".tr(), style: style),
            ),
          ],
        ),
      ],
    );
    showContextMenu(
      context,
      contextMenu: menu,
      routeOptions: const MenuRouteOptions(
        transitionDuration: Duration(milliseconds: 120),
        reverseTransitionDuration: Duration(milliseconds: 120),
      ),
    );
  }

  /// Reverts a single column to auto width: clears its spec's pinned width (live
  /// user data first so the deferred autoFit no longer skips it), persists the
  /// change, then re-fits since a same-columns reconcile alone would not.
  void _resetColumnWidth(TrinaColumn column) {
    final spec = column.getUserData<ColumnSpec>();
    if (spec == null || spec.width == null) {
      return;
    }
    final cleared = spec.withWidth(null);
    column.setUserData(cleared);
    ref.read(currentColumnSpecsLoaderProvider.notifier).replaceById(cleared);
    _afterFrame(() {
      stateManager.autoFitColumns();
      _snapshotColumnWidths();
      _applyRowHeights();
    });
  }

  /// Sorts [column] in [order] from the header context menu. Unlike a header
  /// click (toggleSortColumn), the direct sort calls don't fire onSorted, so the
  /// sort bookkeeping and the pinned-row index are updated here to match — none
  /// restores the original order via sortBySortIdx.
  void _sortColumn(TrinaColumn column, TrinaColumnSort order) {
    if (!_loaded) {
      return;
    }
    switch (order) {
      case TrinaColumnSort.ascending:
      case TrinaColumnSort.descending:
        stateManager.sortColumn(column, order);
      case TrinaColumnSort.none:
        stateManager.sortBySortIdx(column);
    }
    if (order == TrinaColumnSort.none) {
      sortColumn = null;
      sortOrder = TrinaColumnSort.none;
    } else {
      sortColumn = column.field;
      sortOrder = order;
    }
    _indexPinnedRows();
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

  /// Runs [action] after the current frame, but only while the grid is still
  /// mounted and loaded.
  ///
  /// Every imperative grid poke is deferred this way: the grid may leave the tree
  /// before the next frame (page torn down, or columns emptied — which disposes
  /// the stateManager), so the guard keeps a stale/disposed manager from being
  /// touched.
  void _afterFrame(VoidCallback action) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _loaded) {
        action();
      }
    });
  }

  /// Rebuilds the frozen-row index from the live grid, in the order the renderer
  /// iterates (refRows.originalList filtered to frozen).
  ///
  /// Called after every reconcile (and the initial load) because a sort reorders
  /// pinned rows among themselves, so the watched provider's row order is not a
  /// reliable source. rowWrapper reads the resulting field at paint time.
  void _indexPinnedRows() {
    final pinnedRows = stateManager.refRows.originalList.where((row) => row.frozen == TrinaRowFrozen.start).toList();
    _pinnedRowCount = pinnedRows.length;
    _pinnedIndexById = {for (var i = 0; i < pinnedRows.length; i++) ?stateManager.recordIdOf(pinnedRows[i]): i};
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
    // Remember the highlighted row's record (and which column the user had
    // selected) so the selection survives the update. The row diff keeps an
    // unchanged row's identity on its own, but a structural column change
    // rebuilds every row and clears the current cell.
    final selectedRecord = stateManager.currentRecord;
    final selectedField = stateManager.currentColumnField;
    final columnsChanged = _appliedGrid == null || !_sameColumns(_appliedGrid!.columns, next.columns);
    if (columnsChanged) {
      // Clear rows first so the column replace operates on an empty row set (no
      // wasted per-row cell fill/remove, no transient cell/column mismatch).
      stateManager.removeAllRows(notify: false);
      stateManager.removeColumns(stateManager.columns.toList());
      stateManager.insertColumns(0, next.columns);
      // Replace the row set wholesale, restoring the canonical sortIdx and the
      // current cell position (shared with reconcileRows' bulk fallback).
      stateManager.replaceAllRows(next.rows, sortColumn: sortColumn, sortOrder: sortOrder);
      // autoFitColumns measures via gridKey.currentContext, which needs the new
      // columns laid out first, so defer it one frame (the grid may have left the
      // tree before the frame, disposing its stateManager — _afterFrame guards that).
      _afterFrame(() {
        stateManager.autoFitColumns();
        _snapshotColumnWidths();
        _applyRowHeights();
      });
    } else {
      stateManager.refreshColumnRenderers(next.columns);
      // _reconcile notifies once at the end (after restoreCurrentRecord), so the
      // row diff and the restored selection land in a single repaint.
      final rowsChanged = stateManager.reconcileRows(
        next.rows,
        sortColumn: sortColumn,
        sortOrder: sortOrder,
        notify: false,
      );
      // Re-fit columns when the row set actually changed (e.g. a cell edited to a
      // longer value), matching the pre-incremental behavior. Skipped on a
      // selection/sort-only reconcile so widths don't churn needlessly.
      if (rowsChanged) {
        _afterFrame(() {
          stateManager.autoFitColumns();
          _snapshotColumnWidths();
          _applyRowHeights();
        });
      }
    }
    // Re-highlight the same record on the same column when possible (skips the
    // checkbox cell so the highlight lands on a data cell). No-op when it is still
    // current or now filtered out.
    stateManager.restoreCurrentRecord(selectedRecord, preferField: selectedField, ignoreField: checkColumnField);
    _appliedGrid = next;
    // Re-index the pinned block from the now-final live row order before the
    // repaint so rowWrapper's O(1) lookup matches what the renderer draws.
    _indexPinnedRows();
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
      // The grid's long-lived row callbacks read _theme; nudge them to repaint
      // with the new colors (a theme change doesn't touch currentGridProvider). A
      // font/text-scale change also alters wrapping, so re-fit row heights too.
      _afterFrame(() {
        _applyRowHeights();
        stateManager.notifyListeners();
      });
    }
    // Apply subsequent grid changes to the live stateManager rather than letting
    // the watch above rebuild a fresh grid (TrinaGrid ignores changed columns/rows
    // after init). The watch stays only to seed the initial grid and the empty
    // checks below.
    ref.listen(currentGridProvider, (_, next) => _reconcile(next));
    // Changing the row-height mode or minimum doesn't rebuild the grid (only the
    // CellText cells, which watch the settings), so reflow the live row heights
    // here on change.
    ref.listen(charaDetailRowHeightModeProvider, (_, _) => _afterFrame(_applyRowHeights));
    ref.listen(charaDetailMinRowLinesProvider, (_, _) => _afterFrame(_applyRowHeights));
    // A focus request set while this table is already alive (e.g. from the capture screen on a
    // duplicate). A request that arrives before load is picked up by onLoaded instead.
    ref.listen(charaDetailFocusRecordProvider, (_, next) {
      if (next != null) {
        _consumeFocusRequest();
      }
    });
    // No source-switch listener needed: the panel tracks the grid's current record
    // and re-resolves it against the live sorted set each build, so a source switch
    // (the old record's id is absent from the new source) falls back to the empty
    // placeholder on its own.
    final sidePreview = ref.watch(sidePreviewProvider);
    // The narrow (drawer + app bar) layout has no room for the panel, so it is
    // disabled there (toggle hidden, panel not rendered). Computed up here so the
    // grid's onSelected handler — built below — can also gate on it.
    final narrow = !isSidePreviewAllowed(context);
    if (grid.columns.isEmpty) {
      // The grid leaves the tree here, disposing its stateManager. Mark it
      // unloaded so a grid update (via the listen above) or theme repaint won't
      // touch the dead manager; onLoaded re-initializes it when columns return.
      _loaded = false;
      return Container();
    }
    final gridStack = Stack(
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
            // trina_grid exposes no resize-complete callback, so wrap the grid and
            // read column widths on pointer-up: any column whose width drifted from
            // the recorded baseline was dragged, and is pinned. A secondary press on
            // the header band opens the auto-width reset menu (trina has no
            // header-secondary-tap event either).
            return Listener(
              onPointerUp: (_) => _persistResizedColumns(),
              onPointerDown: (event) {
                if (!_loaded || event.buttons != kSecondaryButton) {
                  return;
                }
                // trina's _GridContainer insets its content by gridBorderWidth +
                // gridPadding, which the Listener's localPosition doesn't account
                // for. Map into content space before the header-band check and
                // column hit-test so both land on the right column / boundary.
                final inset = stateManager.gridBorderWidth + stateManager.gridPadding;
                final local = event.localPosition - Offset(inset, inset);
                if (local.dy < 0 || local.dy > stateManager.columnHeight) {
                  return;
                }
                final column = _columnAtHeaderOffset(local.dx);
                if (column == null || column.enableRowChecked) {
                  return;
                }
                _showColumnHeaderMenu(context, event.position, column);
              },
              child: ColoredBox(
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
                    if (rowContext.stateManager.isCurrentRecord(rowContext.row)) {
                      return theme.colorScheme.primaryContainer;
                    }
                    return rowContext.rowIdx.isEven
                        ? theme.colorScheme.surface
                        : theme.colorScheme.surfaceContainerLowest;
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
                      // Position within the frozen block, precomputed by
                      // [_indexPinnedRows] from the live row order.
                      final rowId = stateManager.recordIdOf(rowData);
                      final pinnedIdx = rowId == null ? -1 : (_pinnedIndexById[rowId] ?? -1);
                      if (pinnedIdx >= 0) {
                        final isLast = pinnedIdx == _pinnedRowCount - 1;
                        // The stripe and separator don't depend on the selection, so
                        // compute them once; only the current-row highlight below is
                        // recomputed per notify.
                        final stripe = pinnedIdx.isEven
                            ? theme.colorScheme.surface
                            : theme.colorScheme.surfaceContainerLowest;
                        final separator = isLast
                            ? BorderSide(color: theme.colorScheme.outline, width: 3)
                            : BorderSide(
                                color: theme.focusColor,
                                width: stateManager.configuration.style.cellHorizontalBorderWidth,
                              );
                        final bordered = DecoratedBox(
                          position: DecorationPosition.foreground,
                          decoration: BoxDecoration(border: Border(bottom: separator)),
                          child: row,
                        );
                        // The current-row highlight must track currentCell changes.
                        // Scrollable rows get this for free: their highlight is
                        // painted inside TrinaBaseRow (via rowColorCallback), which
                        // listens to the stateManager and rebuilds on every notify.
                        // Frozen rows render with a transparent frozenRowColor and
                        // bypass rowColorCallback, so this outer wrapper paints their
                        // highlight — but it only re-runs on a body rebuild, leaving a
                        // stale highlight when the selection moves to another row.
                        // Listen to the stateManager here so the background repaints by
                        // record id whenever the current row changes.
                        row = ListenableBuilder(
                          listenable: stateManager,
                          builder: (context, child) {
                            final background = stateManager.isCurrentRecord(rowData)
                                ? theme.colorScheme.primaryContainer
                                : stripe;
                            return DecoratedBox(
                              decoration: BoxDecoration(color: background),
                              child: child,
                            );
                          },
                          child: bordered,
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
                      // Disable trina's built-in current-row fill. It highlights
                      // the row where `currentRowIdx == widget.rowIdx`, comparing
                      // a (tap-set) display index against each row's display
                      // index. With pinned (frozen) rows that index space drifts
                      // out of sync with refRows after a reconcile, so the
                      // built-in fill lands on the wrong row — a second highlight
                      // on top of the record-id one we paint in rowColorCallback/
                      // rowWrapper. A transparent color fails trina's
                      // `activatedColor.a > 0` guard, leaving our callback's color
                      // in place, so the highlight is driven solely by record id.
                      activatedColor: Colors.transparent,
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
                    _snapshotColumnWidths();
                    _applyRowHeights();
                    if (sortColumn != null) {
                      event.stateManager.sortColumnByField(sortColumn!, sortOrder);
                    }
                    // Index the pinned block so frozen rows are styled on first
                    // load; a later _pending reconcile reindexes (harmlessly).
                    _indexPinnedRows();
                    // A grid change may have arrived before the stateManager was
                    // ready; apply the latest one now.
                    if (_pending != null) {
                      final pending = _pending!;
                      _pending = null;
                      _reconcile(pending);
                    }
                    // Seed the side preview's record tracker from whatever is current
                    // after load (normally nothing, since auto-select is disabled).
                    _currentRecordId.value = event.stateManager.currentRecord?.id;
                    // A focus request may have been set before the grid was ready (e.g. the capture
                    // screen navigated here on a duplicate); apply it now that rows exist.
                    _consumeFocusRequest();
                  },
                  // The side preview panel follows the grid's current record. This
                  // fires on every current-cell change — user taps and the
                  // programmatic restoreCurrentRecord in _navigateSidePreview alike
                  // (setCurrentCell calls it even with notify:false) — so mirroring the
                  // id here keeps the panel in sync without the panel storing its own.
                  onActiveCellChanged: (_) {
                    _currentRecordId.value = stateManager.currentRecord?.id;
                    // Keep the shown image (mode) following the focused column on every
                    // current-cell change — keyboard moves and the programmatic
                    // restoreCurrentRecord alike, not just mouse clicks (which also pass
                    // through onSelected). The panel only tracks the record id; the mode
                    // is re-derived here from the focused column's cell action so the
                    // image always matches the column in focus. The breakpoint is
                    // re-checked (not read from the captured `narrow`) for the same
                    // reason onSelected does: this closure is captured once at grid load.
                    final sidePreview = ref.read(sidePreviewProvider);
                    if (sidePreview != null && isSidePreviewAllowed(context)) {
                      final action = stateManager.currentCell?.column.getUserData<ColumnSpec>()?.cellAction;
                      final mode = imageModeForColumnAction(action);
                      if (mode != sidePreview.mode) {
                        ref.read(sidePreviewProvider.notifier).set(SidePreviewState(mode: mode));
                      }
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
                    _afterFrame(() => stateManager.notifyListeners());
                  },
                  onSelected: (TrinaGridOnSelectedEvent event) {
                    try {
                      final data = event.cell?.getUserData<CellData>();
                      // Pass this State's live ref (stable for the widget's
                      // lifetime), never a grid-build ref the cell captured: the
                      // grid provider may have rebuilt and disposed that one.
                      if (!(data?.onSelected?.call(ref.base, event) ?? false)) {
                        final record = event.cell?.row.getUserData<CharaDetailRecord>();
                        if (record == null) {
                          return;
                        }
                        // While the side preview panel is open (and visible — not in
                        // the narrow layout where it is hidden), a cell click only moves
                        // the focus: the panel follows the grid's current record and the
                        // shown image is re-derived from the focused column, both in
                        // onActiveCellChanged (which the tap also fires). So here we only
                        // suppress the dialog.
                        //
                        // The breakpoint is re-evaluated here, not read from the
                        // build-scope `narrow`: TrinaGrid captures this onSelected
                        // closure once (at grid load) and never refreshes it, so a
                        // captured `narrow` would stay frozen at its first-build value
                        // and feed the hidden panel after the window shrinks.
                        if (ref.read(sidePreviewProvider) != null && isSidePreviewAllowed(context)) {
                          return;
                        }
                        final source = ref.read(recordSourceProvider);
                        final pathInfo = ref.read(pathInfoProvider);
                        // event.rowIdx is unreliable once any row is frozen
                        // (pinned): frozen rows render in a separate block and
                        // shift the scrollable rows' indices, so it no longer maps
                        // to getSortedRecords. Resolve the tapped record from its
                        // own cell row and find its position by identity instead.
                        final sorted = stateManager.getSortedRecords().toList();
                        final index = sorted.indexOf(record);
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
                    // A header click runs trina's own per-column sort, which
                    // leaves same-day (tied) rows in an undefined order. Re-break
                    // those ties by capture date, mirroring the sort direction.
                    stateManager.applyCaptureDateTiebreak(event.column, event.column.sort);
                    // A header-click sort reorders the frozen rows in place
                    // (FilteredList.sort works on originalList), but unlike
                    // _reconcile/onLoaded it doesn't rebuild the pinned index, so
                    // rowWrapper's stripe/boundary would read stale positions.
                    // toggleSortColumn fires this before its own notifyListeners,
                    // so re-indexing here lands in the very next repaint.
                    _indexPinnedRows();
                  },
                ),
              ),
            );
          },
        ),
        if (grid.rows.isEmpty) Text("$tr_chara_detail.no_row_message".tr()),
      ],
    );

    // The panel follows the grid's current record (mirrored into _currentRecordId);
    // its directory is resolved against the active source. Watch source/pathInfo here
    // in the build phase — the nested builders below run during layout, where
    // ref.watch is unsafe — and pass them down. Only needed while the panel shows.
    //
    // In the narrow layout the panel is simply not rendered (see the Row below) and a
    // cell click opens the dialog instead (onSelected re-checks the breakpoint), so
    // the open state is left untouched — widening the window restores the panel.
    // Drive the open/close slide off the toggle (and the narrow-layout gate). The
    // calls are idempotent while already settled or animating, so running them each
    // build is safe; they only start a ticker, never setState. While sliding closed
    // sidePreview is already null, so the subtree renders [_lastSidePreview] until
    // the controller reaches 0 (its status listener then rebuilds to unmount it).
    final wantSide = sidePreview != null && !narrow;
    if (wantSide) {
      _lastSidePreview = sidePreview;
      _sidePanelController.forward();
    } else {
      _sidePanelController.reverse();
    }
    final sideShown = wantSide || _sidePanelController.value > 0;
    final sideState = sidePreview ?? _lastSidePreview;
    final sideSource = sideShown ? ref.watch(recordSourceProvider) : null;
    final sidePathInfo = sideShown ? ref.watch(pathInfoProvider) : null;

    // Keep the grid mounted at a stable tree position whether or not the panel is
    // open: its ValueKey only preserves identity among siblings, so moving the
    // grid under a different ancestor (a conditional Row vs. bare Stack) would
    // remount it and drop its scroll offset and row selection. Only the trailing
    // splitter + panel are conditionally added.
    return Expanded(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxPanel = Math.max(sidePreviewMinPanelWidth, constraints.maxWidth - sidePreviewMinGridWidth);
          return Row(
            children: [
              Expanded(child: gridStack),
              // Re-resolve which record the panel shows whenever the grid's current
              // record changes (taps / prev-next mirror into _currentRecordId). The
              // sorted lookup runs here, not on splitter drag — that is the inner
              // _panelWidth builder.
              if (sideShown && sideState != null)
                // Clip + reveal the panel along the horizontal axis so opening and
                // closing slide in from / out to the right edge instead of snapping.
                // The child keeps its full width (so its image never reflows mid-
                // slide); SizeTransition clips it to the animated fraction, and the
                // grid's Expanded takes back the freed width each frame.
                ClipRect(
                  child: SizeTransition(
                    axis: Axis.horizontal,
                    alignment: Alignment.centerRight,
                    sizeFactor: _sidePanelReveal,
                    child: ValueListenableBuilder<String?>(
                      valueListenable: _currentRecordId,
                      builder: (context, currentId, _) {
                        DirectoryPath? sideRecordDir;
                        var canPrev = false;
                        var canNext = false;
                        if (currentId != null && sideSource != null && sidePathInfo != null) {
                          final located = _locateSorted(currentId);
                          if (located != null) {
                            final (sorted, i) = located;
                            if (i >= 0) {
                              // i < 0 means the current record is no longer in the sorted
                              // set (filtered out, or a stale selection after a source
                              // switch): leave recordDir null so the panel shows its
                              // placeholder instead of a missing-directory error.
                              sideRecordDir = recordDirOfId(sidePathInfo, sideSource, currentId);
                              canPrev = i > 0;
                              canNext = i < sorted.length - 1;
                            }
                          }
                        }
                        final hasRecord = sideRecordDir != null;
                        final canModeLeft = hasRecord && canStepSidePreviewMode(sideState.mode, -1);
                        final canModeRight = hasRecord && canStepSidePreviewMode(sideState.mode, 1);
                        // Only the splitter + panel listen to _panelWidth, so dragging the
                        // splitter rebuilds just this subtree — not the sorted lookup above.
                        return ValueListenableBuilder<double>(
                          valueListenable: _panelWidth,
                          builder: (context, width, _) {
                            final panelWidth = Math.clamp(sidePreviewMinPanelWidth, width, maxPanel);
                            return Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                MouseRegion(
                                  cursor: SystemMouseCursors.resizeColumn,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onHorizontalDragStart: (_) {
                                      // Re-seat the stored width to the currently displayed
                                      // (clamped) value so a drag begun after the window
                                      // shrank doesn't snap back to a stale wider value.
                                      _panelWidth.value = panelWidth;
                                    },
                                    onHorizontalDragUpdate: (details) {
                                      // Accumulate against the live value, not the
                                      // build-local `panelWidth`: several drag updates can
                                      // fire before a rebuild, and each would otherwise read
                                      // the same stale base, so the width would lag behind
                                      // the cursor. Dragging the splitter left widens the
                                      // right-hand panel, hence subtracting delta.dx.
                                      _panelWidth.value = Math.clamp(
                                        sidePreviewMinPanelWidth,
                                        _panelWidth.value - details.delta.dx,
                                        maxPanel,
                                      );
                                    },
                                    // Persist once the drag settles rather than on
                                    // every update, so the panel reopens at the size
                                    // the user left it.
                                    onHorizontalDragEnd: (_) => _panelWidthEntry?.push(_panelWidth.value),
                                    child: SizedBox(
                                      width: 10,
                                      child: Center(child: Container(width: 2, color: theme.colorScheme.outline)),
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: panelWidth,
                                  child: SidePreviewPanel(
                                    recordDir: sideRecordDir,
                                    mode: sideState.mode,
                                    canPrev: canPrev,
                                    canNext: canNext,
                                    canModeLeft: canModeLeft,
                                    canModeRight: canModeRight,
                                    onNavigate: _navigateSidePreview,
                                    onChangeMode: _changeSidePreviewMode,
                                  ),
                                ),
                              ],
                            );
                          },
                        );
                      },
                    ),
                  ),
                ),
            ],
          );
        },
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
      color: theme.semantic.noticeContainer,
      onColor: theme.semantic.onNoticeContainer,
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

/// The preset bar + column chips, withdrawn behind a scrim while bulk-archive
/// selection is active.
///
/// During selection every top control (presets, source switch, column chips)
/// must be inert — changing any of them rebuilds the grid and would drop the
/// in-progress checkbox selection. The controls are withdrawn and the scrim
/// surfaces the only two valid actions: archive the selection, or cancel.
///
/// **The scrim is not what makes them inert.** [AbsorbPointer] refuses
/// hit-testing and touches no focus node, exactly as [IgnorePointer] does, so
/// covering the controls left them Tab-reachable and firing on Enter and on
/// Space — a keyboard user could switch presets or a column spec mid-selection
/// and rebuild the grid out from under the checkboxes. [Disabled] is the app's
/// one primitive for "this control is withdrawn", and it withdraws from both
/// input devices; reusing it here is also what keeps a second implementation of
/// the same idea from drifting away from the first.
class TopControlsLayer extends ConsumerWidget {
  /// The controls the scrim covers. Injectable only so a test can mount this
  /// layer without the preset bar's and the chip row's whole provider graph:
  /// what is under test is the withdrawal, which has to hold for any child.
  final Widget controls;

  const TopControlsLayer({
    super.key,
    this.controls = const Column(
      mainAxisSize: MainAxisSize.min,
      children: [ColumnPresetBarWidget(), ColumnSpecTagWidget()],
    ),
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final purpose = ref.watch(selectionModeProvider);
    final selectedCount = ref.watch(selectedRecordIdsProvider).length;
    return Stack(
      children: [
        Disabled(disabled: purpose != null, child: controls),
        if (purpose != null)
          Positioned.fill(
            child: Stack(
              children: [
                // The scrim still absorbs taps: with the controls under it
                // ignoring the pointer, an unabsorbed tap would fall through to
                // whatever the table paints behind this layer.
                Positioned.fill(
                  child: AbsorbPointer(child: ColoredBox(color: theme.colorScheme.surface.withValues(alpha: 0.85))),
                ),
                // The two valid actions sit above the scrim and stay interactive.
                Center(
                  // Label on its own line above the action buttons, so a long
                  // message does not overflow the row on narrow windows.
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        // Purpose-neutral ("selecting N records; columns/presets
                        // are frozen"), so it is shared by both flows.
                        "$tr_chara_detail.archive_records.overlay.message".tr(namedArgs: {"count": "$selectedCount"}),
                        style: theme.textTheme.labelLarge,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _SelectionConfirmButton(purpose: purpose, selectedCount: selectedCount),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            icon: const Icon(Symbols.cancel_rounded, size: 20),
                            label: Text("$tr_chara_detail.archive_records.cancel.label".tr()),
                            onPressed: () => exitSelection(ref),
                          ),
                        ],
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
/// ([BulkArchiveRecordDialog] or [ExportRecordDialog]) for the checked rows.
/// Disabled until at least one row is checked.
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
                  BulkArchiveRecordDialog.show(ref.base, recordIds: recordIds);
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
    // The count is loaded asynchronously (a filesystem/OPFS scan); treat the
    // loading and error states as "nothing to show" so the banner only appears
    // once a non-zero count resolves.
    final count = ref.watch(charaDetailQuarantineCountProvider).asData?.value ?? 0;
    if (count == 0) {
      return const SizedBox.shrink();
    }
    final quarantineDir = ref.watch(pathInfoProvider).charaDetailQuarantineDir;
    return RecordStoreBanner(
      message: "$tr_chara_detail.quarantine_banner.message".tr(namedArgs: {"count": "$count"}),
      actions: [
        RecordStoreBannerAction(
          label: "$tr_chara_detail.quarantine_banner.refresh".tr(),
          icon: Symbols.refresh_rounded,
          onPressed: () => ref.invalidate(charaDetailQuarantineCountProvider),
        ),
        // Same capability gate as the record context menu: the banner still
        // reports the quarantined count on web, but only platforms with a file
        // manager get the shortcut into the folder.
        if (CurrentPlatform.canRevealInFileManager())
          RecordStoreBannerAction(
            label: "$tr_chara_detail.quarantine_banner.open".tr(),
            icon: Symbols.folder_open_rounded,
            onPressed: () => quarantineDir.launch(),
          ),
      ],
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

  Widget error(Object? errorMessage, Object? stackTrace) {
    return ErrorLogView(title: "$tr_chara_detail.loading_error".tr(), message: errorMessage, stackTrace: stackTrace);
  }

  Widget data(BuildContext context, WidgetRef ref) {
    return Column(
      children: const [
        _QuarantineBannerWidget(),
        // Quarantined and unavailable records are different conditions with
        // different remedies, so they get one banner each rather than a merged
        // count: a quarantined record was moved aside and is inspected in the
        // quarantine folder; an unavailable one is intact, still in place, and
        // is recovered by rescanning or repairing.
        IncompleteStoreBanner(),
        // The archive scan is not awaited by this page, so its whole-store
        // failure would otherwise be invisible while still narrowing every
        // dedup and inheritance decision. Above the table, not instead of it:
        // the active records are loaded and usable.
        ArchiveStoreOutageBanner(),
        TopControlsLayer(),
        SizedBox(height: 8),
        _CharaDetailDataTablePreCheckLayer(),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Blocking, and ahead of the loader: without the cross-tab lock every record
    // read throws, so the loader can only ever reach its error branch and paint a
    // raw English exception in a Japanese UI. Draw nothing rather than pretend the
    // table is loading -- and nothing rather than the banner, for the same reason
    // the startup branch below draws nothing: [RecordLockUnavailableBanner] is
    // already mounted above every page in `app_widget.dart`, so stating it here
    // too would stack two copies of the identical remedy on this one tab. The
    // cause and the way out are not lost; they are simply said once.
    if (ref.watch(recordMutationLockUnavailabilityProvider) != null) {
      return const SizedBox.shrink();
    }
    // A startup outage reaches this loader too (it awaits the path info), but it
    // is stated app-wide by [RecordStoreStartupOutageBanner], which is above this
    // page on every tab. Repeating it here would say the same thing twice and
    // offer a rescan that cannot work: the stores are downstream of the path info
    // that failed, so invalidating them only replays the cached rejection.
    if (ref.watch(pathInfoOutageProvider) != null) {
      return const SizedBox.shrink();
    }
    final loader = ref.watch(charaDetailInitialDataLoader);
    // Same short-circuit, one scope down: the lock exists but the store-wide scan
    // could not list a single record, so this loader can only be in error and its
    // error branch would paint that raw exception. The banner states whether
    // waiting fixes it and carries the rescan. It replaces the table because
    // there is nothing to draw -- exactly what the error branch it displaces did.
    //
    // Read off the loader rather than off the store directly: this page awaits
    // the loader anyway, so watching the store would add a second subscription
    // reporting the same outage. It is no longer a *safety* argument — the scan
    // and the archive geometry migration exclude each other through the root
    // record lock now, not through which provider is read first (see
    // `record_loader_io.dart` and [runArchiveGeometryMigrationIfNeeded]).
    final outage = loader.storeOutage;
    if (outage != null) {
      return Align(
        alignment: Alignment.topCenter,
        child: RecordStoreOutageBanner(outage: outage),
      );
    }
    return loader.when(
      // A background reload of an upstream loader (path/module/record storage)
      // must not tear down the whole table subtree: doing so remounts the grid,
      // resetting its scroll offset and dropping the row selection. Keep showing
      // the existing data across reloads; only the very first load shows the
      // spinner (no previous value to keep).
      skipLoadingOnReload: true,
      loading: () => loading(),
      error: (errorMessage, stackTrace) => error(errorMessage, stackTrace),
      data: (_) => data(context, ref),
    );
  }
}
