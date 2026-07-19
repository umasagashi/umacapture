import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:percent_indicator/percent_indicator.dart';
import 'package:version/version.dart';

import '/const.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/common.dart';
import '/src/gui/module_update_dialog.dart';
import '/src/gui/statistics.dart';
import '/src/gui/theme_extensions.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_dashboard = "pages.dashboard";

final _downloadProgressProvider = settableNotifierProvider<Progress?>(null);

final _newsMarkdownLoader = FutureProvider<String>((ref) async {
  try {
    final response = await createDiagnosticDio(operation: "load_news").get(Const.newsUrl);
    return response.toString();
  } catch (error, stackTrace) {
    logger.e("Failed to load news.", error, stackTrace);
    captureException(error, stackTrace);
    rethrow;
  }
});

class AppUpdaterGroup extends ConsumerWidget {
  final Version version;

  const AppUpdaterGroup({super.key, required this.version});

  /// Renders [error] as a single short line for the failure toast.
  ///
  /// Deliberately descriptive rather than diagnostic: it reports what the OS or
  /// the HTTP layer actually said instead of guessing a cause, so an unfamiliar
  /// failure is not mislabelled as a familiar one.
  static String describeError(Object error) {
    final String detail = switch (error) {
      FileSystemException(:final osError?) => "${error.message}: ${osError.message} (errno ${osError.errorCode})",
      FileSystemException() => error.message,
      DioException(:final response?) => "${error.type.name}: HTTP ${response.statusCode}",
      DioException() => "${error.type.name}: ${error.message ?? error.error ?? ''}",
      _ => error.toString(),
    };
    // Naming what was being acted on lets the user act on it directly (close
    // whatever holds the file, or check the URL) instead of only learning that
    // something went wrong.
    final String target = switch (error) {
      FileSystemException(:final path?) => "\n$path",
      DioException(:final requestOptions) => "\n${requestOptions.uri}",
      _ => "",
    };
    const limit = 300;
    final trimmed = detail.trim();
    return (trimmed.length <= limit ? trimmed : "${trimmed.substring(0, limit)}...") + target;
  }

  void downloadAndOpen(WidgetRef ref) {
    // Capture the (top-level, non-autoDispose) provider objects before the async chain so the deferred
    // callbacks never touch the build-phase WidgetRef after this card is disposed (e.g. tab switch).
    final progress = ref.read(_downloadProgressProvider.notifier);
    final pathInfo = ref.read(pathInfoProvider);
    progress.set(Progress(count: 0, total: 100));
    ref
        .read(isInstallerModeLoader.future)
        .then((isInstallerMode) {
          final downloadUrl = isInstallerMode ? Const.appExeUrl(version: version) : Const.appZipUrl(version: version);
          final String fileName = Uri.parse(downloadUrl).pathSegments.last;
          final FilePath downloadPath = pathInfo.downloadDir.filePath(fileName);
          // Stream into a sibling temp file and rename on success, so an aborted
          // transfer never leaves a truncated executable under the real name for
          // the user to run. Sibling, not tempDir: a rename cannot cross volumes.
          final FilePath incompletePath = pathInfo.downloadDir.filePath("$fileName.part");
          logger.d("Downloading the app update from $downloadUrl to ${downloadPath.path}");
          // Always discard a previous artifact rather than reusing it: its
          // provenance is unknown (it may be a truncated or tampered-with file
          // from an earlier run). Deleting up front also surfaces a locked
          // destination here, before spending a 50 MB transfer that could only
          // fail at the rename.
          downloadPath.deleteSync(emptyOk: true);
          incompletePath.deleteSync(emptyOk: true);
          return createDiagnosticDio(operation: "download_app_update")
              .download(
                downloadUrl,
                incompletePath.path,
                onReceiveProgress: (int count, int total) {
                  progress.set(Progress(count: count, total: total));
                },
              )
              .then((_) {
                incompletePath.renameSync(downloadPath);
                progress.set(null);
                return (isInstallerMode ? downloadPath : downloadPath.parent).launch();
              })
              .onError<Object>((error, stackTrace) {
                // Drop the half-written temp file so an abandoned download does
                // not strand 50 MB in the user's Downloads folder. Best-effort:
                // a cleanup failure must not replace the error being reported.
                try {
                  incompletePath.deleteSync(emptyOk: true);
                } catch (cleanupError) {
                  logger.w("Failed to remove the incomplete app update download.", cleanupError);
                }
                throw error;
              });
        })
        .catchError((Object error, StackTrace stackTrace) {
          // Reset the progress so the card stops spinning and becomes tappable again;
          // without this a failed download leaves it stuck on the spinner forever.
          // Report at error level and to Sentry: this was the only network
          // operation that stayed a local warning, which left production failures
          // with no trace at all.
          logger.e("Failed to download the app update.", error, stackTrace);
          if (error is DioException) {
            logger.e(
              "App update download detail: type=${error.type} url=${error.requestOptions.uri} "
              "status=${error.response?.statusCode} inner=${error.error} (${error.error.runtimeType})",
            );
          }
          captureException(error, stackTrace);
          progress.set(null);
          Toaster.show(
            ToastData.error(
              description: "$tr_dashboard.app_updater.download_failed.template".tr(
                namedArgs: {"error": describeError(error)},
              ),
            ),
          );
        });
  }

