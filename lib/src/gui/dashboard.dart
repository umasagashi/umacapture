import 'dart:io';
import 'dart:typed_data';

import 'package:auto_route/auto_route.dart';
import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:percent_indicator/percent_indicator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:version/version.dart';

import '/const.dart';
import '/src/chara_detail/storage.dart';
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

/// Loads the announcement markdown. Public (with [NewsGroup]) only so a test can
/// override it; nothing outside this library watches it.
final newsMarkdownLoader = FutureProvider<String>((ref) async {
  try {
    final response = await createDiagnosticDio(operation: "load_news").get(Const.newsUrl);
    return response.toString();
  } catch (error, stackTrace) {
    logger.e("Failed to load news.", error, stackTrace);
    captureException(error, stackTrace);
    rethrow;
  }
});

/// Which artefact an app-update download is supposed to be.
///
/// The two branches of [AppUpdaterGroup.downloadAndOpen] hand the finished file
/// to the OS in different ways -- the installer is *executed* through
/// ShellExecuteW, the portable build is only revealed in the file manager -- so
/// what counts as an acceptable payload differs per branch. Naming the branch as
/// data keeps the refusal, the log line and the toast reading the same value
/// instead of three places re-deriving it from `isInstallerMode`.
enum AppUpdatePayloadKind {
  /// The Inno Setup installer (`…-windows.exe`), which the app runs.
  installer("exe"),

  /// The portable zip (`…-windows.zip`), which the app only reveals.
  archive("zip");

  const AppUpdatePayloadKind(this.translationKey);

  /// The leaf under `pages.dashboard.app_updater.invalid_payload` naming this
  /// artefact to the user.
  final String translationKey;
}

/// Raised when an app-update download is not the artefact its branch expects.
///
/// A distinct type rather than a [FormatException] because the toast has to say
/// something else for it: the transfer *succeeded*, so "the download failed" on
/// its own would send the user to look at their network. [reason] is English and
/// only reaches the log and Sentry; the user-visible sentence comes from
/// `ja.json` via [AppUpdaterGroup.describeError].
class AppUpdatePayloadException implements Exception {
  const AppUpdatePayloadException(this.kind, this.reason);

  final AppUpdatePayloadKind kind;

  /// Why the bytes were refused, in enough detail to tell a captive portal from
  /// a truncated transfer without re-downloading.
  final String reason;

  @override
  String toString() => "AppUpdatePayloadException(${kind.name}): $reason";
}

/// How much of the downloaded file [requireAppUpdatePayload] inspects.
///
/// The PE signature sits at the offset stored at 0x3c, immediately after the DOS
/// stub, which every Windows linker keeps a few hundred bytes long; 4 KiB is the
/// first page and leaves an order of magnitude of headroom. Bounded on purpose:
/// the payload is a ~50 MB installer and this runs on the UI isolate.
const _appUpdateHeaderProbeBytes = 4096;

