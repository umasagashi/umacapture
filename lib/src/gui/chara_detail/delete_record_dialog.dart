import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/storage.dart';
import '/src/core/providers.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/storage/storage_delete_request.dart';
import '/src/core/storage/zip_export.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';
import '/src/gui/record_image.dart';
import '/src/gui/storage_tree.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_delete_record = "pages.chara_detail.delete_record";

/// Whether deleting the records [recordIds] names would collide with a zip that
/// is already reading the same folders.
///
/// **The same question the storage view's delete asks, asked through the same
/// function.** [storageDeleteAwaitsExtraction] is where that answer is derived —
/// physical containment between the folder being bundled and what the delete
/// removes, taken in both directions — and deriving it a second time here is how
/// the two surfaces would come to disagree silently about which deletes a zip
/// covers. All this adds is the step from "these record ids" to "these
/// directories", through [recordDirOfId], which is the same resolver every other
/// reader of a record's folder goes through.
///
/// **Why the refusal sits on the confirmation and not on the two entrances.**
/// The storage view withholds its row button and its menu entry, because there
/// the confirmation is shared by twelve groups and both entrances are one tap
/// from the work. This path is shaped the other way round: the row context menu
/// and the selection scrim are the only two ways in, and *both* of them open one
/// of the dialogs below, so the dialog is the single place every delete of a
/// record passes through. Refusing here therefore covers a third entrance
/// written later without that author having to know this rule exists, which a
/// gate installed once per entrance cannot do. It also covers the reverse order
/// — a zip that begins while the confirmation is already open — which the
/// storage view answers with modality instead.
///
/// Answers false for an empty [recordIds]: [StorageDeletePathsRequest] is
/// documented as never empty, and "this deletes nothing" is not a state a zip
/// can cover.
bool recordDeleteAwaitsExtraction({
  required PathInfo pathInfo,
  required RecordSource source,
  required Iterable<String> recordIds,
  required StorageZipState? extraction,
}) {
  final targets = [for (final id in recordIds) recordDirOfId(pathInfo, source, id)];
  if (targets.isEmpty) {
    return false;
  }
  return storageDeleteAwaitsExtraction(StorageDeletePathsRequest(targets), extraction);
}

