import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/storage.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_archive_record = "pages.chara_detail.archive_records";

/// Bulk-archive confirmation dialog.
///
/// Shows how many records will be archived and lets the user pick the image
/// disposition ([ArchiveImageOption]) for the whole batch. Archiving is
/// destructive (re-recognition is lost), so confirmation is a long-press, like
/// the delete dialog.
class ArchiveRecordDialog extends ConsumerStatefulWidget {
  final List<String> recordIds;

  const ArchiveRecordDialog({super.key, required this.recordIds});

  static void show(RefBase ref, {required List<String> recordIds}) {
    CardDialog.show(ref, (_) => ArchiveRecordDialog(recordIds: recordIds));
  }

  @override
  ConsumerState<ArchiveRecordDialog> createState() => _ArchiveRecordDialogState();
}

class _ArchiveRecordDialogState extends ConsumerState<ArchiveRecordDialog> {
  ArchiveImageOption _option = ArchiveImageOption.resizedJpeg;

  void _confirm() {
    ref.read(charaArchiveControllerProvider.notifier).archive(widget.recordIds, _option);
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
    );
  }
}
