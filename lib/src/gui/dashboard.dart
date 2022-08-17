import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:percent_indicator/percent_indicator.dart';
import 'package:version/version.dart';

import '/const.dart';
import '/src/core/path_entity.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_dashboard = "pages.dashboard";

bool _isInstallerMode() {
  return FilePath.resolvedExecutable.parent
      .listSync(recursive: false, followLinks: false)
      .where((e) => Const.uninstallerPattern.hasMatch(e.path))
      .isNotEmpty;
}

final _downloadProgressProvider = StateProvider<Progress?>((ref) {
  return null;
});

class AppUpdaterGroup extends ConsumerWidget {
  final Version version;
  final bool isInstallerMode = _isInstallerMode();

  AppUpdaterGroup({Key? key, required this.version}) : super(key: key);

  void downloadAndOpen(WidgetRef ref) {
    ref.read(_downloadProgressProvider.notifier).update((_) => Progress(count: 0, total: 100));
    getDownloadsDirectory().then((downloadDir) {
      final downloadUrl =
          isInstallerMode ? Const.appExeUrl(version: version.toString()) : Const.appZipUrl(version: version.toString());
      final FilePath downloadPath = DirectoryPath(downloadDir).filePath(Uri.parse(downloadUrl).pathSegments.last);
      logger.d("$downloadUrl, ${downloadPath.path}");
      Dio().download(
        downloadUrl,
        downloadPath.path,
        onReceiveProgress: (int count, int total) {
          ref.read(_downloadProgressProvider.notifier).update((_) => Progress(count: count, total: total));
        },
      ).then((_) {
        ref.read(_downloadProgressProvider.notifier).update((_) => null);
        (isInstallerMode ? downloadPath : downloadPath.parent).launch();
      });
    });
  }

  Widget downloadProgressWidget(BuildContext context, Progress progress) {
    final theme = Theme.of(context);
    return Flex(
      direction: Axis.horizontal,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: CircularPercentIndicator(
            radius: 32.0,
            lineWidth: 6.0,
            animation: true,
            animateFromLastPercent: true,
            animationDuration: 200,
            percent: progress.progress,
            center: Text("${progress.percent}%"),
            progressColor: theme.colorScheme.primary,
            backgroundColor: theme.colorScheme.secondaryContainer,
          ),
        ),
        Flexible(
          child: Text("$tr_dashboard.app_updater.downloading.template".tr(namedArgs: {
            "file": isInstallerMode
                ? "$tr_dashboard.app_updater.downloading.exe".tr()
                : "$tr_dashboard.app_updater.downloading.zip".tr(),
          })),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloadProgress = ref.watch(_downloadProgressProvider);
    return ListCard(
      title: "$tr_dashboard.app_updater.title".tr(),
      padding: EdgeInsets.zero,
      children: [
        ListTile(
          title: Text("$tr_dashboard.app_updater.subtitle".tr()),
          onTap: downloadProgress != null ? null : () => downloadAndOpen(ref),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: (downloadProgress == null) ? Container() : downloadProgressWidget(context, downloadProgress),
        ),
      ],
    );
  }
}

class DashboardPage extends ConsumerWidget {
  const DashboardPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppVersionCheckResult? result = ref.watch(appVersionCheckLoader).asData?.value;
    return ListTilePageRootWidget(
      children: [
        if (result?.isUpdatable ?? false) AppUpdaterGroup(version: result!.latest),
        const Center(
          child: Text("Under Construction"),
        )
      ],
    );
  }
}
