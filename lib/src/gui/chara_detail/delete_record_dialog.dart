import 'dart:async';

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
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_delete_record = "pages.chara_detail.delete_record";

/// Bulk-delete confirmation dialog, the selection-flow counterpart of
/// [DeleteRecordDialog].
///
/// Reached from the selection scrim after rows are checked. Like the single
/// dialog it gates the destructive action behind a long-press; like the archive
/// dialog it reports a count rather than a single record's icon.
class BulkDeleteRecordDialog extends ConsumerStatefulWidget {
  final List<String> recordIds;
  final RecordSource source;

  const BulkDeleteRecordDialog({super.key, required this.recordIds, required this.source});

  static void show(RefBase ref, {required List<String> recordIds, required RecordSource source}) {
    CardDialog.show(ref, (_) => BulkDeleteRecordDialog(recordIds: recordIds, source: source));
  }

  @override
  ConsumerState<BulkDeleteRecordDialog> createState() => _BulkDeleteRecordDialogState();
}

class _BulkDeleteRecordDialogState extends ConsumerState<BulkDeleteRecordDialog> {
  // Whether this dialog's delete is still running. See [_confirm] for why the
  // dialog has to carry it.
  bool _deleting = false;

  /// Deletes the checked records, then closes this dialog.
  ///
  /// Everything the post-await steps need is read up front: the dialog is
  /// dismissible through the scrim, so a bulk delete on OPFS is easily long
  /// enough for the user to close it mid-flight, and `ref` throws once the
  /// widget is unmounted. The notifiers themselves are container-scoped and
  /// outlive the dialog.
  ///
  /// The dialog stays up until the delete settles and the wait is unbounded -
  /// the store takes a cross-tab record lock that makes a second caller *wait*
  /// rather than refusing it. A second confirm therefore reaches the store after
  /// the first delete has already erased the records, where every id is missing
  /// from memory and is counted as failed: the user is told the delete failed
  /// for records that were deleted. [_deleting] is what stops that, and the same
  /// flag puts a running indicator in place of the caution box, so the silence
  /// that provokes the second press is answered at the same time.
  Future<void> _confirm() async {
    final storage = recordStorageFor(ref, widget.source);
    final dialogs = ref.read(dialogBuilderProvider.notifier);
    final token = dialogs.currentToken;
    setState(() => _deleting = true);
    // The rows are on their way out; leave selection mode now so the checkbox
    // column disappears and stale checks are dropped even when the delete fails
    // or the dialog is closed before it finishes.
    exitSelection(ref);
    try {
      await storage.deleteAllAsync(widget.recordIds);
    } catch (error, stackTrace) {
      // deleteAllAsync reports its own per-record failures; this covers the whole
      // batch failing (e.g. the record lock could not be acquired), which would
      // otherwise surface as an unhandled error in the zone.
      logger.e("Failed to delete records.", error, stackTrace);
      Toaster.show(ToastData.error(description: "app.file_deletion_error".tr()));
    } finally {
      // Restore the confirm before dismissing, for the case the dismiss cannot
      // take: the token is stale once another dialog has taken over, and this
      // one would otherwise be left showing a spinner for work that is over.
      if (mounted) {
        setState(() => _deleting = false);
      }
      // Token-scoped: the user may have opened another dialog while the delete
      // ran, and an unqualified dismiss would close that one instead.
      dialogs.dismiss(token);
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.recordIds.length;
    return BulkConfirmDialog(
      dismissRef: ref.base,
      dialogTitle: "$tr_delete_record.bulk.title".tr(),
      closeTooltip: "$tr_delete_record.bulk.cancel_button.tooltip".tr(),
      maxWidth: 500,
      maxHeight: 360,
      message: "$tr_delete_record.bulk.message".tr(namedArgs: {"count": "$count"}),
      // The caution answers "shall I?", so it gives way to the running indicator
      // once that has been answered.
      bodyExtras: [
        Center(
          child: _deleting
              ? const CircularProgressIndicator()
              : WarningCard(message: "$tr_delete_record.bulk.description".tr()),
        ),
      ],
      cancelLabel: "$tr_delete_record.bulk.cancel_button.label".tr(),
      cancelTooltip: "$tr_delete_record.bulk.cancel_button.tooltip".tr(),
      confirmLabel: "$tr_delete_record.bulk.ok_button.label".tr(),
      confirmTooltip: "$tr_delete_record.bulk.ok_button.tooltip".tr(),
      confirmIcon: Symbols.delete_rounded,
      destructive: true,
      onConfirm: () => unawaited(_confirm()),
      confirmEnabled: !_deleting,
    );
  }
}

class DeleteRecordDialog extends ConsumerStatefulWidget {
  final String recordId;
  final RecordSource source;

  const DeleteRecordDialog({super.key, required this.recordId, this.source = RecordSource.active});

  static void show(RefBase ref, {required String recordId, RecordSource source = RecordSource.active}) {
    CardDialog.show(ref, (_) {
      return DeleteRecordDialog(recordId: recordId, source: source);
    });
  }

  @override
  ConsumerState<DeleteRecordDialog> createState() => _DeleteRecordDialogState();
}

class _DeleteRecordDialogState extends ConsumerState<DeleteRecordDialog> {
  bool _deleting = false;

  /// Deletes the record, then closes this dialog. See
  /// [_BulkDeleteRecordDialogState._confirm] for why the post-await work is
  /// prepared before the await, and why a second confirm has to be withdrawn
  /// rather than served.
  Future<void> _confirm() async {
    final storage = recordStorageFor(ref, widget.source);
    final dialogs = ref.read(dialogBuilderProvider.notifier);
    final token = dialogs.currentToken;
    setState(() => _deleting = true);
    try {
      await storage.deleteAsync(widget.recordId);
    } catch (error, stackTrace) {
      logger.e("Failed to delete record ${widget.recordId}.", error, stackTrace);
      Toaster.show(ToastData.error(description: "app.file_deletion_error".tr()));
    } finally {
      if (mounted) {
        setState(() => _deleting = false);
      }
      dialogs.dismiss(token);
    }
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
      constraints: const BoxConstraints(maxWidth: 500, maxHeight: 400),
      child: CardDialog(
        dialogTitle: "$tr_delete_record.dialog.title".tr(),
        closeButtonTooltip: "$tr_delete_record.dialog.close_button.tooltip".tr(),
        usePageView: false,
        content: Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              RecordImage(
                iconPath,
                // The trainee icon is normally always present, but guard against a
                // missing/corrupt file (e.g. a hand-edited archive) so the dialog
                // shows a placeholder instead of a red error box.
                errorBuilder: (context, error, stackTrace) =>
                    Icon(Symbols.hide_image_rounded, size: 64, color: theme.colorScheme.onSurfaceVariant),
              ),
              Text(record.evaluationValueLabel, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              // The caution answers "shall I?", so it gives way to the running
              // indicator once that has been answered.
              if (_deleting)
                const CircularProgressIndicator()
              else
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
          onConfirm: () => unawaited(_confirm()),
          enabled: !_deleting,
        ),
      ),
    );
  }
}
