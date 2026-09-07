import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/storage.dart';
import '/src/core/providers.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/storage/storage_delete_request.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/chara_detail/delete_record_dialog.dart';
import '/src/gui/common.dart';
import '/src/gui/record_image.dart';
import '/src/gui/storage_tree.dart';

// ignore: constant_identifier_names
const tr_archive_record = "pages.chara_detail.archive_records";

/// Which long reader, if any, is holding a folder an archive of [recordIds]
/// would write.
///
/// **Asked over [archiveRecordLongReadPaths], which is also what the archive
/// itself claims.** The move writes two folders per record — it empties
/// `active/<id>` into `archive/<id>` — and the transaction journal for its whole
/// length, so a question about the active folder alone is a different question
/// from the one the operation answers. The two were written separately until this
/// went through the one derivation, and had drifted apart: this confirm stayed
/// live while a job held the archive store root, and pressing it queued the batch
/// behind that job's lock until the acquisition budget ran out and reported every
/// record as failed.
///
/// **Not narrowed by the dialog's own `source`.** Which store the surrounding
/// page is showing is a property of a dropdown; which folders the move writes is
/// a property of the move, and [archiveRecordLongReadPaths] is where that is
/// derived. Nor is the destination left out for not existing yet — the registry
/// matches paths by containment and never asks the filesystem, so a claim above
/// an `archive/<id>` covers it before anything creates it.
///
/// [storageDeleteBlockedBy] and not `recordDeleteBlockedBy`: the question is a
/// list of paths rather than record ids in one store, which is the step
/// `export_button.dart` takes over `recordExportLongReadPaths` for the same
/// reason.
///
/// Watched, not read: a long read can end while either dialog is open, and the
/// confirm has to come back on its own when it does.
///
/// The layout and not `pathInfoProvider`, the step
/// `_BulkDeleteRecordDialogState.build` explains: this question has never
/// depended on the record store having been *prepared*, only on where it is, and
/// `pathInfoProvider` throws while it has not been. A layout the app has not
/// resolved yet becomes a null request — nothing to withhold — which is the same
/// statement, since a claim's paths are derived from that same layout.
///
/// **It buys an answer for the bulk dialog, and for it alone.**
/// [_ArchiveRecordDialogState.build] reads `pathInfoProvider` itself, for the
/// trainee icon, so the single-record dialog still throws before it reaches this
/// helper while the root is unresolved. The step is worth taking regardless: this
/// helper is shared, and the caller that *can* be built without a resolved root
/// must not be made to throw by the one that cannot.
LongReadKind? _archiveBlockedBy(WidgetRef ref, List<String> recordIds) {
  final claims = ref.watch(longReadRegistryProvider).values;
  final layout = ref.watch(pathLayoutProvider);
  return storageDeleteBlockedBy(
    layout == null
        ? null
        : StorageDeletePathsRequest(archiveRecordLongReadPaths(pathInfo: layout, recordIds: recordIds)),
    claims,
  );
}

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
    final awaitingExtraction = _archiveBlockedBy(ref, widget.recordIds) != null;
    return BulkConfirmDialog(
      dismissRef: ref.base,
      dialogTitle: "$tr_archive_record.dialog.title".tr(),
      closeTooltip: "$tr_archive_record.dialog.cancel_button.tooltip".tr(),
      maxWidth: 500,
      // 440 and not the 420 this dialog shipped with: measured under the app's
      // own strings, the two radio options and the caution box already overflow
      // that by four pixels, which is a defect of its own and is fixed here
      // because a case below renders exactly this state. The refusal box is
      // taller again than the caution it replaces, hence the second figure.
      maxHeight: awaitingExtraction ? 460 : 440,
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
        // (stretched) width. The caution answers 「shall I?」, so it gives way to
        // the refusal while that question is not the user's to answer yet — the
        // same swap the delete dialogs make, and for the same reason. Stated as
        // body text and not only as the confirm's tooltip: a tooltip needs a
        // hover, and this dialog has already taken the whole screen to ask a
        // question that cannot be answered.
        Center(
          child: awaitingExtraction
              ? NoteCard(description: Text(longReadBusyMessage()))
              : WarningCard(message: "$tr_archive_record.dialog.description".tr()),
        ),
      ],
      cancelLabel: "$tr_archive_record.dialog.cancel_button.label".tr(),
      cancelTooltip: "$tr_archive_record.dialog.cancel_button.tooltip".tr(),
      confirmLabel: "$tr_archive_record.dialog.ok_button.label".tr(),
      confirmTooltip: awaitingExtraction ? longReadBusyMessage() : "$tr_archive_record.dialog.ok_button.tooltip".tr(),
      confirmIcon: Symbols.archive_rounded,
      destructive: true,
      onConfirm: _confirm,
      confirmEnabled: _option != null && !awaitingExtraction,
      // Not narrowed by the refusal: leaving is the remedy it asks for, so the
      // way out stays open for exactly the window the confirm is shut.
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
    final awaitingExtraction = _archiveBlockedBy(ref, [widget.recordId]) != null;
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
              // The caution gives way to the refusal; see the bulk dialog above.
              Center(
                child: awaitingExtraction
                    ? NoteCard(description: Text(longReadBusyMessage()))
                    : WarningCard(message: "$tr_archive_record.dialog.description".tr()),
              ),
            ],
          ),
        ),
        bottom: ConfirmActionRow(
          dismissRef: ref.base,
          cancelLabel: "$tr_archive_record.dialog.cancel_button.label".tr(),
          cancelTooltip: "$tr_archive_record.dialog.cancel_button.tooltip".tr(),
          confirmLabel: "$tr_archive_record.dialog.ok_button.label".tr(),
          confirmTooltip: awaitingExtraction
              ? longReadBusyMessage()
              : "$tr_archive_record.dialog.ok_button.tooltip".tr(),
          confirmIcon: Symbols.archive_rounded,
          destructive: true,
          onConfirm: _confirm,
          enabled: _option != null && !awaitingExtraction,
          // Not narrowed by the refusal: leaving is the remedy it asks for, so
          // the way out stays open for exactly the window the confirm is shut.
        ),
      ),
    );
  }
}