/// Which long reader, if any, is holding a folder these records live in.
///
/// The record surfaces' counterpart of [storageDeleteBlockedBy], and the same
/// shape for the same reason: the per-hold decision stays in
/// [recordDeleteAwaitsExtraction] — which is itself only the id-to-directory step
/// in front of the storage view's predicate — and this adds the quantifiers over
/// the registry's claims and their holds.
LongReadKind? recordDeleteBlockedBy({
  required PathInfo pathInfo,
  required RecordSource source,
  required Iterable<String> recordIds,
  required Iterable<LongReadClaim> claims,
}) {
  for (final claim in claims) {
    final covered = claim.holds.any(
      (hold) =>
          recordDeleteAwaitsExtraction(pathInfo: pathInfo, source: source, recordIds: recordIds, extraction: hold),
    );
    if (covered) {
      return claim.kind;
    }
  }
  return null;
}

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
  ///
  /// **Withdrawing the confirm is not enough on its own, because it is not the
  /// only way back to the tree.** The barrier, the title bar's × and cancel each
  /// unmount this dialog just as thoroughly, and [_deleting] goes with the
  /// widget — so the row the delete was started from is live again, still listed,
  /// and a second delete of the same ids can be started, which is exactly what
  /// the paragraph above says must not happen. All three are shut here for the
  /// duration of the delete: the barrier through the controller, the other two
  /// through [BulkConfirmDialog.leaveEnabled] where the dialog is built.
  Future<void> _confirm() async {
    final storage = recordStorageFor(ref, widget.source);
    final dialogs = ref.read(dialogBuilderProvider.notifier);
    final token = dialogs.currentToken;
    setState(() => _deleting = true);
    dialogs.setBarrierDismissible(token, barrierDismissible: false);
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
      // Released on every way out, so the barrier is frozen for exactly as long
      // as the delete. A no-op once the entry has gone, which is why it needs no
      // `mounted` test of its own.
      dialogs.setBarrierDismissible(token, barrierDismissible: true);
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
    // Watched, not read: a long read can end while this dialog is open, and the
    // confirm has to come back on its own when it does. The registry and not
    // `storageZipProgressProvider`, for the reason `_DeleteSlot` states: the
    // question is about any long reader, not about the zip.
    final claims = ref.watch(longReadRegistryProvider).values;
    // The *layout* and not `pathInfoProvider`, which is the layout plus the
    // statement that the record store was prepared in it — a statement this
    // dialog has never needed and which throws while it is not true. Asking it
    // only when a claim exists used to stand in for that, and the premise was
    // backwards: the one claim that can be live before the store is prepared is
    // the startup sweep's own, taken inside `pathInfoLoader`, so "unresolved and
    // holding a claim" was the state the guard was meant to cover and the only
    // one it could not. Read rather than watched: the data root does not move
    // under an open dialog.
    final layout = ref.read(pathLayoutProvider);
    final awaitingExtraction =
        layout != null &&
        recordDeleteBlockedBy(pathInfo: layout, source: widget.source, recordIds: widget.recordIds, claims: claims) !=
            null;
    return BulkConfirmDialog(
      dismissRef: ref.base,
      dialogTitle: "$tr_delete_record.bulk.title".tr(),
      closeTooltip: "$tr_delete_record.bulk.cancel_button.tooltip".tr(),
      maxWidth: 500,
      maxHeight: 360,
      message: "$tr_delete_record.bulk.message".tr(namedArgs: {"count": "$count"}),
      // The caution answers "shall I?", so it gives way to the running indicator
      // once that has been answered — and to the refusal below when the question
      // is not the user's to answer yet. Stated as body text and not only as the
      // confirm's tooltip: a tooltip needs a hover, and the dialog has already
      // taken the whole screen to ask a question this one cannot be answered.
      bodyExtras: [
        Center(
          child: switch ((_deleting, awaitingExtraction)) {
            (true, _) => const CircularProgressIndicator(),
            (false, true) => NoteCard(description: Text(longReadBusyMessage())),
            (false, false) => WarningCard(message: "$tr_delete_record.bulk.description".tr()),
          },
        ),
      ],
      cancelLabel: "$tr_delete_record.bulk.cancel_button.label".tr(),
      cancelTooltip: "$tr_delete_record.bulk.cancel_button.tooltip".tr(),
      confirmLabel: "$tr_delete_record.bulk.ok_button.label".tr(),
      confirmTooltip: awaitingExtraction ? longReadBusyMessage() : "$tr_delete_record.bulk.ok_button.tooltip".tr(),
      confirmIcon: Symbols.delete_rounded,
      destructive: true,
      onConfirm: () => unawaited(_confirm()),
      confirmEnabled: !_deleting && !awaitingExtraction,
      // The other two of the three exits [_confirm] shuts while the delete runs;
      // the barrier is the third, and it is answered by the same flag so none of
      // them can be reinstated alone.
      leaveEnabled: !_deleting,
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
  /// rather than served — and why all three exits are shut while it runs.
  Future<void> _confirm() async {
    final storage = recordStorageFor(ref, widget.source);
    final dialogs = ref.read(dialogBuilderProvider.notifier);
    final token = dialogs.currentToken;
    setState(() => _deleting = true);
    dialogs.setBarrierDismissible(token, barrierDismissible: false);
    try {
      await storage.deleteAsync(widget.recordId);
    } catch (error, stackTrace) {
      logger.e("Failed to delete record ${widget.recordId}.", error, stackTrace);
      Toaster.show(ToastData.error(description: "app.file_deletion_error".tr()));
    } finally {
      dialogs.setBarrierDismissible(token, barrierDismissible: true);
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
    final pathInfo = ref.read(pathInfoProvider);
    final iconPath = traineeIconPathIn(recordDirOf(pathInfo, widget.source, record));
    // Watched, not read: a long read can end while this dialog is open. No
    // `claims.isNotEmpty` guard around the layout as in the bulk dialog, because
    // this one has already read it for the trainee icon above: here it is not a
    // dependency the gate introduces.
    final awaitingExtraction =
        recordDeleteBlockedBy(
          pathInfo: pathInfo,
          source: widget.source,
          recordIds: [widget.recordId],
          claims: ref.watch(longReadRegistryProvider).values,
        ) !=
        null;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 500, maxHeight: 400),
      child: CardDialog(
        dialogTitle: "$tr_delete_record.dialog.title".tr(),
        closeButtonTooltip: "$tr_delete_record.dialog.close_button.tooltip".tr(),
        // One of the three exits [_confirm] shuts while the delete runs; the
        // barrier and cancel are the other two, and they are answered by the same
        // flag so none of them can be reinstated alone.
        closeButtonEnabled: !_deleting,
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
              // indicator once that has been answered, and to the refusal while
              // the question is not the user's to answer. See the bulk dialog for
              // why the reason is body text and not only the confirm's tooltip.
              if (_deleting)
                const CircularProgressIndicator()
              else if (awaitingExtraction)
                NoteCard(description: Text(longReadBusyMessage()))
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
          confirmTooltip: awaitingExtraction
              ? longReadBusyMessage()
              : "$tr_delete_record.dialog.ok_button.tooltip".tr(),
          confirmIcon: Symbols.delete_rounded,
          destructive: true,
          onConfirm: () => unawaited(_confirm()),
          enabled: !_deleting && !awaitingExtraction,
          // Not narrowed by the extraction: leaving is the remedy this refusal
          // asks for, so the way out stays open for exactly the window the
          // confirm is shut.
          cancelEnabled: !_deleting,
        ),
      ),
    );
  }
}
