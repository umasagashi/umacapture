import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/chara_detail/record_link_import.dart';
import '/src/chara_detail/record_share.dart';
import '/src/chara_detail/record_share_session.dart';
import '/src/chara_detail/record_zip.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/chara_detail/import_button.dart';
import '/src/gui/common.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_link_import = "$tr_import.link";

/// How long a request answered 429 waits before it is sent once more: the WAF's window on `/api/` (10 seconds).
final linkImportRetryDelayProvider = Provider<Duration>((_) => const Duration(seconds: 10));

/// The **full** translation key of the sentence [refusal] owes the user. Exhaustive, for the reason
/// [importRefusalKey] states.
String linkImportRefusalKey(LinkImportRefusal refusal) => switch (refusal) {
  LinkImportRefusal.notALink => "$tr_link_import.refused.not_a_link",
  LinkImportRefusal.notFound => "$tr_link_import.refused.not_found",
  LinkImportRefusal.oldFormat => "$tr_link_import.refused.old_format",
  LinkImportRefusal.ownShare => "$tr_link_import.refused.own_share",
  LinkImportRefusal.imagesPending => "$tr_link_import.refused.images_pending",
  LinkImportRefusal.imagesUnavailable => "$tr_link_import.refused.images_unavailable",
  LinkImportRefusal.imagesUnreachable => "$tr_link_import.refused.images_unreachable",
  LinkImportRefusal.busy => "$tr_link_import.refused.busy",
  LinkImportRefusal.unreachable => "$tr_link_import.refused.unreachable",
};

/// Imports the shared record [text] links to: reads it ([fetchSharedRecord]) and, where it is complete, writes it
/// through the import every toolbar import takes ([runRecordImport]). Every outcome is told on a toast. Returns
/// whether the record was written, which is when the dialog has nothing left to offer; any refusal — before the store
/// or by it — leaves the link in the dialog to correct or try again.
Future<bool> importRecordFromLink(ProviderContainer container, String text) async {
  void refuse(LinkImportRefusal reason) =>
      Toaster.show(ToastData.warning(description: linkImportRefusalKey(reason).tr()));
  final shareId = sharedRecordIdOf(text);
  if (shareId == null) {
    refuse(LinkImportRefusal.notALink);
    return false;
  }
  final LinkImportFetch fetched;
  try {
    fetched = await fetchSharedRecord(
      container.read(recordShareDioProvider),
      shareId,
      ownShareIds: [for (final share in container.read(recordSharesProvider).values) ?share.id],
      retryDelay: container.read(linkImportRetryDelayProvider),
      timeout: container.read(shareRequestTimeoutProvider),
      imagesTimeout: container.read(shareImagesRequestTimeoutProvider),
    );
  } catch (error, stackTrace) {
    logger.e("Failed to read the shared record $shareId", error, stackTrace);
    refuse(LinkImportRefusal.unreachable);
    return false;
  }
  switch (fetched) {
    case LinkImportRefused(:final reason):
      logger.i("The shared record $shareId is not imported: ${reason.name}");
      refuse(reason);
      return false;
    case LinkImportFiles(:final files):
      var written = false;
      await runRecordImport(
        container,
        operation: 'An import of the shared record $shareId',
        action: (progress) => progress.run(
          (storageDir, isDuplicate) => RecordZipService.importFiles(files, storageDir, isDuplicate: isDuplicate),
        ),
        report: (progress) {
          // A record refused by the store is told by its reason after this; only a written one is told here.
          written = progress.importedIds.isNotEmpty;
          if (written) {
            Toaster.show(
              ToastData.success(
                description: "$tr_import.success".tr(namedArgs: {"count": "${progress.importedIds.length}"}),
              ),
            );
          }
        },
      );
      return written;
  }
}

/// Toolbar control, beside [CharaDetailImportButton], that opens [LinkImportDialog]. Withheld while an import runs,
/// or another long read holds the record store, as the zip import is.
class CharaDetailLinkImportButton extends ConsumerWidget {
  const CharaDetailLinkImportButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (:withheld, :importing) = recordImportWithheld(ref);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Disabled(
        disabled: withheld,
        tooltip: importing ? "$tr_import.disabled_tooltip".tr() : longReadBusyMessage(),
        child: IconButton(
          icon: const Icon(Symbols.add_link_rounded, size: 22),
          tooltip: "$tr_link_import.button_tooltip".tr(),
          visualDensity: VisualDensity.compact,
          splashRadius: 20,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          padding: EdgeInsets.zero,
          onPressed: withheld ? null : () => CardDialog.show(ref.base, (_) => const LinkImportDialog()),
        ),
      ),
    );
  }
}

/// The dialog a link is pasted into (N2): the opening sentence, the link's field, and the import button.
class LinkImportDialog extends ConsumerStatefulWidget {
  const LinkImportDialog({super.key});

  @override
  ConsumerState<LinkImportDialog> createState() => _LinkImportDialogState();
}

class _LinkImportDialogState extends ConsumerState<LinkImportDialog> {
  final _link = TextEditingController();
  bool _importing = false;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  /// **Nothing closes the dialog while the import runs** — not the barrier, the × or the cancel button — as the share
  /// dialog keeps itself open while its request is out: a fetch cannot be called back, and a record whose write has
  /// begun is not to be left half-imported. The dialog closes once the record is written, and stays open otherwise.
  Future<void> _import() async {
    // The container, not `ref`: the import reports through the container, which outlives this dialog.
    final container = ProviderScope.containerOf(context, listen: false);
    final dismissRef = ref.base;
    final dialogs = ref.read(dialogBuilderProvider.notifier);
    final token = dialogs.currentToken;
    setState(() => _importing = true);
    dialogs.setBarrierDismissible(token, barrierDismissible: false);
    var written = false;
    try {
      written = await importRecordFromLink(container, _link.text);
    } finally {
      dialogs.setBarrierDismissible(token, barrierDismissible: true);
      if (mounted) setState(() => _importing = false);
    }
    if (written && mounted) CardDialog.dismiss(dismissRef, token);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Text("$tr_link_import.dialog.description".tr(), style: theme.textTheme.bodyMedium),
        TextField(
          controller: _link,
          enabled: !_importing,
          keyboardType: TextInputType.url,
          autofocus: true,
          decoration: InputDecoration(labelText: "$tr_link_import.dialog.field_label".tr()),
          onSubmitted: (_) => _importing ? null : _import(),
        ),
      ],
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: CardDialog(
        dialogTitle: "$tr_link_import.dialog.title".tr(),
        closeButtonTooltip: "$tr_link_import.dialog.cancel_button.tooltip".tr(),
        closeButtonEnabled: !_importing,
        usePageView: false,
        scrollableContent: true,
        content: _importing ? Stack(children: [content, const LinearProgressIndicator()]) : content,
        bottom: ConfirmActionRow(
          dismissRef: ref.base,
          cancelLabel: "$tr_link_import.dialog.cancel_button.label".tr(),
          cancelTooltip: "$tr_link_import.dialog.cancel_button.tooltip".tr(),
          confirmLabel: "$tr_link_import.dialog.ok_button.label".tr(),
          confirmTooltip: "$tr_link_import.dialog.ok_button.tooltip".tr(),
          confirmIcon: Symbols.download_rounded,
          destructive: false,
          enabled: !_importing,
          cancelEnabled: !_importing,
          onConfirm: _import,
        ),
      ),
    );
  }
}
