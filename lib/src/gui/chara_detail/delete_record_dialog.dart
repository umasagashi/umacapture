import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/storage.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_delete_record = "pages.chara_detail.delete_record";

/// Bulk-delete confirmation dialog, the selection-flow counterpart of
/// [DeleteRecordDialog].
///
/// Reached from the selection scrim after rows are checked. Like the single
/// dialog it gates the destructive action behind a long-press; like the archive
/// dialog it reports a count rather than a single record's icon.
class BulkDeleteRecordDialog extends ConsumerWidget {
  final List<String> recordIds;
  final RecordSource source;

  const BulkDeleteRecordDialog({super.key, required this.recordIds, required this.source});

  static void show(RefBase ref, {required List<String> recordIds, required RecordSource source}) {
    CardDialog.show(ref, (_) => BulkDeleteRecordDialog(recordIds: recordIds, source: source));
  }

  void _confirm(WidgetRef ref) {
    recordStorageFor(ref, source).deleteAll(recordIds);
    // The rows are gone; leave selection mode so the checkbox column disappears
    // and stale checks are dropped.
    exitSelection(ref);
    CardDialog.dismiss(ref.base);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = recordIds.length;
    return BulkConfirmDialog(
      dismissRef: ref.base,
      dialogTitle: "$tr_delete_record.bulk.title".tr(),
      closeTooltip: "$tr_delete_record.bulk.cancel_button.tooltip".tr(),
      maxWidth: 500,
      maxHeight: 360,
      message: "$tr_delete_record.bulk.message".tr(namedArgs: {"count": "$count"}),
      bodyExtras: [Center(child: WarningCard(message: "$tr_delete_record.bulk.description".tr()))],
      cancelLabel: "$tr_delete_record.bulk.cancel_button.label".tr(),
      cancelTooltip: "$tr_delete_record.bulk.cancel_button.tooltip".tr(),
      confirmLabel: "$tr_delete_record.bulk.ok_button.label".tr(),
      confirmTooltip: "$tr_delete_record.bulk.ok_button.tooltip".tr(),
      confirmIcon: Symbols.delete_rounded,
      destructive: true,
      onConfirm: () => _confirm(ref),
    );
  }
}

class DeleteRecordDialog extends ConsumerWidget {
  final String recordId;
  final RecordSource source;

  const DeleteRecordDialog({super.key, required this.recordId, this.source = RecordSource.active});

  static void show(RefBase ref, {required String recordId, RecordSource source = RecordSource.active}) {
    CardDialog.show(ref, (_) {
      return DeleteRecordDialog(recordId: recordId, source: source);
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final record = recordStorageFor(ref, source).getBy(id: recordId);
    if (record == null) {
      return dismissForMissingRecord(ref.base);
    }
    final iconPath = traineeIconPathIn(recordDirOf(ref.read(pathInfoProvider), source, record));
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 500, maxHeight: 400),
      child: CardDialog(
        dialogTitle: "$tr_delete_record.dialog.title".tr(),
        closeButtonTooltip: "$tr_delete_record.dialog.close_button.tooltip".tr(),
        usePageView: false,
        content: Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.file(
                iconPath.toFile(),
                // The trainee icon is normally always present, but guard against a
                // missing/corrupt file (e.g. a hand-edited archive) so the dialog
                // shows a placeholder instead of a red error box.
                errorBuilder: (context, error, stackTrace) =>
                    Icon(Symbols.hide_image_rounded, size: 64, color: theme.colorScheme.onSurfaceVariant),
              ),
              Text(record.evaluationValue.toNumberString(), style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              WarningCard(message: "$tr_delete_record.dialog.description".tr()),
            ],
          ),
        ),
        bottom: ConfirmActionRow(
          dismissRef: ref.base,
          cancelLabel: "$tr_delete_record.dialog.cancel_button.label".tr(),
          cancelTooltip: "$tr_delete_record.dialog.cancel_button.tooltip".tr(),
          confirmLabel: "$tr_delete_record.dialog.ok_button.label".tr(),
          confirmTooltip: "$tr_delete_record.dialog.ok_button.tooltip".tr(),
          confirmIcon: Symbols.delete_rounded,
          destructive: true,
          onConfirm: () {
            recordStorageFor(ref, source).delete(recordId);
            CardDialog.dismiss(ref.base);
          },
        ),
      ),
    );
  }
}
