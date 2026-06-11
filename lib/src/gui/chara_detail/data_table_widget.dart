import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/providers.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/chara_detail/column_preset_bar_widget.dart';
import '/src/gui/chara_detail/column_spec_tag_widget.dart';
import '/src/gui/chara_detail/delete_record_dialog.dart';
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

  void showPopup(BuildContext context, WidgetRef ref, Offset offset, CharaDetailRecord record, int initialPage) {
    final theme = Theme.of(context);
    final storage = ref.read(charaDetailRecordStorageLoaderProvider.notifier);
    final rect = offset & const Size(1, 1);
    const height = 40.0;
    final style = theme.textTheme.labelMedium;
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
            final directories = records.map((e) => storage.recordPathOf(e)).toList();
            return CharaDetailPreviewDialog.show(ref.base, directories, index);
          },
          child: Text("$tr_chara_detail.context_menu.preview".tr(), style: style),
        ),
        PopupMenuItem(
          height: height,
          onTap: () => storage.copyToClipboard(record, CharaDetailRecordImageMode.skillPlain),
          child: Text("$tr_chara_detail.context_menu.copy_skill".tr(), style: style),
        ),
        PopupMenuItem(
          height: height,
          onTap: () => storage.copyToClipboard(record, CharaDetailRecordImageMode.factorPlain),
          child: Text("$tr_chara_detail.context_menu.copy_factor".tr(), style: style),
        ),
        PopupMenuItem(
          height: height,
          onTap: () => storage.recordPathOf(record).launch(),
          child: Text("$tr_chara_detail.context_menu.open_in_explorer".tr(), style: style),
        ),
        PopupMenuItem(
          height: height,
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
          child: Text("$tr_chara_detail.context_menu.regenerate_record".tr(), style: style),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          height: height,
          onTap: () => DeleteRecordDialog.show(ref.base, recordId: record.id),
          child: Text("$tr_chara_detail.context_menu.delete_record".tr(), style: style),
        ),
        if (isSentryAvailable())
          PopupMenuItem(
            height: height,
            onTap: () => ReportRecordDialog.show(ref.base, storage.recordPathOf(record)),
            child: Text("$tr_chara_detail.context_menu.report_record".tr(), style: style),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grid = ref.watch(currentGridProvider);
    if (grid.columns.isEmpty) {
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
                  // Since TrinaGrid have internal states, it won't rebuilt without changing the key each time.
                  key: ValueKey(const Uuid().v4()),
                  columns: grid.columns,
                  rows: grid.rows,
                  mode: TrinaGridMode.select,
                  // Paint the selected row ourselves so the highlight stays
                  // visible even when the grid loses focus (e.g. the app is
                  // deactivated). TrinaGrid's built-in activatedColor is gated on
                  // hasFocus, so it disappears otherwise. Setting rowColorCallback
                  // overrides the default striping, so reproduce it for other rows.
                  rowColorCallback: (rowContext) {
                    if (rowContext.stateManager.currentRowIdx == rowContext.rowIdx) {
                      return theme.colorScheme.primaryContainer;
                    }
                    return rowContext.rowIdx.isEven ? theme.colorScheme.surface : theme.colorScheme.stripedRowColor;
                  },
                  configuration: TrinaGridConfiguration(
                    enterKeyAction: TrinaGridEnterKeyAction.toggleEditing,
                    scrollbar: const TrinaGridScrollbarConfig(isAlwaysShown: true, radius: 8, thickness: 12),
                    style: TrinaGridStyleConfig(
                      enableCellBorderVertical: false,
                      gridBackgroundColor: Colors.transparent,
                      // Not the per-row striping (rowColorCallback overrides that),
                      // but the body background painted behind/around the rows,
                      // e.g. the empty space right of the last column. Without it
                      // this falls back to TrinaGrid's default Colors.white.
                      rowColor: theme.colorScheme.surface,
                      activatedColor: theme.colorScheme.primaryContainer,
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
                    event.stateManager.autoFitColumns();
                    if (sortColumn != null) {
                      event.stateManager.sortColumnByField(sortColumn!, sortOrder);
                    }
                  },
                  onRowSecondaryTap: (TrinaGridOnRowSecondaryTapEvent event) {
                    final record = event.row.getUserData<CharaDetailRecord>()!;
                    final spec = event.cell.column.getUserData<ColumnSpec>();
                    showPopup(context, ref, event.offset, record, spec!.cellAction?.tabIdx ?? 0);
                  },
                  onSelected: (TrinaGridOnSelectedEvent event) {
                    try {
                      final data = event.cell?.getUserData<CellData>();
                      if (!(data?.onSelected?.call(event) ?? false)) {
                        final storage = ref.read(charaDetailRecordStorageLoaderProvider.notifier);
                        final records = stateManager.getSortedRecords().map((e) => storage.recordPathOf(e)).toList();
                        CharaDetailPreviewDialog.show(ref.base, records, event.rowIdx!);
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

class _CharaDetailDataTablePreCheckLayer extends ConsumerWidget {
  const _CharaDetailDataTablePreCheckLayer();

  Widget regenerationProgressWidget(BuildContext context, Progress regenerationProgress) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CircularPercentIndicator(
            radius: 32.0,
            lineWidth: 6.0,
            animation: true,
            animateFromLastPercent: true,
            animationDuration: 200,
            percent: regenerationProgress.progress,
            center: Text("${regenerationProgress.percent}%"),
            footer: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text("$tr_chara_detail.regenerating_message".tr()),
            ),
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
      return regenerationProgressWidget(context, regenerationProgress);
    }
    if (ref.watch(charaDetailRecordStorageProvider).isEmpty) {
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
              Icon(Icons.warning_amber_rounded, color: theme.colorScheme.onErrorContainer),
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
                icon: const Icon(Icons.refresh),
                label: Text("$tr_chara_detail.quarantine_banner.refresh".tr()),
                style: buttonStyle,
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () => quarantineDir.launch(),
                icon: const Icon(Icons.folder_open),
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
        ColumnPresetBarWidget(),
        ColumnSpecTagWidget(),
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
      loading: () => loading(),
      error: (errorMessage, stackTrace) => error(errorMessage, stackTrace, theme),
      data: (_) => data(context, ref),
    );
  }
}
