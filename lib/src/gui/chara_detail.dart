import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:badges/badges.dart';
import "package:collection/collection.dart";
import 'package:easy_localization/easy_localization.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:recase/recase.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '/src/app/providers.dart';
import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/exporter.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/builder.dart';
import '/src/chara_detail/spec/skill.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/utils.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_chara_detail = "pages.chara_detail";

StreamController<String> _recordExportEventController = StreamController();
final recordExportEventProvider = StreamProvider<String>((ref) {
  if (_recordExportEventController.hasListener) {
    _recordExportEventController = StreamController();
  }
  return _recordExportEventController.stream;
});

class _Dialog extends ConsumerWidget {
  static void show(BuildContext context, Widget dialog) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: dialog,
        );
      },
    );
  }

  final String dialogTitle;
  final String closeButtonTooltip;
  final Widget content;
  final Widget? bottom;
  final bool usePageView;

  const _Dialog({
    required this.dialogTitle,
    required this.closeButtonTooltip,
    required this.content,
    this.bottom,
    this.usePageView = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          ListTile(
            tileColor: theme.colorScheme.primary,
            shape: Border(bottom: BorderSide(color: theme.dividerColor)),
            title: Text(
              dialogTitle,
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.onPrimary,
              ),
            ),
            trailing: Tooltip(
              message: closeButtonTooltip,
              child: IconButton(
                icon: Icon(Icons.close, color: theme.colorScheme.onPrimary),
                splashRadius: 24,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
          if (usePageView)
            Expanded(
              child: SingleChildScrollView(
                controller: ScrollController(),
                padding: const EdgeInsets.all(8),
                child: content,
              ),
            ),
          if (!usePageView) content,
          if (bottom != null)
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: theme.dividerColor)),
              ),
              padding: const EdgeInsets.all(8),
              child: bottom,
            ),
        ],
      ),
    );
  }
}

class _ColumnBuilderDialog extends ConsumerWidget {
  static void show(BuildContext context) {
    _Dialog.show(context, _ColumnBuilderDialog());
  }

  Widget chipWidget(BuildContext context, WidgetRef ref, List<ColumnBuilder> targets) {
    return Align(
      alignment: Alignment.topLeft,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final builder in targets)
            GestureDetector(
              onLongPress: () {
                Navigator.of(context).pop();
                _ColumnSpecDialog.show(context, builder.build());
              },
              child: ActionChip(
                label: Text(builder.title),
                onPressed: () {
                  ref.read(currentColumnSpecsProvider.notifier).replaceById(builder.build());
                  Navigator.of(context).pop();
                },
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final builders = ref.watch(columnBuilderProvider);
    final buildersMap = groupBy<ColumnBuilder, ColumnCategory>(builders, (b) => b.category);
    return _Dialog(
      dialogTitle: "$tr_chara_detail.column_spec.dialog.title".tr(),
      closeButtonTooltip: "$tr_chara_detail.column_spec.dialog.close_button.tooltip".tr(),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withOpacity(0.2),
                border: Border.all(color: theme.colorScheme.primaryContainer),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(8),
              child: Text("$tr_chara_detail.column_spec.dialog.description".tr()),
            ),
          ),
          for (final cat in ColumnCategory.values) ...[
            Row(
              children: [
                Text("$tr_chara_detail.column_category.${cat.name.snakeCase}".tr()),
                const Expanded(child: Divider(indent: 8)),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: chipWidget(context, ref, buildersMap[cat] ?? []),
            ),
          ],
        ],
      ),
    );
  }
}

class _ColumnSpecDialog extends ConsumerStatefulWidget {
  final ColumnSpec originalSpec;

  const _ColumnSpecDialog(ColumnSpec spec) : originalSpec = spec;

  static void show(BuildContext context, ColumnSpec spec) {
    _Dialog.show(context, _ColumnSpecDialog(spec));
  }

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _ColumnSpecDialogState();
}

class _ColumnSpecDialogState extends ConsumerState<_ColumnSpecDialog> {
  late ColumnSpec spec;

  @override
  void initState() {
    super.initState();
    setState(() => spec = widget.originalSpec);
  }

