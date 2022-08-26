import 'dart:ui' as ui;

import 'package:collection/collection.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_tag_widget.dart';
import '/src/gui/chara_detail/preview_dialog.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_chara_detail = "pages.chara_detail";

final charaDetailInitialDataLoader = FutureProvider((ref) async {
  return Future.wait([
    ref.watch(pathInfoLoader.future),
  ]).then((_) {
    return Future.wait([
      ref.watch(moduleInfoLoaders.future),
      ref.watch(charaDetailRecordStorageLoader.future),
    ]);
  });
});

extension PlutoGridStateManagerExtension on PlutoGridStateManager {
  void autoFitColumnPrecise(BuildContext context, PlutoColumn column) {
    final values = refRows.map((e) => column.formattedValueForDisplay(e.cells[column.field]?.value));
    final maxWidth = values.toSet().map((value) {
      TextSpan textSpan = TextSpan(
        style: DefaultTextStyle.of(context).style,
        text: value,
      );
      TextPainter textPainter = TextPainter(
        text: textSpan,
        textDirection: ui.TextDirection.ltr,
      );
      textPainter.layout();
      return textPainter.width;
    }).max;

    EdgeInsets cellPadding = column.cellPadding ?? configuration!.style.defaultCellPadding;

    resizeColumn(
      column,
      maxWidth - column.width + (cellPadding.left + cellPadding.right) + 8,
    );
  }

  void autoFitColumns() {
    final context = gridKey!.currentContext!;
    for (final col in columns) {
      final enabled = col.enableDropToResize;
      col.enableDropToResize = true; // If this flag is false, col will ignore any resizing operations.
      autoFitColumnPrecise(context, col);
      if (maxWidth != null && col.width > maxWidth!) {
        resizeColumn(col, -col.width / 2);
      }
      col.enableDropToResize = enabled;
    }
  }

  PlutoColumn? getColumn(String field) {
    return columns.firstWhereOrNull((e) => e.field == field);
  }

  void sortColumn(PlutoColumn col, PlutoColumnSort order) {
    if (order == PlutoColumnSort.ascending) {
      sortAscending(col);
    } else {
      sortDescending(col);
    }
  }

  void sortColumnByField(String columnField, PlutoColumnSort sortOrder) {
    final col = getColumn(columnField);
    if (col != null) {
      sortColumn(col, sortOrder);
    }
  }
}

class _CharaDetailDataTableWidget extends ConsumerStatefulWidget {
  const _CharaDetailDataTableWidget({Key? key}) : super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _CharaDetailDataTableWidgetState();
}

class _CharaDetailDataTableWidgetState extends ConsumerState<_CharaDetailDataTableWidget> {
  String? sortColumn;
  PlutoColumnSort sortOrder = PlutoColumnSort.none;

  void showPopup(BuildContext context, WidgetRef ref, Offset offset, CharaDetailRecord record, int initialPage) {
    final theme = Theme.of(context);
    final storage = ref.read(charaDetailRecordStorageProvider.notifier);
    final rect = offset & const Size(1, 1);
    const height = 40.0;
    final style = theme.textTheme.labelMedium;
    showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(rect.left, rect.top, rect.right, rect.bottom),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      items: [
        PopupMenuItem(
          height: height,
          onTap: () => CharaDetailPreviewDialog.show(ref, record, initialPage),
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
          PlutoGrid(
            // Since PlutoGrid have internal states, it won't rebuilt without changing the key each time.
            key: ValueKey(const Uuid().v4()),
            columns: grid.columns,
            rows: grid.rows,
            mode: PlutoGridMode.select,
            configuration: PlutoGridConfiguration(
              enterKeyAction: PlutoGridEnterKeyAction.none,
              scrollbar: const PlutoGridScrollbarConfig(
                isAlwaysShown: true,
                scrollbarRadius: Radius.circular(8),
                scrollbarRadiusWhileDragging: Radius.circular(8),
                scrollbarThickness: 12,
                scrollbarThicknessWhileDragging: 12,
              ),
              style: PlutoGridStyleConfig(
                enableCellBorderVertical: false,
                gridBackgroundColor: theme.colorScheme.surface,
                rowColor: theme.colorScheme.surface,
                evenRowColor: theme.colorScheme.surfaceVariant,
                activatedColor: theme.focusColor,
                gridBorderColor: theme.colorScheme.outline.withOpacity(0.5),
                borderColor: theme.focusColor,
                activatedBorderColor: theme.focusColor,
                inactivatedBorderColor: theme.focusColor,
                columnTextStyle: theme.textTheme.titleSmall!,
                cellTextStyle: theme.textTheme.bodyMedium!,
              ),
            ),
            onLoaded: (PlutoGridOnLoadedEvent event) {
              event.stateManager.autoFitColumns();
              if (sortColumn != null) {
                event.stateManager.sortColumnByField(sortColumn!, sortOrder);
              }
            },
            onRowSecondaryTap: (PlutoGridOnRowSecondaryTapEvent event) {
              final record = event.row!.getUserData<CharaDetailRecord>()!;
              final spec = event.cell?.column.getUserData();
              showPopup(context, ref, event.offset!, record, spec?.tabIdx ?? 0);
            },
            onSelected: (PlutoGridOnSelectedEvent event) {
              final record = event.row!.getUserData<CharaDetailRecord>()!;
              final spec = event.cell?.column.getUserData();
              CharaDetailPreviewDialog.show(ref, record, spec?.tabIdx ?? 0);
            },
            onSorted: (PlutoGridOnSortedEvent event) {
              if (event.column.sort == PlutoColumnSort.none) {
                sortColumn = null;
                sortOrder = PlutoColumnSort.none;
              } else {
                sortColumn = event.column.field;
                sortOrder = event.column.sort;
              }
            },
          ),
          if (grid.rows.isEmpty) Text("$tr_chara_detail.no_row_message".tr()),
        ],
      ),
    );
  }
}

class _CharaDetailDataTablePreCheckLayer extends ConsumerWidget {
  const _CharaDetailDataTablePreCheckLayer({Key? key}) : super(key: key);

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
    if (ref.watch(currentColumnSpecsProvider).isEmpty) {
      return Expanded(child: ErrorMessageWidget(message: "$tr_chara_detail.no_column_message".tr()));
    }
    return const _CharaDetailDataTableWidget();
  }
}

class CharaDetailDataTableLoaderLayer extends ConsumerWidget {
  const CharaDetailDataTableLoaderLayer({Key? key}) : super(key: key);

  Widget loading() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: const [
          CircularProgressIndicator(),
          SizedBox(height: 8),
          Text("Loading"),
        ],
      ),
    );
  }

  Widget error(errorMessage, stackTrace, theme) {
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
        ColumnSpecTagWidget(),
        SizedBox(height: 8),
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
