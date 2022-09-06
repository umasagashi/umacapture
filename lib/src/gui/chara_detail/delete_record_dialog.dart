import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/storage.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_delete_record = "pages.chara_detail.delete_record";

class DeleteRecordDialog extends ConsumerWidget {
  final String recordId;

  const DeleteRecordDialog({
    Key? key,
    required this.recordId,
  }) : super(key: key);

  static void show(RefBase ref, {required String recordId}) {
    CardDialog.show(ref, (_) {
      return DeleteRecordDialog(recordId: recordId);
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final storage = ref.read(charaDetailRecordStorageProvider.notifier);
    final record = storage.getBy(id: recordId)!;
    final iconPath = storage.traineeIconPathOf(record);
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: 500,
        maxHeight: 400,
      ),
      child: CardDialog(
        dialogTitle: "$tr_delete_record.dialog.title".tr(),
        closeButtonTooltip: "$tr_delete_record.dialog.close_button.tooltip".tr(),
        usePageView: false,
        content: Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.file(iconPath.toFile()),
              Text(record.evaluationValue.toNumberString(), style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              NoteCard(
                description: Text("$tr_delete_record.dialog.description".tr()),
                color: theme.colorScheme.error,
              ),
            ],
          ),
        ),
        bottom: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Tooltip(
              message: "$tr_delete_record.dialog.cancel_button.tooltip".tr(),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.cancel),
                label: Text("$tr_delete_record.dialog.cancel_button.label".tr()),
                onPressed: () {
                  CardDialog.dismiss(ref.base);
                },
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: "$tr_delete_record.dialog.ok_button.tooltip".tr(),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  primary: theme.colorScheme.error,
                  onPrimary: theme.colorScheme.onError,
                ),
                icon: const Icon(Icons.delete),
                label: Text("$tr_delete_record.dialog.ok_button.label".tr()),
                onPressed: () {},
                onLongPress: () {
                  ref.read(charaDetailRecordStorageProvider.notifier).delete(recordId);
                  CardDialog.dismiss(ref.base);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