  Widget downloadProgressWidget(BuildContext context, WidgetRef ref, Progress progress) {
    final theme = Theme.of(context);
    return ref.watch(isInstallerModeLoader).guarded((isInstallerMode) {
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
            child: Text(
              "$tr_dashboard.app_updater.downloading.template".tr(
                namedArgs: {
                  "file": isInstallerMode
                      ? "$tr_dashboard.app_updater.downloading.exe".tr()
                      : "$tr_dashboard.app_updater.downloading.zip".tr(),
                },
              ),
            ),
          ),
        ],
      );
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloadProgress = ref.watch(_downloadProgressProvider);
    return ListCard(
      title: "$tr_dashboard.app_updater.title".tr(),
      titleColor: Theme.of(context).semantic.noticeContainer,
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

/// Persistent dashboard card shown when the recognition module could not be
/// obtained automatically (capture is unavailable). Mirrors [AppUpdaterGroup]
/// and opens the manual update dialog so the user can recover offline.
class ModuleUpdaterGroup extends ConsumerWidget {
  const ModuleUpdaterGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListCard(
      title: "$tr_dashboard.module_updater.title".tr(),
      titleColor: Theme.of(context).semantic.noticeContainer,
      padding: EdgeInsets.zero,
      children: [
        ListTile(
          title: Text("$tr_dashboard.module_updater.subtitle".tr()),
          onTap: () => ModuleManualUpdateDialog.show(ref.base),
        ),
      ],
    );
  }
}

class _NewsGroup extends ConsumerWidget {
  const _NewsGroup();

  Widget text(String data) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Align(alignment: Alignment.topLeft, child: Text(data)),
    );
  }

  Widget markdown(String data) {
    return Markdown(data: data, shrinkWrap: true, extensionSet: md.ExtensionSet.gitHubFlavored);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loader = ref.watch(_newsMarkdownLoader);
    return ListCard(
      title: "$tr_dashboard.news.title".tr(),
      padding: EdgeInsets.zero,
      children: [loader.guarded((data) => markdown(data))],
    );
  }
}

class _StatisticGroup extends ConsumerWidget {
  const _StatisticGroup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListCard(
      title: "$tr_dashboard.statistic.title".tr(),
      padding: const EdgeInsets.all(16),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("$tr_dashboard.statistic.description".tr()),
        const SizedBox(height: 12),
        // Fixed-size cells: constrain the grid's width to a whole number of cells
        // so StaggeredGrid.extent renders each 1x1 tile at exactly [cellSize]
        // (it always stretches tiles to fill the width it is given). Any leftover
        // width becomes a right-side margin via the top-left alignment, instead of
        // inflating the cells.
        LayoutBuilder(
          builder: (context, constraints) {
            const cellSize = 220.0;
            const spacing = 16.0;
            final available = constraints.maxWidth;
            final columns = Math.max(1, ((available + spacing) / (cellSize + spacing)).floor());
            final gridWidth = Math.min(available, columns * (cellSize + spacing) - spacing);
            // Fill the full available width and left-align the fixed-width grid
            // inside it. Without this the body block shrinks to the grid width and
            // the card's (center-aligned) outer column would center the whole
            // block; filling the width keeps it flush left with the description.
            return Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                SizedBox(
                  width: gridWidth,
                  child: StaggeredGrid.extent(
                    maxCrossAxisExtent: cellSize,
                    mainAxisSpacing: spacing,
                    crossAxisSpacing: spacing,
                    children: [
                      NumberOfRecordStatisticWidget.asTile(),
                      CountStrategyStatisticWidget.asTile(),
                      MonthlyFansStatisticWidget.asTile(),
                      EvaluationTrendStatisticWidget.asTile(),
                      EvaluationRankingStatisticWidget.asTile(),
                      SkillCountRankingStatisticWidget.asTile(),
                      FactorCountRankingStatisticWidget.asTile(),
                      G1WinningRankingStatisticWidget.asTile(),
                      MostFrequentCharacterStatisticWidget.asTile(),
                      MostFrequentSkillStatisticWidget.asTile(),
                      MostFrequentFactorStatisticWidget.asTile(),
                      CountSRankStatisticWidget.asTile(),
                      CountBlueFactorStatisticWidget.asTile(),
                      CountRedFactorStatisticWidget.asTile(),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

final _versionCheckLoader = FutureProvider<AppVersionCheckResult>((ref) async {
  late final AppVersionCheckResult result;
  await Future.wait([
    ref.watch(appVersionCheckLoader.future).then((e) => result = e),
    ref.watch(isInstallerModeLoader.future),
  ]);
  return result;
});

@RoutePage()
class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(_versionCheckLoader).asData?.value;
    // Watch moduleVersionLoader to ensure the automatic check runs, then drive
    // the banner from the failure state (true when the module could not be
    // obtained OR the latest could not be downloaded but an old one is in use).
    // hasError is a fallback for an unexpected exception inside the loader.
    final moduleAsync = ref.watch(moduleVersionLoader);
    final moduleUpdateFailed = ref.watch(moduleUpdateFailedProvider) || moduleAsync.hasError;
    return ListTilePageRootWidget(
      children: [
        if (moduleUpdateFailed) const ModuleUpdaterGroup(),
        if (result?.isUpdatable ?? false) AppUpdaterGroup(version: result!.latest),
        const _NewsGroup(),
        const _StatisticGroup(),
      ],
    );
  }
}
