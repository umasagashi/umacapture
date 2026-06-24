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
const tr_regenerate_record = "pages.chara_detail.regenerate_record";

class RegenerateRecordDialog extends ConsumerWidget {
  final String recordId;

  const RegenerateRecordDialog({super.key, required this.recordId});

  static void show(RefBase ref, {required String recordId}) {
    CardDialog.show(ref, (_) {
      return RegenerateRecordDialog(recordId: recordId);
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Guard against the record vanishing between show() and build() (a background
    // capture reload, quarantine move, or the record being deleted/archived), and
    // resolve the icon from the active source (regenerate is active-only), matching
    // the delete/memo/rating dialogs.
    final record = ref.read(charaDetailRecordStorageLoaderProvider.notifier).getBy(id: recordId);
    if (record == null) {
      return dismissForMissingRecord(ref.base);
    }
    final iconPath = traineeIconPathIn(recordDirOf(ref.read(pathInfoProvider), RecordSource.active, record));
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 500, maxHeight: 400),
      child: CardDialog(
        dialogTitle: "$tr_regenerate_record.dialog.title".tr(),
        closeButtonTooltip: "$tr_regenerate_record.dialog.close_button.tooltip".tr(),
        usePageView: false,
        content: Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.file(
                iconPath.toFile(),
                // The trainee icon is normally always present, but guard against a
                // missing/corrupt file so the dialog shows a placeholder instead
                // of a red error box.
                errorBuilder: (context, error, stackTrace) =>
                    Icon(Symbols.hide_image_rounded, size: 64, color: theme.colorScheme.onSurfaceVariant),
              ),
              Text(record.metadata.capturedDate.toDateTime().toLocal().toString(), style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              NoteCard(
                description: Text("$tr_regenerate_record.dialog.description".tr()),
                color: theme.colorScheme.error,
              ),
            ],
          ),
        ),
        bottom: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Tooltip(
              message: "$tr_regenerate_record.dialog.cancel_button.tooltip".tr(),
              child: OutlinedButton.icon(
                icon: const Icon(Symbols.cancel_rounded),
                label: Text("$tr_regenerate_record.dialog.cancel_button.label".tr()),
                onPressed: () {
                  CardDialog.dismiss(ref.base);
                },
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: "$tr_regenerate_record.dialog.ok_button.tooltip".tr(),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                icon: const Icon(Symbols.refresh_rounded),
                label: Text("$tr_regenerate_record.dialog.ok_button.label".tr()),
                onPressed: () {},
                onLongPress: () {
                  ref.read(charaDetailRecordRegenerationControllerProvider.notifier).start([record]);
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
