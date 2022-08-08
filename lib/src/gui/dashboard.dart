import 'dart:io';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:percent_indicator/percent_indicator.dart';
import 'package:version/version.dart';

import '/const.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_dashboard = "pages.dashboard";

bool isInstallerMode() {
  return File(Platform.resolvedExecutable)
      .parent
      .listSync(recursive: false, followLinks: false)
      .where((e) => Const.uninstallerPattern.hasMatch(e.path))
      .isNotEmpty;
}

final _downloadProgressProvider = StateProvider<Progress?>((ref) {
  return null;
});

class AppUpdaterGroup extends ConsumerWidget {
  final Version version;

  const AppUpdaterGroup({Key? key, required this.version}) : super(key: key);

  void downloadAndOpen(WidgetRef ref) {
    ref.read(_downloadProgressProvider.notifier).update((_) => Progress(count: 0, total: 100));
    getDownloadsDirectory().then((downloadDir) {
      final isInstallerMode_ = isInstallerMode();
      final downloadUrl = isInstallerMode_
          ? Const.appExeUrl(version: version.toString())
          : Const.appZipUrl(version: version.toString());
      final downloadPath = "${downloadDir!.path}/${Uri.parse(downloadUrl).pathSegments.last}";
      logger.d("$downloadUrl, $downloadPath");
      Dio().download(
        downloadUrl,
        downloadPath,
        onReceiveProgress: (int count, int total) {
          ref.read(_downloadProgressProvider.notifier).update((_) => Progress(count: count, total: total));
        },
      ).then((_) {
        ref.read(_downloadProgressProvider.notifier).update((_) => null);
        openEntity(isInstallerMode_ ? File(downloadPath) : File(downloadPath).parent);
      });
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final downloadProgress = ref.watch(_downloadProgressProvider);
    return ListCard(
      title: "$tr_dashboard.app_updater.title".tr(),
      padding: EdgeInsets.zero,
      children: [
        ListTile(
          title: Text("$tr_dashboard.app_updater.subtitle".tr()),
          subtitle: downloadProgress == null
              ? null
              : LinearPercentIndicator(
                  animation: true,
                  animationDuration: 200,
                  animateFromLastPercent: true,
                  lineHeight: 20,
                  percent: downloadProgress.progress,
                  center: Text("${downloadProgress.percent}%"),
                  barRadius: const Radius.circular(8),
                  progressColor: theme.colorScheme.primary,
                ),
          onTap: downloadProgress != null ? null : () => downloadAndOpen(ref),
        ),
      ],
    );
  }
}

class DashboardPage extends ConsumerWidget {
  const DashboardPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final VersionCheckResult? result = ref.watch(appVersionCheckLoader).asData?.value;
    return ListTilePageRootWidget(
      children: [
        if (result?.isUpdatable ?? false) AppUpdaterGroup(version: result!.latest!),
        const Center(
          child: Text("Under Construction"),
        )
      ],
    );
  }
}
