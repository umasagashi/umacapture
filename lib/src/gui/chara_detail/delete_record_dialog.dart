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
    if (source == RecordSource.active) {
      ref.read(charaDetailRecordStorageLoaderProvider.notifier).deleteAll(recordIds);
    } else {
      ref.read(charaDetailArchiveStorageLoaderProvider.notifier).deleteAll(recordIds);
    }
    // The rows are gone; leave selection mode so the checkbox column disappears
    // and stale checks are dropped.
    ref.read(selectionModeProvider.notifier).set(null);
    ref.read(selectedRecordIdsProvider.notifier).set(<String>{});
    CardDialog.dismiss(ref.base);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final count = recordIds.length;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 500, maxHeight: 360),
      child: CardDialog(
        dialogTitle: "$tr_delete_record.bulk.title".tr(),
        closeButtonTooltip: "$tr_delete_record.bulk.cancel_button.tooltip".tr(),
        usePageView: false,
        content: Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  "$tr_delete_record.bulk.message".tr(namedArgs: {"count": "$count"}),
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                WarningCard(message: "$tr_delete_record.bulk.description".tr()),
              ],
            ),
          ),
        ),
        bottom: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Tooltip(
              message: "$tr_delete_record.bulk.cancel_button.tooltip".tr(),
              child: OutlinedButton.icon(
                icon: const Icon(Symbols.cancel_rounded),
                label: Text("$tr_delete_record.bulk.cancel_button.label".tr()),
                onPressed: () => CardDialog.dismiss(ref.base),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: "$tr_delete_record.bulk.ok_button.tooltip".tr(),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                icon: const Icon(Symbols.delete_rounded),
                label: Text("$tr_delete_record.bulk.ok_button.label".tr()),
                onPressed: () {},
                onLongPress: () => _confirm(ref),
              ),
            ),
          ],
        ),
      ),
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
    final record = source == RecordSource.active
        ? ref.read(charaDetailRecordStorageLoaderProvider.notifier).getBy(id: recordId)!
        : ref.read(charaDetailArchiveStorageLoaderProvider.notifier).getBy(id: recordId)!;
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
              Image.file(iconPath.toFile()),
              Text(record.evaluationValue.toNumberString(), style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              WarningCard(message: "$tr_delete_record.dialog.description".tr()),
            ],
          ),
        ),
        bottom: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Tooltip(
              message: "$tr_delete_record.dialog.cancel_button.tooltip".tr(),
              child: OutlinedButton.icon(
                icon: const Icon(Symbols.cancel_rounded),
                label: Text("$tr_delete_record.dialog.cancel_button.label".tr()),
                onPressed: () {
                  CardDialog.dismiss(ref.base);
                },
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: "$tr_delete_record.dialog.ok_button.tooltip".tr(),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                icon: const Icon(Symbols.delete_rounded),
                label: Text("$tr_delete_record.dialog.ok_button.label".tr()),
                onPressed: () {},
                onLongPress: () {
                  if (source == RecordSource.active) {
                    ref.read(charaDetailRecordStorageLoaderProvider.notifier).delete(recordId);
                  } else {
                    ref.read(charaDetailArchiveStorageLoaderProvider.notifier).delete(recordId);
                  }
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
