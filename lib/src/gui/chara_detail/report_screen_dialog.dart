import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_report_screen = "pages.chara_detail.report_screen";

class ReportScreenDialog extends ConsumerWidget {
  const ReportScreenDialog({Key? key}) : super(key: key);

  static void show(RefBase ref) {
    CardDialog.show(ref, (_) => const ReportScreenDialog());
  }

  Widget loading() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 8),
        Text("$tr_report_screen.dialog.loading".tr()),
      ],
    );
  }

  Widget unavailable(BuildContext context, WidgetRef ref) {
    return CardDialog(
      dialogTitle: "$tr_report_screen.dialog.title".tr(),
      closeButtonTooltip: "$tr_report_screen.dialog.close_button.tooltip".tr(),
      content: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 16),
          Text("$tr_report_screen.dialog.unavailable".tr()),
        ],
      ),
      bottom: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Tooltip(
            message: "$tr_report_screen.dialog.close_button.tooltip".tr(),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.check_circle),
              label: Text("$tr_report_screen.dialog.close_button.label".tr()),
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
      dialogTitle: "$tr_report_screen.dialog.title".tr(),
      closeButtonTooltip: "$tr_report_screen.dialog.close_button.tooltip".tr(),
      content: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 16),
          Text("$tr_report_screen.dialog.limit_reached".tr()),
        ],
      ),
      bottom: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Tooltip(
            message: "$tr_report_screen.dialog.close_button.tooltip".tr(),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.check_circle),
              label: Text("$tr_report_screen.dialog.close_button.label".tr()),
              onPressed: () {
                CardDialog.dismiss(ref.base);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget screenshot(BuildContext context, WidgetRef ref) {
    final data = ref.watch(latestScreenshotProvider);
    if (data == null) {
      return const CircularProgressIndicator();
    }
    if (data.hasError) {
      return Center(
        child: NoteCard(
          description: Text("$tr_report_screen.dialog.screenshot_error".tr()),
        ),
      );
    }
    return Center(child: Image.memory(data.path.readAsBytesSync()));
  }

  Widget ready(BuildContext context, WidgetRef ref, {required int count, required int limit}) {
    final controller = TextEditingController();
    final data = ref.watch(latestScreenshotProvider);
    return CardDialog(
      dialogTitle: "$tr_report_screen.dialog.title".tr(),
      closeButtonTooltip: "$tr_report_screen.dialog.close_button.tooltip".tr(),
      content: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("$tr_report_screen.dialog.description".tr()),
            const SizedBox(height: 16),
            screenshot(context, ref),
            const SizedBox(height: 16),
            Text("$tr_report_screen.dialog.note".tr()),
            const SizedBox(height: 4),
            TextFormField(controller: controller),
            if (limit - count <= 10) ...[
              const SizedBox(height: 16),
              Text("${"$tr_report_screen.dialog.available_count".tr()} (${limit - count} / $limit)"),
            ]
          ],
        ),
      ),
      bottom: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Tooltip(
            message: "$tr_report_screen.dialog.cancel_button.tooltip".tr(),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.cancel),
              label: Text("$tr_report_screen.dialog.cancel_button.label".tr()),
              onPressed: () {
                CardDialog.dismiss(ref.base);
                data?.path.deleteSync(emptyOk: true);
              },
            ),
          ),
          const SizedBox(width: 8),
          Disabled(
            disabled: data == null,
            child: Tooltip(
              message: "$tr_report_screen.dialog.ok_button.tooltip".tr(),
              child: ElevatedButton.icon(
                icon: const Icon(Icons.check_circle),
                label: Text("$tr_report_screen.dialog.ok_button.label".tr()),
                onPressed: () {
                  captureScreen(controller.text, data!.path);
                  CardDialog.dismiss(ref.base);
                  data.path.deleteSync(emptyOk: true);
                },
              ),
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
          Toaster.show(ToastData.error(description: "$tr_report_screen.dialog.loading_error".tr()));
          return Container();
        }
      },
    );
  }
}
