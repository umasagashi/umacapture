import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/const.dart';
import '/src/core/path_entity.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/report_common.dart';
import '/src/gui/common.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_report_record = "pages.chara_detail.report_record";

class ReportRecordDialog extends ConsumerStatefulWidget {
  final DirectoryPath directory;

  /// How the monthly report quota is fetched.
  ///
  /// Only overridden by tests, exactly as `ReportScreenDialog` does it: the real loader issues a Dio
  /// request, whose timeout timer a widget test reports as a pending timer even after the dialog is
  /// gone. Without this seam this dialog cannot be rendered by a test at all.
  @visibleForTesting
  final Future<SentryRateLimit?> Function() rateLimitLoader;

  const ReportRecordDialog({super.key, required this.directory, this.rateLimitLoader = SentryRateLimit.download});

  static void show(RefBase ref, DirectoryPath directory) {
    CardDialog.show(ref, (_) => ReportRecordDialog(directory: directory));
  }

  @override
  ConsumerState<ReportRecordDialog> createState() => _ReportRecordDialogState();
}

class _ReportRecordDialogState extends ConsumerState<ReportRecordDialog> {
  // Resolved asynchronously: the web (OPFS) fs backend throws on the synchronous
  // existence checks that getCharaDetailRecordFiles performs, so the list must not
  // be evaluated eagerly during build.
  late final Future<List<FilePath>> _filesFuture = getCharaDetailRecordFiles(widget.directory);
  final TextEditingController _noteController = TextEditingController();
  // Cached so a rebuild does not re-issue the rate-limit request (and reset the spinner).
  late final Future<SentryRateLimit?> _rateLimitFuture = widget.rateLimitLoader();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  /// The close-only states, both drawn by the shared [ReportDialogNotice].
  Widget notice(String message) {
    return ReportDialogNotice(dialogTitle: "$tr_report_record.dialog.title".tr(), message: message);
  }

  Widget ready(BuildContext context, {required int count, required int limit}) {
    final theme = Theme.of(context);
    return CardDialog(
      dialogTitle: "$tr_report_record.dialog.title".tr(),
      closeButtonTooltip: "$tr_report_common.dialog.close_button.tooltip".tr(),
      content: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // At the head of the dialog, as in the other two report dialogs, and here it carries
            // more of the weight than in either of them: on web the file list below is not shown at
            // all (OPFS paths mean nothing to the user), so this is the only place the dialog says
            // that anything leaves the machine. Its own sentence rather than the shared one because
            // this report attaches the record's screenshots AND its recognition JSON.
            ReportUploadWarning(message: "$tr_report_record.dialog.upload_warning".tr()),
            const SizedBox(height: 16),
            // The file list shows OS-level paths and links to the OS file explorer,
            // neither of which is meaningful on web (virtual OPFS paths, no shell
            // launch). Hide it there; the attachments are still gathered and sent.
            // Same capability as every other reveal affordance, so the four sites
            // cannot drift apart again.
            if (CurrentPlatform.canRevealInFileManager()) ...[
              Row(
                children: [
                  Text("$tr_report_record.dialog.files".tr()),
                  RichText(
                    text: TextSpan(
                      text: "$tr_report_record.dialog.open_in_explorer".tr(),
                      style: theme.textTheme.bodyMedium!.copyWith(
                        color: theme.colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                      recognizer: TapGestureRecognizer()..onTap = () => widget.directory.launch(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              FutureBuilder<List<FilePath>>(
                future: _filesFuture,
                builder: (context, snapshot) {
                  final files = snapshot.data ?? const <FilePath>[];
                  return TextFormField(
                    key: ValueKey(files.map((e) => e.path).join("\n")),
                    initialValue: files.map((e) => e.path).join("\n"),
                    decoration: const InputDecoration(
                      hintText: "File not found.",
                      filled: false,
                      isCollapsed: true,
                      contentPadding: EdgeInsets.all(8),
                    ),
                    readOnly: true,
                    maxLines: null,
                  );
                },
              ),
              const SizedBox(height: 16),
            ],
            Text("$tr_report_common.dialog.note".tr()),
            const SizedBox(height: 4),
            TextFormField(controller: _noteController),
            if (limit - count <= 10) ...[
              const SizedBox(height: 16),
              Text("${"$tr_report_common.dialog.available_count".tr()} (${limit - count} / $limit)"),
            ],
            // The buttons scroll with the content instead of sitting in a fixed
            // footer: reporters were submitting straight from the always-visible
            // footer without ever noticing the free-text note field above.
            // Reaching Send now means scrolling past it.
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Tooltip(
                  message: "$tr_report_common.dialog.cancel_button.tooltip".tr(),
                  child: OutlinedButton.icon(
                    icon: const Icon(Symbols.cancel_rounded),
                    label: Text("$tr_report_common.dialog.cancel_button.label".tr()),
                    onPressed: () {
                      CardDialog.dismiss(ref.base);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: "$tr_report_common.dialog.ok_button.tooltip".tr(),
                  child: FilledButton.icon(
                    icon: const Icon(Symbols.check_circle_rounded),
                    label: Text("$tr_report_common.dialog.ok_button.label".tr()),
                    onPressed: () {
                      captureCharaDetailRecord(_noteController.text, widget.directory);
                      CardDialog.dismiss(ref.base);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SentryRateLimit?>(
      future: _rateLimitFuture,
      builder: (BuildContext context, AsyncSnapshot<SentryRateLimit?> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const ReportDialogLoading();
        }
        final rateLimit = snapshot.data;
        if (rateLimit == null) {
          logger.e("Failed to retrieve rate limit config", snapshot.error, snapshot.stackTrace);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            CardDialog.dismiss(ref.base);
            Toaster.show(ToastData.error(description: "$tr_report_common.dialog.loading_error".tr()));
          });
          return Container();
        }
        final count = getSentryReportCount();
        logger.i("Rate Limit: available=${rateLimit.available}, limit=${rateLimit.rateLimitPerMonth}, count=$count");
        if (!rateLimit.available) {
          return notice("$tr_report_common.dialog.unavailable".tr());
        }
        if (count >= rateLimit.rateLimitPerMonth) {
          return notice("$tr_report_common.dialog.limit_reached".tr());
        }
        return ready(context, count: count, limit: rateLimit.rateLimitPerMonth);
      },
    );
  }
}