  @override
  Widget build(BuildContext context) {
    final resource = ref.watch(buildResourceProvider);
    return _Dialog(
      dialogTitle: "$tr_chara_detail.column_predicate.dialog.title".tr(),
      closeButtonTooltip: "$tr_chara_detail.column_predicate.dialog.close_button.tooltip".tr(),
      content: spec.selector(
        resource: resource,
        onChanged: (newSpec) => setState(() => spec = newSpec),
      ),
      bottom: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Tooltip(
            message: "$tr_chara_detail.column_predicate.dialog.delete_button.tooltip".tr(),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.delete_forever),
              label: Text("$tr_chara_detail.column_predicate.dialog.delete_button.label".tr()),
              onPressed: () {
                ref.read(currentColumnSpecsProvider.notifier).removeIfExists(widget.originalSpec);
                Navigator.of(context).pop();
              },
            ),
          ),
          Tooltip(
            message: "$tr_chara_detail.column_predicate.dialog.ok_button.tooltip".tr(),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.check_circle),
              label: Text("$tr_chara_detail.column_predicate.dialog.ok_button.label".tr()),
              onPressed: () {
                ref.read(currentColumnSpecsProvider.notifier).replaceById(spec);
                Navigator.of(context).pop();
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CharaDetailExportButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelLarge;
    const menuHeight = 40.0;
    const buttonSize = 30.0;
    const encoding = "Shift_JIS";
    final exporting = ref.watch(exportingStateProvider);
    return SizedBox(
      height: buttonSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Disabled(
            disabled: exporting,
            child: PopupMenuButton<int>(
              enabled: ref.watch(charaDetailRecordStorageProvider).isNotEmpty,
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.download),
              tooltip: "$tr_chara_detail.export.button_tooltip".tr(),
              splashRadius: 24,
              position: PopupMenuPosition.under,
              shape: RoundedRectangleBorder(
                side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.5)),
                borderRadius: BorderRadius.circular(8),
              ),
              itemBuilder: (BuildContext context) {
                final title = "$tr_chara_detail.export.dialog_title".tr();
                return [
                  PopupMenuItem(
                    height: menuHeight,
                    onTap: () {
                      CsvExporter(title, "records.csv", ref, encoding).export(onSuccess: (path) {
                        _recordExportEventController.sink.add(path);
                      });
                    },
                    child: Tooltip(
                      message: "$tr_chara_detail.export.csv.tooltip".tr(),
                      child: Text("$tr_chara_detail.export.csv.label".tr(), style: style),
                    ),
                  ),
                  PopupMenuItem(
                    height: menuHeight,
                    onTap: () {
                      JsonExporter(title, "records.json", ref).export(onSuccess: (path) {
                        _recordExportEventController.sink.add(path);
                      });
                    },
                    child: Tooltip(
                      message: "$tr_chara_detail.export.json.tooltip".tr(),
                      child: Text("$tr_chara_detail.export.json.label".tr(), style: style),
                    ),
                  ),
                  PopupMenuItem(
                    height: menuHeight,
                    onTap: () {
                      ZipExporter(title, "records.zip", ref).export(onSuccess: (path) {
                        _recordExportEventController.sink.add(path);
                      });
                    },
                    child: Tooltip(
                      message: "$tr_chara_detail.export.zip.tooltip".tr(),
                      child: Text("$tr_chara_detail.export.zip.label".tr(), style: style),
                    ),
                  ),
                ];
              },
            ),
          ),
          if (exporting)
            const SizedBox(
              width: buttonSize,
              height: buttonSize,
              child: CircularProgressIndicator(),
            ),
        ],
      ),
    );
  }
}

class _ColumnSpecTagWidget extends ConsumerStatefulWidget {
  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _ColumnSpecTagWidgetState();
}

class _ColumnSpecTagWidgetState extends ConsumerState<_ColumnSpecTagWidget> {
  ColumnSpec? hoveredSpec;

