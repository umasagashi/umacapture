import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/storage.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';
import '/src/gui/record_image.dart';

// ignore: constant_identifier_names
const tr_archive_record = "pages.chara_detail.archive_records";

/// Bulk-archive confirmation dialog, the selection-flow counterpart of
/// [ArchiveRecordDialog].
///
/// Shows how many records will be archived and lets the user pick the image
/// disposition ([ArchiveImageOption]) for the whole batch. Archiving is
/// destructive (re-recognition is lost), so confirmation is a long-press, like
/// the bulk delete dialog. Reports a count rather than a single record's icon.
class BulkArchiveRecordDialog extends ConsumerStatefulWidget {
  final List<String> recordIds;

  const BulkArchiveRecordDialog({super.key, required this.recordIds});

  static void show(RefBase ref, {required List<String> recordIds}) {
    CardDialog.show(ref, (_) => BulkArchiveRecordDialog(recordIds: recordIds));
  }

  @override
  ConsumerState<BulkArchiveRecordDialog> createState() => _BulkArchiveRecordDialogState();
}

class _BulkArchiveRecordDialogState extends ConsumerState<BulkArchiveRecordDialog> {
  // Starts unselected so the user must deliberately pick an image disposition;
  // the confirm button stays disabled until then.
  ArchiveImageOption? _option;

  void _confirm() {
    ref.read(charaArchiveControllerProvider.notifier).archive(widget.recordIds, _option!);
    // The grid rebuilds without these rows; leave selection mode so the
    // checkbox column disappears and stale checks are dropped.
    exitSelection(ref);
    CardDialog.dismiss(ref.base);
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.recordIds.length;
    return BulkConfirmDialog(
      dismissRef: ref.base,
      dialogTitle: "$tr_archive_record.dialog.title".tr(),
      closeTooltip: "$tr_archive_record.dialog.cancel_button.tooltip".tr(),
      maxWidth: 500,
      maxHeight: 420,
      message: "$tr_archive_record.dialog.message".tr(namedArgs: {"count": "$count"}),
      bodyExtras: [
        RadioGroup<ArchiveImageOption>(
          groupValue: _option,
          onChanged: (value) => setState(() => _option = value!),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<ArchiveImageOption>(
                value: ArchiveImageOption.resizedJpeg,
                title: Text("$tr_archive_record.dialog.option.resized_jpeg.label".tr()),
                subtitle: Text("$tr_archive_record.dialog.option.resized_jpeg.description".tr()),
              ),
              RadioListTile<ArchiveImageOption>(
                value: ArchiveImageOption.none,
                title: Text("$tr_archive_record.dialog.option.none.label".tr()),
                subtitle: Text("$tr_archive_record.dialog.option.none.description".tr()),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Centered caution box hugging its content instead of spanning the full
        // (stretched) width.
        Center(child: WarningCard(message: "$tr_archive_record.dialog.description".tr())),
      ],
      cancelLabel: "$tr_archive_record.dialog.cancel_button.label".tr(),
      cancelTooltip: "$tr_archive_record.dialog.cancel_button.tooltip".tr(),
      confirmLabel: "$tr_archive_record.dialog.ok_button.label".tr(),
      confirmTooltip: "$tr_archive_record.dialog.ok_button.tooltip".tr(),
      confirmIcon: Symbols.archive_rounded,
      destructive: true,
      onConfirm: _confirm,
      confirmEnabled: _option != null,
    );
  }
}

/// Single-record archive confirmation dialog, the context-menu counterpart of
/// [BulkArchiveRecordDialog].
///
/// Mirrors [DeleteRecordDialog]'s layout — the trainee icon and evaluation value
/// of the target record — so archiving one record from the row context menu
/// looks and reads like deleting one. It still exposes the image disposition
/// ([ArchiveImageOption]) that archiving requires.
class ArchiveRecordDialog extends ConsumerStatefulWidget {
  final String recordId;
  final RecordSource source;

  const ArchiveRecordDialog({super.key, required this.recordId, this.source = RecordSource.active});

  static void show(RefBase ref, {required String recordId, RecordSource source = RecordSource.active}) {
    CardDialog.show(ref, (_) => ArchiveRecordDialog(recordId: recordId, source: source));
  }

  @override
  ConsumerState<ArchiveRecordDialog> createState() => _ArchiveRecordDialogState();
}

class _ArchiveRecordDialogState extends ConsumerState<ArchiveRecordDialog> {
  // Starts unselected so the user must deliberately pick an image disposition;
  // the confirm button stays disabled until then.
  ArchiveImageOption? _option;

  void _confirm() {
    ref.read(charaArchiveControllerProvider.notifier).archive([widget.recordId], _option!);
    CardDialog.dismiss(ref.base);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final record = recordStorageFor(ref, widget.source).getBy(id: widget.recordId);
    if (record == null) {
      return dismissForMissingRecord(ref.base);
    }
    final iconPath = traineeIconPathIn(recordDirOf(ref.read(pathInfoProvider), widget.source, record));
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 500, maxHeight: 560),
      child: CardDialog(
        dialogTitle: "$tr_archive_record.dialog.title".tr(),
        closeButtonTooltip: "$tr_archive_record.dialog.cancel_button.tooltip".tr(),
        usePageView: false,
        content: Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 140),
                child: RecordImage(
                  iconPath,
                  // The trainee icon is normally always present, but guard against a
                  // missing/corrupt file (e.g. a hand-edited archive) so the dialog
                  // shows a placeholder instead of a red error box.
                  errorBuilder: (context, error, stackTrace) =>
                      Icon(Symbols.hide_image_rounded, size: 64, color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              Text(record.evaluationValueLabel, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              RadioGroup<ArchiveImageOption>(
                groupValue: _option,
                onChanged: (value) => setState(() => _option = value!),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<ArchiveImageOption>(
                      value: ArchiveImageOption.resizedJpeg,
                      title: Text("$tr_archive_record.dialog.option.resized_jpeg.label".tr()),
                      subtitle: Text("$tr_archive_record.dialog.option.resized_jpeg.description".tr()),
                    ),
                    RadioListTile<ArchiveImageOption>(
                      value: ArchiveImageOption.none,
                      title: Text("$tr_archive_record.dialog.option.none.label".tr()),
                      subtitle: Text("$tr_archive_record.dialog.option.none.description".tr()),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Center(child: WarningCard(message: "$tr_archive_record.dialog.description".tr())),
            ],
          ),
        ),
        bottom: ConfirmActionRow(
          dismissRef: ref.base,
          cancelLabel: "$tr_archive_record.dialog.cancel_button.label".tr(),
          cancelTooltip: "$tr_archive_record.dialog.cancel_button.tooltip".tr(),
          confirmLabel: "$tr_archive_record.dialog.ok_button.label".tr(),
          confirmTooltip: "$tr_archive_record.dialog.ok_button.tooltip".tr(),
          confirmIcon: Symbols.archive_rounded,
          destructive: true,
          onConfirm: _confirm,
          enabled: _option != null,
        ),
      ),
    );
  }
}
