import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/exporter.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/providers.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/storage/storage_delete_request.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';
import '/src/gui/storage_tree.dart';

// ignore: constant_identifier_names
const tr_chara_detail = "pages.chara_detail";

final _recordExportEvent = EventStreamProvider<ExportResult>();
final recordExportEventProvider = _recordExportEvent.provider;

/// Output formats offered by [ExportRecordDialog], one per radio entry.
enum ExportFormat { csvShiftJis, csvUtf8Bom, json, zip }

/// Toolbar control that starts an export.
///
/// Like the archive button, it does not act immediately: it engages the bulk
/// row-selection UI ([SelectionPurpose.export]). Once rows are checked the scrim
/// surfaces the format picker ([ExportRecordDialog]). The spinner shown here
/// covers the asynchronous write that follows the picker.
class CharaDetailExportButton extends ConsumerWidget {
  const CharaDetailExportButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Match _PresetActionButton exactly: same horizontal:3 margin and inner
    // IconButton metrics (icon 22, splash 20, 36x36 hit area) so the export
    // control is indistinguishable from the other toolbar icon buttons.
    const buttonSize = 36.0;
    final exporting = ref.watch(exportingStateProvider);
    final hasRecords = ref.watch(displayedRecordsProvider).isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: SizedBox(
        height: buttonSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Disabled(
              disabled: exporting,
              tooltip: "$tr_chara_detail.export.disabled_tooltip".tr(),
              child: IconButton(
                icon: const Icon(Symbols.download_rounded, size: 22),
                tooltip: "$tr_chara_detail.export.button_tooltip".tr(),
                visualDensity: VisualDensity.compact,
                splashRadius: 20,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
                onPressed: hasRecords
                    ? () => ref.read(selectionModeProvider.notifier).set(SelectionPurpose.export)
                    : null,
              ),
            ),
            if (exporting)
              const IgnorePointer(
                child: SizedBox(width: buttonSize, height: buttonSize, child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }
}

/// Format picker shown after rows are selected for export.
///
/// Mirrors [BulkArchiveRecordDialog]: it runs from its own [WidgetRef] (so the
/// asynchronous export survives the scrim being torn down), reports how many
/// records are involved, and lets the user pick one disposition for the whole
/// batch. Export is non-destructive, so a plain confirm replaces the archive
/// dialog's long-press.
class ExportRecordDialog extends ConsumerStatefulWidget {
  final List<String> recordIds;

  const ExportRecordDialog({super.key, required this.recordIds});

  static void show(RefBase ref, {required List<String> recordIds}) {
    CardDialog.show(ref, (_) => ExportRecordDialog(recordIds: recordIds));
  }

  @override
  ConsumerState<ExportRecordDialog> createState() => _ExportRecordDialogState();
}

class _ExportRecordDialogState extends ConsumerState<ExportRecordDialog> {
  ExportFormat _format = ExportFormat.csvShiftJis;

  Exporter _exporterFor(
    ExportFormat format,
    String title,
    Set<String> ids,
    RecordSource source,
    Grid grid,
    RefBase ref,
  ) {
    switch (format) {
      case ExportFormat.csvShiftJis:
        return CsvExporter(title, "records.csv", ref, ids, source, CharCodec.shiftJis, grid);
      case ExportFormat.csvUtf8Bom:
        return CsvExporter(title, "records.csv", ref, ids, source, CharCodec.utf8Bom, grid);
      case ExportFormat.json:
        return JsonExporter(title, "records.json", ref, ids, source);
      case ExportFormat.zip:
        return ZipExporter(title, "records.zip", ref, ids, source);
    }
  }

  void _confirm() {
    final title = "$tr_chara_detail.export.dialog_title".tr();
    final ids = widget.recordIds.toSet();
    final format = _format;
    // Snapshot the source too: clearing selection below makes the source dropdown
    // live again, and the picker/write run later, so the exporter must capture the
    // source now rather than re-read it mid-flight.
    final source = ref.read(recordSourceProvider);
    // Snapshot the grid as well for CSV (which exports the displayed columns/cells
    // rather than raw records). Read it before exitSelection makes the grid live
    // again, so a later source switch cannot redirect the CSV to the other set.
    final grid = ref.read(currentGridProvider);
    // Run the export on the container-scoped ExportRunner rather than this
    // dialog's ref: the directory picker and write outlive the dialog, which is
    // dismissed immediately below. The selection is already snapshotted into the
    // exporter, so clearing it here cannot affect the in-flight write.
    ref
        .read(exportRunnerProvider.notifier)
        .run(
          (rb) => _exporterFor(format, title, ids, source, grid, rb),
          onSuccess: (result) => _recordExportEvent.add(result),
        );
    exitSelection(ref);
    CardDialog.dismiss(ref.base);
  }

  Widget _option(ExportFormat format, String labelKey, String descriptionKey) {
    return RadioListTile<ExportFormat>(value: format, title: Text(labelKey.tr()), subtitle: Text(descriptionKey.tr()));
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.recordIds.length;
    // Watched, not read: a long read can end while this dialog is open, and the
    // confirm has to come back on its own when it does.
    //
    // The source is read rather than watched, and it is the same snapshot
    // [_confirm] takes: the dropdown is inert while the selection this dialog was
    // opened from is live, so there is nothing here for a watch to observe.
    final claims = ref.watch(longReadRegistryProvider).values;
    // Asked over [recordExportLongReadPaths] and no longer over the record ids
    // alone: the desktop zip also reads `modules/labels.json`, and that file
    // belongs to an unlocked group whose writers announce themselves and nothing
    // else. Going through the export's own derivation is what keeps the set this
    // button asks about equal to the set the export claims — the two used to be
    // written separately, and the modules half existed in neither.
    // The layout and not `pathInfoProvider`, the step
    // `_BulkDeleteRecordDialogState.build` explains: an export needs to know
    // where the store is, not that it was successfully prepared, and the second
    // throws while it has not been.
    final layout = ref.read(pathLayoutProvider);
    final awaitingExtraction =
        layout != null &&
        storageDeleteBlockedBy(
              StorageDeletePathsRequest(
                recordExportLongReadPaths(
                  pathInfo: layout,
                  source: ref.read(recordSourceProvider),
                  recordIds: widget.recordIds,
                  isWeb: ref.read(exportIsWebProvider),
                ),
              ),
              claims,
            ) !=
            null;
    return BulkConfirmDialog(
      dismissRef: ref.base,
      dialogTitle: "$tr_chara_detail.export.dialog.title".tr(),
      closeTooltip: "$tr_chara_detail.export.dialog.cancel_button.tooltip".tr(),
      maxWidth: 560,
      // Taller by exactly the card the refusal adds. The four format options and
      // their descriptions already fill the 520, and this dialog has no caution
      // box for the refusal to take the place of the way the archive and delete
      // dialogs do — so the alternative to growing is a body that overflows its
      // own card.
      maxHeight: awaitingExtraction ? 600 : 520,
      message: "$tr_chara_detail.export.dialog.message".tr(namedArgs: {"count": "$count"}),
      bodyExtras: [
        RadioGroup<ExportFormat>(
          groupValue: _format,
          onChanged: (value) => setState(() => _format = value!),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _option(
                ExportFormat.csvShiftJis,
                "$tr_chara_detail.export.csv.label",
                "$tr_chara_detail.export.csv.tooltip",
              ),
              _option(
                ExportFormat.csvUtf8Bom,
                "$tr_chara_detail.export.csv_utf.label",
                "$tr_chara_detail.export.csv_utf.tooltip",
              ),
              _option(ExportFormat.json, "$tr_chara_detail.export.json.label", "$tr_chara_detail.export.json.tooltip"),
              _option(ExportFormat.zip, "$tr_chara_detail.export.zip.label", "$tr_chara_detail.export.zip.tooltip"),
            ],
          ),
        ),
        // Stated as body text and not only as the confirm's tooltip, for the
        // reason the delete dialogs give: a tooltip needs a hover, and the dialog
        // has already taken the whole screen to ask a question that cannot be
        // answered yet.
        if (awaitingExtraction) Center(child: NoteCard(description: Text(longReadBusyMessage()))),
      ],
      cancelLabel: "$tr_chara_detail.export.dialog.cancel_button.label".tr(),
      cancelTooltip: "$tr_chara_detail.export.dialog.cancel_button.tooltip".tr(),
      confirmLabel: "$tr_chara_detail.export.dialog.ok_button.label".tr(),
      confirmTooltip: awaitingExtraction
          ? longReadBusyMessage()
          : "$tr_chara_detail.export.dialog.ok_button.tooltip".tr(),
      confirmIcon: Symbols.download_rounded,
      // Export is non-destructive: confirm on a plain tap, no error palette.
      destructive: false,
      onConfirm: _confirm,
      confirmEnabled: !awaitingExtraction,
      // Not narrowed by the refusal: leaving is the remedy it asks for, so the
      // way out stays open for exactly the window the confirm is shut.
    );
  }
}