  Widget buildSpecChip(BuildContext context, BuildResource resource, ColumnSpec spec, int? count) {
    final theme = Theme.of(context);
    return DragTarget<ColumnSpec>(
      builder: (context, candidateData, rejectedData) {
        return Draggable<ColumnSpec>(
          data: spec,
          feedback: Material(
            color: Colors.transparent,
            child: Opacity(
              opacity: 0.6,
              child: Chip(
                label: spec.tag(resource),
              ),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.6,
            child: Chip(label: spec.tag(resource)),
          ),
          child: Badge(
            showBadge: count != null,
            badgeColor: theme.chipTheme.selectedColor!,
            position: BadgePosition.topEnd(top: -8, end: -8),
            shape: BadgeShape.square,
            borderRadius: BorderRadius.circular(8),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            alignment: Alignment.center,
            ignorePointer: true,
            badgeContent: Text(
              "$count",
              style: theme.textTheme.labelSmall,
              textAlign: TextAlign.center,
            ),
            child: ActionChip(
              label: spec.tag(resource),
              tooltip: spec.description,
              backgroundColor: spec == hoveredSpec ? theme.colorScheme.secondaryContainer.darken(10) : null,
              onPressed: () {
                _ColumnSpecDialog.show(context, spec);
              },
            ),
          ),
        );
      },
      onWillAccept: (data) {
        setState(() => hoveredSpec = spec);
        return true;
      },
      onLeave: (data) {
        setState(() => hoveredSpec = null);
      },
      onAccept: (dropped) {
        ref.read(currentColumnSpecsProvider.notifier).moveTo(dropped, spec);
        setState(() => hoveredSpec = null);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recordCount = ref.watch(charaDetailRecordStorageProvider).length;
    final specs = ref.watch(currentColumnSpecsProvider);
    final resource = ref.watch(buildResourceProvider);
    final filteredCounts = ref.watch(currentGridProvider).filteredCounts;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Stack(
        alignment: Alignment.bottomRight,
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final col in zip2(specs, filteredCounts))
                  buildSpecChip(context, resource, col.item1, col.item2 == recordCount ? null : col.item2),
                ActionChip(
                  label: Icon(Icons.add, color: theme.colorScheme.onPrimary),
                  tooltip: "$tr_chara_detail.add_column_button_tooltip".tr(),
                  backgroundColor: theme.colorScheme.primary,
                  shape: const CircleBorder().copyWith(side: theme.chipTheme.shape?.side),
                  side: BorderSide.none,
                  labelPadding: EdgeInsets.zero,
                  onPressed: () {
                    _ColumnBuilderDialog.show(context);
                  },
                ),
                const Opacity(
                  // Spacing widget for export button.
                  opacity: 0,
                  child: Chip(
                    padding: EdgeInsets.zero,
                    label: SizedBox(width: 16),
                  ),
                ),
              ],
            ),
          ),
          _CharaDetailExportButton(),
        ],
      ),
    );
  }
}

class _CharaDetailPreviewDialog extends ConsumerStatefulWidget {
  final CharaDetailRecord record;

  const _CharaDetailPreviewDialog(this.record);

  static void show(BuildContext context, CharaDetailRecord record) {
    Future.delayed(Duration.zero, () {
      _Dialog.show(context, _CharaDetailPreviewDialog(record));
    });
  }

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _CharaDetailPreviewDialogState();
}

class _CharaDetailPreviewDialogState extends ConsumerState<_CharaDetailPreviewDialog> {
  late ExtendedPageController controller;

  int get page => controller.page!.round();

  void moveTo(int page) {
    controller.animateToPage(page, duration: const Duration(milliseconds: 200), curve: Curves.easeInOut);
  }

  void prev() {
    if (page > 0) {
      moveTo(page - 1);
    }
  }

  void next() {
    if (page < 2) {
      moveTo(page + 1);
    }
  }

