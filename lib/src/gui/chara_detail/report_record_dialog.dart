import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/path_entity.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/gui/common.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_report_record = "pages.chara_detail.report_record";

class ReportRecordDialog extends ConsumerWidget {
  final DirectoryPath directory;
  final List<FilePath> files;

  ReportRecordDialog({
    Key? key,
    required this.directory,
  })  : files = getCharaDetailRecordFiles(directory),
        super(key: key);

  static void show(RefBase ref, DirectoryPath directory) {
    CardDialog.show(ref, (_) => ReportRecordDialog(directory: directory));
  }

  Widget loading() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 8),
        Text("$tr_report_record.dialog.loading".tr()),
      ],
    );
  }

  Widget unavailable(BuildContext context, WidgetRef ref) {
    return CardDialog(
      dialogTitle: "$tr_report_record.dialog.title".tr(),
      closeButtonTooltip: "$tr_report_record.dialog.close_button.tooltip".tr(),
      content: Text("$tr_report_record.dialog.unavailable".tr()),
      bottom: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Tooltip(
            message: "$tr_report_record.dialog.close_button.tooltip".tr(),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.check_circle),
              label: Text("$tr_report_record.dialog.close_button.label".tr()),
              onPressed: () {
                CardDialog.dismiss(ref.base);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget limitReached(BuildContext context, WidgetRef ref) {
    return CardDialog(
      dialogTitle: "$tr_report_record.dialog.title".tr(),
      closeButtonTooltip: "$tr_report_record.dialog.close_button.tooltip".tr(),
      content: Text("$tr_report_record.dialog.limit_reached".tr()),
      bottom: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Tooltip(
            message: "$tr_report_record.dialog.close_button.tooltip".tr(),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.check_circle),
              label: Text("$tr_report_record.dialog.close_button.label".tr()),
              onPressed: () {
                CardDialog.dismiss(ref.base);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget ready(BuildContext context, WidgetRef ref, {required int count, required int limit}) {
    final theme = Theme.of(context);
    final controller = TextEditingController();
    return CardDialog(
      dialogTitle: "$tr_report_record.dialog.title".tr(),
      closeButtonTooltip: "$tr_report_record.dialog.close_button.tooltip".tr(),
      content: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                    recognizer: TapGestureRecognizer()..onTap = () => directory.launch(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            TextFormField(
              initialValue: files.map((e) => e.path).join("\n"),
              decoration: const InputDecoration(
                hintText: "File not found.",
                filled: false,
                isCollapsed: true,
                contentPadding: EdgeInsets.all(8),
              ),
              readOnly: true,
              maxLines: null,
            ),
            const SizedBox(height: 16),
            Text("$tr_report_record.dialog.note".tr()),
            const SizedBox(height: 4),
            TextFormField(controller: controller),
            if (limit - count <= 10) ...[
              const SizedBox(height: 16),
              Text("${"$tr_report_record.dialog.available_count".tr()} (${limit - count} / $limit)"),
            ]
          ],
        ),
      ),
      bottom: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Tooltip(
            message: "$tr_report_record.dialog.cancel_button.tooltip".tr(),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.cancel),
              label: Text("$tr_report_record.dialog.cancel_button.label".tr()),
              onPressed: () {
                CardDialog.dismiss(ref.base);
              },
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: "$tr_report_record.dialog.ok_button.tooltip".tr(),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.check_circle),
              label: Text("$tr_report_record.dialog.ok_button.label".tr()),
              onPressed: () {
                captureCharaDetailRecord(controller.text, directory);
                CardDialog.dismiss(ref.base);
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder(
      future: SentryRateLimit.download(),
      builder: (BuildContext context, AsyncSnapshot<dynamic> snapshot) {
        try {
          if (!snapshot.hasData) {
            return loading();
          }
          final rateLimit = snapshot.data as SentryRateLimit;
          final count = getSentryReportCount();
          logger.i("Rate Limit: available=${rateLimit.available}, limit=${rateLimit.rateLimitPerMonth}, count=$count");
          if (!rateLimit.available) {
            return unavailable(context, ref);
          }
          if (count >= rateLimit.rateLimitPerMonth) {
            return limitReached(context, ref);
          }
          return ready(context, ref, count: count, limit: rateLimit.rateLimitPerMonth);
        } catch (exception, stackTrace) {
          logger.e("Failed to retrieve rate limit config", exception, stackTrace);
          CardDialog.dismiss(ref.base);
          Toaster.show(ToastData.error(description: "$tr_report_record.dialog.loading_error".tr()));
          return Container();
        }
      },
    );
  }
}