/// Refuses [path] unless its first bytes are structurally the artefact [kind]
/// says the app is about to hand to the OS, and **removes the download when it
/// refuses**.
///
/// The gap this closes: `downloadAndOpen` used to rename whatever the server
/// returned to `…-windows.exe` and execute it. A response that is not a program
/// at all -- a captive-portal login page, a proxy error page, a transfer cut
/// short -- arrives with a 200 and no exception, so nothing downstream noticed.
/// This is the same discipline the module updater applies in
/// `version_check.dart` (`_requireModulePayload`), on the side whose failure
/// mode is code execution rather than a bad extraction.
///
/// **This is a shape check, not an authenticity check.** It tests that the bytes
/// are a Windows executable / a zip; it says nothing about *whose*. A payload
/// that is a well-formed but hostile program passes. Authenticity would need an
/// out-of-band trust anchor (Authenticode, or a hash published outside the same
/// release asset) and is deliberately not attempted here.
///
/// The predicate is a positive structural test -- the file must *be* a PE (or a
/// zip local file header) -- rather than a list of known-bad prefixes, so a
/// payload nobody thought of is refused by default instead of by omission.
///
/// Deleting is part of refusing, not a courtesy of the caller: a refused
/// download must not stay in the user's Downloads folder where it could be run
/// by hand. Best-effort and logged, because a cleanup failure must not replace
/// the refusal being reported.
///
/// Public only so the refusal can be tested; nothing outside this library calls it.
///
/// Throws an [AppUpdatePayloadException] when the bytes are not that artefact.
@visibleForTesting
Future<void> requireAppUpdatePayload(FilePath path, AppUpdatePayloadKind kind) async {
  final Uint8List header = await _readFileHeader(path, _appUpdateHeaderProbeBytes);
  final String? reason = switch (kind) {
    AppUpdatePayloadKind.installer => _portableExecutableRejection(header),
    AppUpdatePayloadKind.archive => _zipRejection(header),
  };
  if (reason == null) {
    return;
  }
  logger.e("Refusing the app update payload at ${path.path}. kind=${kind.name}, reason=$reason");
  try {
    await path.delete(emptyOk: true);
  } catch (cleanupError, cleanupStack) {
    logger.w("Failed to remove the refused app update download.", cleanupError, cleanupStack);
  }
  throw AppUpdatePayloadException(kind, reason);
}

/// At most [maxBytes] leading bytes of [path], or fewer when the file is shorter.
///
/// Reads through `dart:io` rather than the [FsBackend] because that interface has
/// no bounded read and this path is Windows-only anyway (the downloads directory
/// and ShellExecuteW have no web counterpart); pulling the whole file through
/// `readAsBytes` would allocate the entire installer to look at 4 KiB.
Future<Uint8List> _readFileHeader(FilePath path, int maxBytes) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in path.toFile().openRead(0, maxBytes)) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// Why [header] is not the start of a Windows executable, or null when it is.
///
/// Checks the chain a loader itself follows: the `MZ` DOS magic, the `e_lfanew`
/// offset at 0x3c, and the `PE\0\0` signature it points at. Following the offset
/// is what makes this more than a two-byte test -- a text file that happens to
/// start with "MZ", or an installer truncated inside its DOS stub, has no
/// signature at the stated place.
String? _portableExecutableRejection(Uint8List header) {
  if (header.length < 0x40) {
    return "the payload is ${header.length} bytes, too short to hold a DOS header";
  }
  if (header[0] != 0x4d || header[1] != 0x5a) {
    return "the payload does not start with the MZ DOS magic "
        "(0x${header[0].toRadixString(16)} 0x${header[1].toRadixString(16)})";
  }
  final int peOffset = ByteData.sublistView(header).getUint32(0x3c, Endian.little);
  if (peOffset + 4 > header.length) {
    return "the PE signature offset ($peOffset) lies past the ${header.length} bytes available";
  }
  const signature = [0x50, 0x45, 0x00, 0x00];
  for (var i = 0; i < signature.length; i++) {
    if (header[peOffset + i] != signature[i]) {
      return "there is no PE signature at offset $peOffset";
    }
  }
  return null;
}

/// Why [header] is not the start of a zip holding at least one entry, or null
/// when it is.
///
/// The local file header magic, not the end-of-central-directory one, so an
/// *empty* archive is refused too -- that is the shape a captive-portal page
/// decodes into, and the case `version_check.dart` documents as the reason the
/// module refusal exists.
String? _zipRejection(Uint8List header) {
  const signature = [0x50, 0x4b, 0x03, 0x04];
  if (header.length < signature.length) {
    return "the payload is ${header.length} bytes, too short to hold a zip entry header";
  }
  for (var i = 0; i < signature.length; i++) {
    if (header[i] != signature[i]) {
      return "the payload does not start with a zip local file header";
    }
  }
  return null;
}

class AppUpdaterGroup extends ConsumerWidget {
  final Version version;

  const AppUpdaterGroup({super.key, required this.version});