  @override
  void initState() {
    super.initState();
    setState(() {
      controller = ExtendedPageController(initialPage: 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    return _Dialog(
      dialogTitle: "$tr_chara_detail.preview.dialog.title".tr(),
      closeButtonTooltip: "$tr_chara_detail.preview.dialog.close_button.tooltip".tr(),
      usePageView: false,
      content: Expanded(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.all(4),
              child: ExtendedImageGesturePageView.builder(
                itemBuilder: (BuildContext context, int index) {
                  final storage = ref.read(charaDetailRecordStorageProvider.notifier);
                  final imageMode = CharaDetailRecordImageMode.values[index + 1];
                  return LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints constraints) {
                      return GestureDetector(
                        onSecondaryTap: () => Navigator.of(context).pop(),
                        child: ExtendedImage.file(
                          File(storage.imagePathOf(widget.record, imageMode)),
                          filterQuality: FilterQuality.medium,
                          fit: BoxFit.contain,
                          mode: ExtendedImageMode.gesture,
                          onDoubleTap: (_) => storage.copyToClipboard(widget.record, imageMode),
                          initGestureConfigHandler: (ExtendedImageState state) {
                            final h = state.extendedImageInfo!.image.width / constraints.maxWidth;
                            final v = state.extendedImageInfo!.image.height / constraints.maxHeight;
                            final r = math.max(h, v);
                            const f = 0.95;
                            return GestureConfig(
                              maxScale: (r / h) * f,
                              initialScale: r,
                              minScale: math.min(f, r * f),
                              initialAlignment: InitialAlignment.topCenter,
                              reverseMousePointerScrollDirection: true,
                            );
                          },
                        ),
                      );
                    },
                  );
                },
                itemCount: 3,
                controller: controller,
                scrollDirection: Axis.horizontal,
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_left),
                  splashColor: Colors.transparent,
                  hoverColor: Colors.transparent,
                  focusColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                  onPressed: prev,
                ),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_right),
                  splashColor: Colors.transparent,
                  hoverColor: Colors.transparent,
                  focusColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                  onPressed: next,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

extension PlutoGridStateManagerExtension on PlutoGridStateManager {
  void autoFitColumns() {
    final context = gridKey!.currentContext!;
    for (final col in columns) {
      final enabled = col.enableDropToResize;
      col.enableDropToResize = true; // If this flag is false, col will ignore any resizing operations.
      autoFitColumn(context, col);
      col.enableDropToResize = enabled;
    }
  }
}

class _CharaDetailDataTableWidget extends ConsumerWidget {
  void showPopup(BuildContext context, WidgetRef ref, Offset offset, CharaDetailRecord record) {
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
          onTap: () => _CharaDetailPreviewDialog.show(context, record),
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
          onTap: () => launchUrl(Uri.file(storage.recordPathOf(record))),
          child: Text("$tr_chara_detail.context_menu.open_in_explorer".tr(), style: style),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final grid = ref.watch(currentGridProvider);
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
              enterKeyAction: PlutoGridEnterKeyAction.none,
            ),
            onLoaded: (PlutoGridOnLoadedEvent event) {
              event.stateManager.autoFitColumns();
            },
            onRowSecondaryTap: (PlutoGridOnRowSecondaryTapEvent event) {
              final record = event.row!.getUserData<CharaDetailRecord>()!;
              showPopup(context, ref, event.offset!, record);
            },
            onSelected: (PlutoGridOnSelectedEvent event) {
              final record = event.row!.getUserData<CharaDetailRecord>()!;
              _CharaDetailPreviewDialog.show(context, record);
            },
          ),
          if (grid.rows.isEmpty) Text("$tr_chara_detail.no_row_message".tr()),
        ],
      ),
    );
  }
}

class _CharaDetailDataTablePreCheckLayer extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(charaDetailRecordStorageProvider).isEmpty) {
      return Expanded(child: ErrorMessageWidget(message: "$tr_chara_detail.no_record_message".tr()));
    }
    if (ref.watch(currentColumnSpecsProvider).isEmpty) {
      return Expanded(child: ErrorMessageWidget(message: "$tr_chara_detail.no_column_message".tr()));
    }
    return _CharaDetailDataTableWidget();
  }
}

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

class _CharaDetailDataTableLoaderLayer extends ConsumerWidget {
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
      children: [
        _ColumnSpecTagWidget(),
        const SizedBox(height: 8),
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

class CharaDetailPage extends ConsumerWidget {
  const CharaDetailPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleTilePageRootWidget(
      child: _CharaDetailDataTableLoaderLayer(),
    );
  }
}
