import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:percent_indicator/percent_indicator.dart';
import 'package:version/version.dart';

import '/const.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/common.dart';
import '/src/gui/statistics.dart';

// ignore: constant_identifier_names
const tr_dashboard = "pages.dashboard";

final _downloadProgressProvider = StateProvider<Progress?>((ref) {
  return null;
});

final _newsMarkdownLoader = FutureProvider<String>((ref) async {
  try {
    return Dio().get(Const.newsUrl).then((response) => response.toString());
  } catch (error, stackTrace) {
    logger.e("Failed to load news.", error, stackTrace);
    captureException(error, stackTrace);
    rethrow;
  }
});

class AppUpdaterGroup extends ConsumerWidget {
  final Version version;

  const AppUpdaterGroup({Key? key, required this.version}) : super(key: key);

  void downloadAndOpen(WidgetRef ref) {
    ref.read(_downloadProgressProvider.notifier).update((_) => Progress(count: 0, total: 100));
    final isInstallerMode = ref.watch(isInstallerModeLoader).asData!.value;
    final pathInfo = ref.watch(pathInfoProvider);
    final downloadUrl =
        isInstallerMode ? Const.appExeUrl(version: version.toString()) : Const.appZipUrl(version: version.toString());
    final FilePath downloadPath = pathInfo.downloadDir.filePath(Uri.parse(downloadUrl).pathSegments.last);
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
  }

  Widget downloadProgressWidget(BuildContext context, WidgetRef ref, Progress progress) {
    final theme = Theme.of(context);
    final isInstallerMode = ref.watch(isInstallerModeLoader).asData!.value;
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
          child: (downloadProgress == null) ? Container() : downloadProgressWidget(context, ref, downloadProgress),
        ),
      ],
    );
  }
}

class _NewsGroup extends ConsumerWidget {
  const _NewsGroup({Key? key}) : super(key: key);

  Widget text(String data) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Align(
        alignment: Alignment.topLeft,
        child: Text(data),
      ),
    );
  }

  Widget markdown(String data) {
    return Markdown(
      data: data,
      shrinkWrap: true,
      extensionSet: md.ExtensionSet.gitHubFlavored,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loader = ref.watch(_newsMarkdownLoader);
    return ListCard(
      title: "$tr_dashboard.news.title".tr(),
      padding: EdgeInsets.zero,
      children: [
        loader.guarded((data) => markdown(data)),
      ],
    );
  }
}

class _StatisticGroup extends ConsumerWidget {
  const _StatisticGroup({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListCard(
      title: "$tr_dashboard.statistic.title".tr(),
      padding: const EdgeInsets.all(16),
      children: [
        StaggeredGrid.extent(
          maxCrossAxisExtent: 300,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          children: [
            NumberOfRecordStatisticWidget.asTile(),
            MaxEvaluationValueStatisticWidget.asTile(),
            MonthlyFansStatisticWidget.asTile(),
            CountSRankStatisticWidget.asTile(),
            CountStrategyStatisticWidget.asTile(),
          ],
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
        const _NewsGroup(),
        const _StatisticGroup(),
      ],
    );
  }
}
