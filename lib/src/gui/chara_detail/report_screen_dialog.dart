import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_report_screen = "pages.chara_detail.report_screen";

class ReportScreenDialog extends ConsumerStatefulWidget {
  const ReportScreenDialog({super.key});

  static void show(RefBase ref) {
    CardDialog.show(ref, (_) => const ReportScreenDialog());
  }

  @override
  ConsumerState<ReportScreenDialog> createState() => _ReportScreenDialogState();
}

class _ReportScreenDialogState extends ConsumerState<ReportScreenDialog> {
  final TextEditingController _noteController = TextEditingController();
  // Cached so a rebuild does not re-issue the rate-limit request (and reset the spinner).
  late final Future<SentryRateLimit?> _rateLimitFuture = SentryRateLimit.download();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
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

  Widget unavailable(BuildContext context) {
    return CardDialog(
      dialogTitle: "$tr_report_screen.dialog.title".tr(),
      closeButtonTooltip: "$tr_report_screen.dialog.close_button.tooltip".tr(),
      content: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [const SizedBox(height: 16), Text("$tr_report_screen.dialog.unavailable".tr())],
      ),
      bottom: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Tooltip(
            message: "$tr_report_screen.dialog.close_button.tooltip".tr(),
            child: FilledButton.icon(
              icon: const Icon(Symbols.check_circle_rounded),
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

  Widget limitReached(BuildContext context) {
    return CardDialog(
      dialogTitle: "$tr_report_screen.dialog.title".tr(),
      closeButtonTooltip: "$tr_report_screen.dialog.close_button.tooltip".tr(),
      content: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [const SizedBox(height: 16), Text("$tr_report_screen.dialog.limit_reached".tr())],
      ),
      bottom: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Tooltip(
            message: "$tr_report_screen.dialog.close_button.tooltip".tr(),
            child: FilledButton.icon(
              icon: const Icon(Symbols.check_circle_rounded),
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

  Widget screenshot(BuildContext context) {
    final data = ref.watch(latestScreenshotProvider);
    if (data == null) {
      return const CircularProgressIndicator();
    }
    if (data.hasError) {
      return Center(child: NoteCard(description: Text("$tr_report_screen.dialog.screenshot_error".tr())));
    }
    return Center(child: Image.memory(data.path.readAsBytesSync()));
  }

  Widget ready(BuildContext context, {required int count, required int limit}) {
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
            screenshot(context),
            const SizedBox(height: 16),
            Text("$tr_report_screen.dialog.note".tr()),
            const SizedBox(height: 4),
            TextFormField(controller: _noteController),
            if (limit - count <= 10) ...[
              const SizedBox(height: 16),
              Text("${"$tr_report_screen.dialog.available_count".tr()} (${limit - count} / $limit)"),
            ],
          ],
        ),
      ),
      bottom: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Tooltip(
            message: "$tr_report_screen.dialog.cancel_button.tooltip".tr(),
            child: OutlinedButton.icon(
              icon: const Icon(Symbols.cancel_rounded),
              label: Text("$tr_report_screen.dialog.cancel_button.label".tr()),
              onPressed: () {
                data?.path.deleteSync(emptyOk: true);
                CardDialog.dismiss(ref.base);
              },
            ),
          ),
          const SizedBox(width: 8),
          Disabled(
            disabled: data == null,
            child: Tooltip(
              message: "$tr_report_screen.dialog.ok_button.tooltip".tr(),
              child: FilledButton.icon(
                icon: const Icon(Symbols.check_circle_rounded),
                label: Text("$tr_report_screen.dialog.ok_button.label".tr()),
                onPressed: () {
                  captureScreen(_noteController.text, data!.path);
                  CardDialog.dismiss(ref.base);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SentryRateLimit?>(
      future: _rateLimitFuture,
      builder: (BuildContext context, AsyncSnapshot<SentryRateLimit?> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return loading();
        }
        final rateLimit = snapshot.data;
        if (rateLimit == null) {
          logger.e("Failed to retrieve rate limit config", snapshot.error, snapshot.stackTrace);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            CardDialog.dismiss(ref.base);
            Toaster.show(ToastData.error(description: "$tr_report_screen.dialog.loading_error".tr()));
          });
          return Container();
        }
        final count = getSentryReportCount();
        logger.i("Rate Limit: available=${rateLimit.available}, limit=${rateLimit.rateLimitPerMonth}, count=$count");
        if (!rateLimit.available) {
          return unavailable(context);
        }
        if (count >= rateLimit.rateLimitPerMonth) {
          return limitReached(context);
        }
        return ready(context, count: count, limit: rateLimit.rateLimitPerMonth);
      },
    );
  }
}