  /// The whole sentence the failure toast shows for [error].
  ///
  /// The **outer** template is chosen per failure kind, not fixed. A refused
  /// payload is not a failed download: the transfer completed, and wrapping the
  /// refusal in "the download failed" sends the user to check their connection
  /// and retry — the two things that cannot help when a proxy is answering for
  /// the release server. Composing here rather than at the call site keeps the
  /// choice of wrapper and the detail it wraps in one place, so a test can
  /// assert the string the user actually reads.
  static String describeFailure(Object error) {
    final String template = switch (error) {
      AppUpdatePayloadException() => "$tr_dashboard.app_updater.download_rejected.template",
      _ => "$tr_dashboard.app_updater.download_failed.template",
    };
    return template.tr(namedArgs: {"error": describeError(error)});
  }

  /// Renders [error] as a single short line for the failure toast.
  ///
  /// Deliberately descriptive rather than diagnostic: it reports what the OS or
  /// the HTTP layer actually said instead of guessing a cause, so an unfamiliar
  /// failure is not mislabelled as a familiar one.
  static String describeError(Object error) {
    final String detail = switch (error) {
      // The transfer itself succeeded here, so the HTTP/OS wording above would
      // point the user at the wrong thing. Say what was refused and that it was
      // removed, and leave [AppUpdatePayloadException.reason] to the log.
      AppUpdatePayloadException(:final kind) => "$tr_dashboard.app_updater.invalid_payload.template".tr(
        namedArgs: {"file": "$tr_dashboard.app_updater.invalid_payload.${kind.translationKey}".tr()},
      ),
      FileSystemException(:final osError?) => "${error.message}: ${osError.message} (errno ${osError.errorCode})",
      FileSystemException() => error.message,
      DioException(:final response?) => "${error.type.name}: HTTP ${response.statusCode}",
      DioException() => "${error.type.name}: ${error.message ?? error.error ?? ''}",
      // url_launcher wraps ShellExecuteW failures (e.g. launching the finished
      // installer) in a PlatformException whose message already names the
      // target and the OS error code; toString would bury it in "(code, ...,
      // null, null)" noise.
      PlatformException() => error.message ?? error.code,
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
        .then((isInstallerMode) async {
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
          // fail at the rename. Async variants: a locked file makes the delete
          // retry, and the sync retry would stall the UI isolate.
          await downloadPath.delete(emptyOk: true);
          await incompletePath.delete(emptyOk: true);
          return createDiagnosticDio(operation: "download_app_update")
              .download(
                downloadUrl,
                incompletePath.path,
                onReceiveProgress: (int count, int total) {
                  progress.set(Progress(count: count, total: total));
                },
              )
              .then((_) async {
                // Refuse a response that is not the artefact this branch is
                // about to hand to the OS, before it is renamed into place: a
                // 200 carrying a portal login page or a truncated transfer
                // would otherwise be executed. Shape only -- see
                // [requireAppUpdatePayload] for what this does not buy.
                await requireAppUpdatePayload(
                  incompletePath,
                  isInstallerMode ? AppUpdatePayloadKind.installer : AppUpdatePayloadKind.archive,
                );
                await incompletePath.rename(downloadPath);
                progress.set(null);
                return (isInstallerMode ? downloadPath : downloadPath.parent).launch();
              })
              .onError<Object>((error, stackTrace) async {
                // Drop the half-written temp file so an abandoned download does
                // not strand 50 MB in the user's Downloads folder. Best-effort:
                // a cleanup failure must not replace the error being reported.
                try {
                  await incompletePath.delete(emptyOk: true);
                } catch (cleanupError) {
                  logger.w("Failed to remove the incomplete app update download.", cleanupError);
                }
                Error.throwWithStackTrace(error, stackTrace);
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
          Toaster.show(ToastData.error(description: describeFailure(error)));
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

/// What this app is, and where its community lives — the card a first-time visitor lands on.
///
/// **Web only.** In a browser the dashboard is the site's front page: someone arrives at a URL with
/// no idea what the thing does, and the tabs beside it (キャプチャ, 殿堂入り管理) only make sense
/// once they do. A desktop user installed this deliberately and has already read the same sentences
/// wherever they downloaded it, so there the card would be a permanent restatement of what they
/// already know. The gate is at the mount site in [DashboardPage] for the reason stated there.
///
/// The three link labels are brand names and are deliberately **not** translated; only the sentence
/// above them is. The URLs are [Const]'s, which are the ones the README publishes.
class AboutGroup extends StatelessWidget {
  const AboutGroup({super.key});

  /// The three destinations, in the order they are listed.
  static final links = <({String label, String url})>[
    (label: "GitHub", url: Const.githubUrl),
    (label: "Discord", url: Const.discordUrl),
    (label: "X", url: Const.xUrl),
  ];

  /// One bullet: the service's name, then its address as an ordinary web link.
  ///
  /// **The URL itself is the link text**, rather than a labelled button, so the reader sees where
  /// they are going before they go — the same thing a browser's status bar would tell them, which an
  /// app has no equivalent of. Underlined and in the primary colour, which is how the app's other
  /// two text links are drawn.
  ///
  /// One paragraph per line (a rich [Text], not a Row of two Texts): a long address then wraps
  /// inside the line instead of overflowing the card on a narrow window.
  ///
  /// **The tap lives on an [InkWell], not on a [TapGestureRecognizer] inside the span.** A span
  /// takes no part in focus traversal, so a recognizer-only link is unreachable for anyone driving
  /// the web build from the keyboard — and this card is the first-time visitor's only route to the
  /// project. The ink covers the whole bullet line rather than just the address, which also gives
  /// the pointer a target that does not require hitting the text exactly; the [Semantics] link flag
  /// and the [MergeSemantics] around it are what make the line arrive at assistive technology as one
  /// focusable link carrying its own address, instead of a button beside a separate run of text.
  Widget _link(BuildContext context, ({String label, String url}) link) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("•"),
          const SizedBox(width: 8),
          Expanded(
            child: MergeSemantics(
              child: Semantics(
                link: true,
                child: InkWell(
                  onTap: () => launchUrl(Uri.parse(link.url)),
                  borderRadius: BorderRadius.circular(4),
                  // Spelled out rather than left to the ink's default, which is
                  // `WidgetStateMouseCursor.adaptiveClickable` — the hand on web and the plain arrow
                  // everywhere else, because a desktop *button* does not show a hand. This is a link,
                  // not a button: the hand is how a reader is told the address is live, and the span
                  // this replaced set it unconditionally for that reason.
                  mouseCursor: SystemMouseCursors.click,
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: "${link.label}: "),
                        TextSpan(
                          text: link.url,
                          style: TextStyle(color: theme.colorScheme.primary, decoration: TextDecoration.underline),
                        ),
                      ],
                    ),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListCard(
      title: "$tr_dashboard.about.title".tr(),
      padding: const EdgeInsets.all(16),
      // `stretch`, not `start`: the card lays its body out in a centre-aligned column, so a body
      // that sizes to its own content is centred as a block — the wrapped sentence and the link list
      // then sit inset from the title above them. Stretching makes the body take the card's full
      // width, which is what puts both flush left, the way the statistics card's body is.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text("$tr_dashboard.about.description".tr()),
        const SizedBox(height: 16),
        for (final link in AboutGroup.links) _link(context, link),
      ],
    );
  }
}

/// The announcement card.
///
/// The fetch is a plain cross-origin GET, which the browser can refuse for
/// reasons the app cannot see or fix (the news origin's CORS headers), so the
/// card is kept on every platform and says that loading failed instead of
/// rendering an empty body that reads as "no announcements". Hiding it on web
/// would trade one silent state for another.
class NewsGroup extends ConsumerWidget {
  const NewsGroup({super.key});

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
    final loader = ref.watch(newsMarkdownLoader);
    return ListCard(
      title: "$tr_dashboard.news.title".tr(),
      padding: EdgeInsets.zero,
      children: [
        loader.when(
          loading: () => const CircularProgressIndicator(),
          // The exception itself is already logged and reported by the loader;
          // what the user needs here is that the card is empty because the fetch
          // failed, not because there is nothing to announce.
          error: (error, _) => text("$tr_dashboard.news.fetch_failed".tr()),
          data: (data) => markdown(data),
        ),
      ],
    );
  }
}

/// The statistics card.
///
/// **The card is shown whatever the store holds; only its body changes.** Hiding it until the
/// records had finished loading was considered and rejected: a user with many records would meet a
/// dashboard with no statistics on it for as long as the scan takes, which is how a feature stops
/// being discovered at all. So the card and its title are unconditional, and an empty store is
/// answered in place of the grid, by a sentence that says what would fill it.
///
/// Public (like [NewsGroup]) only so a widget test can pump it with a store of its own.
@visibleForTesting
class StatisticGroup extends ConsumerWidget {
  const StatisticGroup({super.key});

  /// The body shown when the store has loaded and holds nothing.
  ///
  /// **Only a settled, empty store reaches this.** While the scan is still running the store is
  /// indistinguishable from an empty one by its contents alone, so the loading and error states keep
  /// the grid — whose tiles already have their own spinner and their own failure state — rather than
  /// claiming a user with a full store has captured nobody.
  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text(
          "$tr_dashboard.statistic.empty".tr(),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The loader rather than the synchronous view: `charaDetailRecordStorageProvider` answers
    // `requireValue`, which cannot tell "no records" from "not scanned yet" without throwing, and
    // that distinction is exactly what decides between the two bodies below.
    final records = ref.watch(charaDetailRecordStorageLoaderProvider);
    final isEmpty = records.asData?.value.isEmpty ?? false;
    return ListCard(
      title: "$tr_dashboard.statistic.title".tr(),
      padding: const EdgeInsets.all(16),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("$tr_dashboard.statistic.description".tr()),
        const SizedBox(height: 12),
        if (isEmpty) _empty(context) else _grid(),
      ],
    );
  }

  Widget _grid() {
    // Fixed-size cells: constrain the grid's width to a whole number of cells
    // so StaggeredGrid.extent renders each 1x1 tile at exactly [cellSize]
    // (it always stretches tiles to fill the width it is given). Any leftover
    // width becomes a right-side margin via the top-left alignment, instead of
    // inflating the cells.
    return LayoutBuilder(
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
        // Shown on every platform: the manual update dialog it opens installs
        // from the archive's bytes, so it works in a browser too, and web is the
        // build that most needs it -- its module lives in OPFS, which the
        // browser may evict, and a failed re-fetch is otherwise invisible.
        if (moduleUpdateFailed) const ModuleUpdaterGroup(),
        // The app updater additionally shell-launches what it downloaded, so it
        // is gated on the reveal capability rather than on `!kIsWeb`: the same
        // predicate every other launch affordance uses.
        if (CurrentPlatform.canRevealInFileManager() && (result?.isUpdatable ?? false))
          AppUpdaterGroup(version: result!.latest),
        // UNDER THE TWO NOTICES, NOT ABOVE THEM. Both of those ask the user to do something before
        // the app can work at all — most sharply the module one, which on web means recognition is
        // unavailable until it is dealt with — while this card says the same thing whenever it is
        // read. So on the rare launch where a notice is up, the notice keeps the top.
        //
        // Gated here rather than inside [AboutGroup] so that the card, which is a fixed sentence
        // and three links, stays renderable by a widget test on the VM; `CurrentPlatform.isWeb()`
        // is const false there, and a self-gating widget would answer an empty box to every test.
        if (CurrentPlatform.isWeb()) const AboutGroup(),
        const NewsGroup(),
        const StatisticGroup(),
      ],
    );
  }
}
