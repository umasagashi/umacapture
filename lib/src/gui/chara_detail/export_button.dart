import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/exporter.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_chara_detail = "pages.chara_detail";

final _recordExportEvent = EventStreamProvider<PathEntity>();
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
/// Mirrors [ArchiveRecordDialog]: it runs from its own [WidgetRef] (so the
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

  Exporter _exporterFor(ExportFormat format, String title, Set<String> ids, RefBase ref) {
    switch (format) {
      case ExportFormat.csvShiftJis:
        return CsvExporter(title, "records.csv", ref, ids, CharCodec.shiftJis);
      case ExportFormat.csvUtf8Bom:
        return CsvExporter(title, "records.csv", ref, ids, CharCodec.utf8Bom);
      case ExportFormat.json:
        return JsonExporter(title, "records.json", ref, ids);
      case ExportFormat.zip:
        return ZipExporter(title, "records.zip", ref, ids);
    }
  }

  void _confirm() {
    final title = "$tr_chara_detail.export.dialog_title".tr();
    final ids = widget.recordIds.toSet();
    final format = _format;
    // Run the export on the container-scoped ExportRunner rather than this
    // dialog's ref: the directory picker and write outlive the dialog, which is
    // dismissed immediately below. The selection is already snapshotted into the
    // exporter, so clearing it here cannot affect the in-flight write.
    ref
        .read(exportRunnerProvider.notifier)
        .run((rb) => _exporterFor(format, title, ids, rb), onSuccess: (path) => _recordExportEvent.add(path));
    ref.read(selectionModeProvider.notifier).set(null);
    ref.read(selectedRecordIdsProvider.notifier).set(<String>{});
    CardDialog.dismiss(ref.base);
  }

  Widget _option(ExportFormat format, String labelKey, String descriptionKey) {
    return RadioListTile<ExportFormat>(value: format, title: Text(labelKey.tr()), subtitle: Text(descriptionKey.tr()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = widget.recordIds.length;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
      child: CardDialog(
        dialogTitle: "$tr_chara_detail.export.dialog.title".tr(),
        closeButtonTooltip: "$tr_chara_detail.export.dialog.cancel_button.tooltip".tr(),
        usePageView: false,
        content: Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  "$tr_chara_detail.export.dialog.message".tr(namedArgs: {"count": "$count"}),
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
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
                      _option(
                        ExportFormat.json,
                        "$tr_chara_detail.export.json.label",
                        "$tr_chara_detail.export.json.tooltip",
                      ),
                      _option(
                        ExportFormat.zip,
                        "$tr_chara_detail.export.zip.label",
                        "$tr_chara_detail.export.zip.tooltip",
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        bottom: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Tooltip(
              message: "$tr_chara_detail.export.dialog.cancel_button.tooltip".tr(),
              child: OutlinedButton.icon(
                icon: const Icon(Symbols.cancel_rounded),
                label: Text("$tr_chara_detail.export.dialog.cancel_button.label".tr()),
                onPressed: () => CardDialog.dismiss(ref.base),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: "$tr_chara_detail.export.dialog.ok_button.tooltip".tr(),
              child: FilledButton.icon(
                icon: const Icon(Symbols.download_rounded),
                label: Text("$tr_chara_detail.export.dialog.ok_button.label".tr()),
                onPressed: _confirm,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
