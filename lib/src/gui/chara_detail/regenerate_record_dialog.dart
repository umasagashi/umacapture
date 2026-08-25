import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/storage.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/core/video_import.dart';
import '/src/core/video_import_ops.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';
import '/src/gui/record_image.dart';
import '/src/gui/video_import.dart';

// ignore: constant_identifier_names
const tr_regenerate_record = "pages.chara_detail.regenerate_record";

class RegenerateRecordDialog extends ConsumerWidget {
  final String recordId;

  /// Test-only: stands in for the import state [videoImportState] reports.
  ///
  /// `video_import.dart` resolves to the desktop stub on the VM, whose notifier is a constant idle
  /// by construction, so without this seam the exclusion below could only be exercised in a browser
  /// — and the button it withdraws is the destructive one on this dialog. Same seam, same reason, as
  /// `NotificationLayer.debugVideoImportState`.
  @visibleForTesting
  final ValueListenable<VideoImportState>? debugImportState;

  const RegenerateRecordDialog({super.key, required this.recordId, this.debugImportState});

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
              RecordImage(
                iconPath,
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
            // Mutual exclusion with a running video import, on exactly the predicate the capture
            // button is gated on. The worker refuses every record while an import owns the event
            // loop (it runs on its own storage root), so a batch started here would fail record by
            // record and then arrive at its teardown with the import still decoding. Listened to
            // rather than read: this dialog is modal for as long as the user leaves it open, and an
            // import can begin behind it.
            ValueListenableBuilder<VideoImportState>(
              valueListenable: debugImportState ?? videoImportState,
              builder: (context, import, _) => Disabled(
                // Withdrawn, not merely inert. Blanking `onLongPress` alone left a filled button in
                // the error colour looking exactly as it does when it works: `FilledButton` counts
                // itself enabled while *either* callback is non-null, so the destructive red stayed
                // and a press did nothing at all, with the reason hidden behind a hover this dialog
                // cannot assume. [Disabled] greys it, takes it out of focus traversal, and -- with
                // both callbacks null below -- lets it announce itself as disabled to a screen
                // reader, which is the shape the other exclusion sites in this app already use.
                disabled: import.isRunning,
                // The reason, and not the generic "what this button does" line below it: the inner
                // [Tooltip] sits under `Disabled`'s `IgnorePointer`, so it goes silent for exactly
                // as long as the import blocks this button. Shared with the settings page's
                // whole-store entry, which is gated on the same predicate: one refusal, one
                // sentence, in one place.
                tooltip: "$tr_video_import.blocks_regeneration".tr(),
                child: Tooltip(
                  message: "$tr_regenerate_record.dialog.ok_button.tooltip".tr(),
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.error,
                      foregroundColor: theme.colorScheme.onError,
                    ),
                    icon: const Icon(Symbols.refresh_rounded),
                    label: Text("$tr_regenerate_record.dialog.ok_button.label".tr()),
                    // Long-press required so a single misclick cannot restart a recognition batch;
                    // `onPressed` stays non-null while the button is offered so it does not render
                    // as disabled in that state, and goes null with it when it is not.
                    onPressed: import.isRunning ? null : () {},
                    onLongPress: import.isRunning
                        ? null
                        : () {
                            ref.read(charaDetailRecordRegenerationControllerProvider.notifier).start([record]);
                            CardDialog.dismiss(ref.base);
                          },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
