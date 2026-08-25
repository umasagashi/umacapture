/// What the three bug-report dialogs say identically.
///
/// `ReportScreenDialog`, `ReportRecordDialog` and `ReportImportDialog` are three features with
/// three subjects, but they share one dialog frame, one monthly quota and one rate-limit load, and
/// they used to carry their own word-for-word copy of every string that describes those. Three
/// copies of one sentence is how they drift: one gets reworded and the other two silently keep the
/// old wording, with nothing to notice.
///
/// Only the strings that are *about the shared thing* live here. Each dialog's title, its
/// description of what it is about to send, and its own error lines stay under its own namespace —
/// those say different things and are supposed to.
///
/// A file of its own rather than a constant inside one of the three: none of them is the owner the
/// other two reach into.
///
/// The same argument applies one level up, to the *widgets* that draw those strings: the three
/// dialogs carried their own copy of the "still checking" spinner and of the close-only notice, all
/// of them structurally identical. They live here now, for the same reason the strings do.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_report_common = "pages.chara_detail.report_common";

/// What every report dialog shows while its monthly quota is still being fetched.
///
/// No [CardDialog] frame: this state deliberately has no title bar and no close button, because the
/// load it is waiting on settles into one of the framed states below within a request.
class ReportDialogLoading extends StatelessWidget {
  const ReportDialogLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 8),
        Text("$tr_report_common.dialog.loading".tr()),
      ],
    );
  }
}

/// The loud line at the head of a report dialog that is about to upload an image: **Send takes it
/// off this machine.**
///
/// Each dialog already describes its attachment in body text, one paragraph in. That was enough
/// while nothing else made a promise about where the pixels stay; the capture card now states that
/// the browser build processes everything locally, and the two report features are exactly where
/// that stops being true. A statement of that shape has to be met where it cannot be scrolled past
/// or skimmed over, which is why this is [WarningCard]'s error-container fill and not a fourth
/// paragraph — the same treatment the delete and archive confirmations get, and for the same
/// reason: once it is sent it cannot be taken back.
///
/// Mounted by all three report dialogs. The **widget** is shared unconditionally — every report
/// leaves the machine, so every one of them owes the user this line in the same place and the same
/// treatment. The **sentence** is shared by the two whose attachment is a single image the user is
/// looking at; the record report names its own, because what it uploads is not one image (see
/// [message]).
///
/// Sharing the widget is not merely tidier: `report_shared_strings_test` fails on any sentence
/// written identically into two feature namespaces, so the two-dialog sentence has nowhere else it
/// could correctly live.
class ReportUploadWarning extends StatelessWidget {
  /// The already-translated sentence, or null for the shared one — the same shape (and the same
  /// reason) as [ReportDialogNotice.message].
  ///
  /// The default names an *image*, which is exactly what the capture-error and import-error reports
  /// attach, and saying so is the point: a screenshot is the thing that can carry a password or a
  /// real name. [ReportRecordDialog] attaches the record's whole directory — three screenshots and
  /// the recognition JSON beside them — so it passes a sentence that says so rather than
  /// understating its own upload. That divergence is the reason for this parameter; a warning that
  /// is inaccurate about what it is warning about is worse than a slightly less punchy one.
  final String? message;

  const ReportUploadWarning({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    // Centred like the other WarningCard sites: the card hugs its text (its Row is mainAxisSize.min),
    // and these dialogs lay their content out with CrossAxisAlignment.start.
    return Center(child: WarningCard(message: message ?? "$tr_report_common.dialog.upload_warning".tr()));
  }
}

/// A report dialog that has one sentence to say and nothing to offer but Close.
///
/// The server-side kill switch and the exhausted monthly quota both end here, in all three
/// features, and so does the import report's "this front end cannot grab a frame". They differ only
/// in [message] — and, between features, in [dialogTitle], which is the one thing about a report
/// dialog that is genuinely per-feature.
///
/// A [ConsumerWidget] because dismissing is `CardDialog.dismiss(ref.base)`: the notice closes the
/// dialog it is itself being rendered inside, so it needs the ref rather than a callback the three
/// callers would each have to pass identically.
class ReportDialogNotice extends ConsumerWidget {
  const ReportDialogNotice({super.key, required this.dialogTitle, required this.message});

  /// The feature's own dialog title, e.g. キャプチャエラー報告.
  final String dialogTitle;

  /// The already-translated sentence to show. Passed resolved rather than as a key because the
  /// import report reaches this with a message of its own that is not one of the shared two.
  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CardDialog(
      dialogTitle: dialogTitle,
      closeButtonTooltip: "$tr_report_common.dialog.close_button.tooltip".tr(),
      content: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [const SizedBox(height: 16), Text(message)],
      ),
      bottom: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Tooltip(
            message: "$tr_report_common.dialog.close_button.tooltip".tr(),
            child: FilledButton.icon(
              icon: const Icon(Symbols.check_circle_rounded),
              label: Text("$tr_report_common.dialog.close_button.label".tr()),
              onPressed: () => CardDialog.dismiss(ref.base),
            ),
          ),
        ],
      ),
    );
  }
}
