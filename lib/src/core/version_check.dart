import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recase/recase.dart';
import 'package:version/version.dart';

import '/const.dart';
import '/src/app/route.dart';
import '/src/core/mapper_init.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
// For [statedReportContext] / [reportValueNotStated]. The sweep lives beside the video-import
// report because that is where the device measurement that produced it was taken, and it is a
// pure file both the web and the Windows leg can compile; what it answers -- whether a value a
// report carries reaches the reader -- is a property of publishing to Sentry, not of video
// import, so every context this app sets goes through it rather than each one inventing a
// spelling for "unstated".
import '/src/core/video_import_ops.dart';
import '/src/gui/toast.dart';
import '/src/preference/storage_box.dart';

part 'version_check.mapper.dart';

// ignore: constant_identifier_names
const tr_toast = "toast";

class ModuleVersion {
  final DateTime recognizerVersion;
  final DateTime minimumVersion;

  ModuleVersion({required this.recognizerVersion, required this.minimumVersion});
}

@MappableClass(caseStyle: CaseStyle.snakeCase)
class ModuleVersionRawData with ModuleVersionRawDataMappable {
  final String formatVersion;
  final String region;
  final String recognizerVersion;

  final String minimumVersion;

  final String applicationVersion;

  final bool pinVersion;

  ModuleVersionRawData(
    this.formatVersion,
    this.region,
    this.recognizerVersion, [
    this.minimumVersion = "2021-02-24T00:00:00+0900",
    this.applicationVersion = "0.0.0",
    this.pinVersion = false,
  ]);

  /// The two dates this module states, or `null` when either cannot be read.
  ///
  /// Both fields are reference points a gate compares records against:
  /// `recognizer_version` decides which stored records count as obsolete and are
  /// re-recognised without asking, and `minimum_version` is the only thing that
  /// keeps a record too old for the current models out of that batch. Parsed
  /// with the stand-in date instead, an unreadable field made *every* record
  /// obsolete and *every* record supported at once -- the two gates failed open
  /// together, and the second one is only noticed after the overwrite.
  ///
  /// Null is not a new outcome to handle: this whole conversion already feeds
  /// providers typed `ModuleVersion?`, and null there means the re-recognition
  /// check does not run and the user is shown the `noVersionAvailable` toast.
  /// A module whose dates cannot be read is exactly a module there is no
  /// version available for.
  ModuleVersion? toModuleVersion() {
    final recognizer = recognizerVersion.toDateTimeOrNull();
    final minimum = minimumVersion.toDateTimeOrNull();
    if (recognizer == null || minimum == null) {
      return null;
    }
    return ModuleVersion(recognizerVersion: recognizer, minimumVersion: minimum);
  }

  static Future<ModuleVersionRawData?> load(FilePath file) async {
    if (!await file.exists()) {
      return Future.value(null);
    }
    initializeMappers();
    try {
      return await file.readAsString().then((content) => ModuleVersionRawDataMapper.fromJson(content));
    } catch (e) {
      return null;
    }
  }

  static Future<ModuleVersionRawData?> download(Uri url) async {
    initializeMappers();
    return await createDiagnosticDio(
      operation: "check_latest_module_version",
    ).get(url.toString()).then((response) => ModuleVersionRawDataMapper.fromJson(response.toString()));
  }
}

enum ModuleVersionCheckResultCode {
  noUpdateRequired,
  updated,
  latestVersionNotAvailable,
  noVersionAvailable,
  accessDenied,
  manualUpdateSuccess,
  manualUpdateFailure,
}

// Failure codes whose toast offers a tap-through to the settings page, where
// the manual module update entry lives.
const _moduleVersionCheckFailureCodes = {
  ModuleVersionCheckResultCode.noVersionAvailable,
  ModuleVersionCheckResultCode.latestVersionNotAvailable,
  ModuleVersionCheckResultCode.accessDenied,
};

/// Whether [exception] is the Windows "access denied" file error (errorCode 5),
/// which we surface with a dedicated permissions toast rather than a generic one.
bool _isAccessDeniedError(Object exception) => exception is FileSystemException && exception.osError?.errorCode == 5;

void sendModuleVersionCheckToast(ToastType type, ModuleVersionCheckResultCode code) {
  // This function can be called before EasyLocalization is initialized.
  // For this reason, a delay is required for now.
  final navigateOnTab = _moduleVersionCheckFailureCodes.contains(code) ? const SettingsRoute() : null;
  Future.delayed(const Duration(milliseconds: 300), () {
    Toaster.show(
      ToastData(
        type: type,
        description: "$tr_toast.module_version_check.${code.name.snakeCase}".tr(),
        navigateOnTab: navigateOnTab,
      ),
    );
  });
}

/// What this side can say about the platform the failure happened on.
///
/// [isWeb] is a parameter rather than a read of [kIsWeb] because two of these three values
/// do not exist on web, and `flutter test` only ever runs on the VM: taking it as an
/// argument is what lets the web shape -- the one where they are unstated -- be built and
/// read by a test at all.
///
/// Platform.operatingSystem / operatingSystemVersion / localeName all throw
/// UnsupportedError on web (the dart2wasm io patch has no host to report), and this map is
/// built from failure handlers -- _bootstrapWebModule's catch runs on web -- so reading
/// them there would replace a recoverable "no module" with a hard error. The ternaries
/// short-circuit before the read, so nothing is evaluated that cannot answer.
@visibleForTesting
Map<String, dynamic> platformDescription({required bool isWeb}) => {
  "os": isWeb ? "web" : Platform.operatingSystem,
  "os_version": isWeb ? null : Platform.operatingSystemVersion,
  "locale": isWeb ? null : Platform.localeName,
};

/// The failure as this side measured it, with an unstated value left as a null.
///
/// Nothing publishes this map: [networkFailureContext] is what reaches Sentry. The two are
/// separate because "what could be measured" and "what a reader receives" are different
/// questions, and only the second one has to answer for a null.
Map<String, dynamic> _measuredNetworkException({
  required String operation,
  required Object exception,
  String? url,
  required bool isWeb,
}) {
  final dioError = exception is DioException ? exception : null;
  final requestUri = dioError?.requestOptions.uri;
  final fallbackUri = url == null ? null : Uri.tryParse(url);
  final uri = requestUri ?? fallbackUri;
  final response = dioError?.response;
  final innerError = dioError?.error;

  return {
    "operation": operation,
    "url": uri?.toString() ?? url,
    "host": uri?.host,
    "scheme": uri?.scheme,
    "dio_type": dioError?.type.toString(),
    "http_status": response?.statusCode,
    "inner_error_type": innerError?.runtimeType.toString(),
    "inner_error": innerError?.toString(),
    "is_handshake_error": exception is HandshakeException || innerError is HandshakeException,
    ...platformDescription(isWeb: isWeb),
  };
}

/// The `network_failure` context exactly as [logNetworkException] publishes it.
///
/// **No key on it is a null.** A null-valued context key does not survive the trip: Sentry's
/// normalisation drops it, so the reader gets a context that is silently shorter than the
/// code says it is -- measured on a stored event, where every null-valued key of a report
/// built this way was absent while an empty string arrived intact. Nine of the twelve keys
/// here can be unstated (`url`, `host`, `scheme`, `dio_type`, `http_status`,
/// `inner_error_type`, `inner_error`, `os_version`, `locale`), each for its own reason -- the
/// failure was not a Dio one, the response never arrived, the platform is web -- and a reader
/// who receives none of them cannot tell "this was not an HTTP response" from "this side
/// never read the status".
///
/// So every one of them is published as [reportValueNotStated] instead, by the same sweep the
/// video-import report uses. It is [statedReportContext] and deliberately **not** a
/// `?? reportValueNotStated` written at each key: the defect is a value going missing in
/// silence, and a per-key table is the shape that lets the next key go missing.
///
/// Public so what is published can be read by a test; nothing outside this library calls it.
@visibleForTesting
Map<String, dynamic> networkFailureContext({
  required String operation,
  required Object exception,
  String? url,
  bool isWeb = kIsWeb,
}) =>
    statedReportContext(_measuredNetworkException(operation: operation, exception: exception, url: url, isWeb: isWeb));

/// The tags that go with a failure whose published context is [context].
///
/// **Tags are the opposite case from the context, on purpose.** A tag is a filter over an
/// issue list: an absent tag narrows nothing, while a `not stated` bucket invites someone to
/// filter on a state a request can never actually be in. So a value the context states as
/// [reportValueNotStated] is *omitted* here rather than tagged with it. (Same ruling as the
/// video-import report's tags.)
///
/// Public so the omission can be read by a test; nothing outside this library calls it.
@visibleForTesting
Map<String, String> networkFailureTags(Map<String, dynamic> context, {Map<String, dynamic>? probe}) {
  final host = context["host"];
  final probeOutcome = probe?["probe_outcome"];
  return {
    "network.operation": context["operation"] as String,
    if (host is String && host != reportValueNotStated) "network.host": host,
    if (context["is_handshake_error"] == true) "network.tls_handshake": "true",
    if (probeOutcome is String && probeOutcome != reportValueNotStated) "network.tls_probe": probeOutcome,
  };
}

/// Logs a failed network request with as much diagnostic context as the platform
/// allows, and reports it to Sentry.
///
/// Public only so the "never escalates" guarantee below can be tested; nothing
/// outside this library calls it.
Future<void> logNetworkException({
  required String operation,
  required Object exception,
  required StackTrace stackTrace,
  String? url,
}) async {
  // Diagnostics must never escalate the failure they describe. Every caller
  // treats a network failure as recoverable (a null module version, a warning
  // toast), so anything raised while reporting it is logged and dropped here
  // rather than propagated out of the caller's catch block.
  try {
    final context = networkFailureContext(operation: operation, exception: exception, url: url);
    logger.e("Network request failed. context=$context", exception, stackTrace);

    Map<String, dynamic>? probe;
    final probeUri =
        (exception is DioException ? exception.requestOptions.uri : null) ?? (url == null ? null : Uri.tryParse(url));
    if (probeUri != null) {
      try {
        probe = await probeTlsConnection(probeUri);
        logger.i("TLS probe result. operation=$operation, probe=$probe");
      } catch (probeError, probeStack) {
        logger.w("TLS probe itself failed. operation=$operation", probeError, probeStack);
        probe = {
          "probe_outcome": "probe_failure",
          "probe_error_type": probeError.runtimeType.toString(),
          "probe_error_message": probeError.toString(),
        };
      }
    }

    // The probe block is swept for the same reason the failure block is. Nothing it can
    // build today is null, but the rule that answers "does a value survive the trip" has to
    // hold for every context this function publishes, not for the ones that happen to need
    // it -- otherwise the next key added to the probe is the one that goes missing.
    final statedProbe = probe == null ? null : statedReportContext(probe);
    captureExceptionWithScope(
      exception,
      stackTrace,
      tags: networkFailureTags(context, probe: statedProbe),
      contexts: {"network_failure": context, "tls_probe": ?statedProbe},
    );
  } catch (loggingError, loggingStack) {
    logger.e("Failed to report a network exception. operation=$operation", loggingError, loggingStack);
  }
}

/// Decodes the module zip at `args.$1`, refuses it unless it carries a
/// recognition module, and extracts it into `args.$2`.
///
/// File-based counterpart of [installModuleArchiveBytes]. The two routes exist
/// because the *source* differs -- desktop streams from a file it downloaded or
/// the user picked, a browser only ever has the bytes -- but the refusal must
/// not: both call [_requireModulePayload], so what counts as a module is one
/// rule and the platforms cannot drift on it. Without it this route wrote
/// nothing for a body that is not an archive (a captive-portal page served with
/// a 200 decodes into an *empty* archive rather than throwing) and its caller
/// then reported success for a module that is not on disk.
///
/// The check reads entry names only, so it does not consume [stream] ahead of
/// the extraction below.
///
/// Runs inside a `compute` isolate, so it has to stay a top-level function.
///
/// Public only so the refusal can be tested; nothing outside this library calls
/// it.
///
/// Throws a [FormatException] when the zip does not carry a recognition module.
@visibleForTesting
Future<void> installModuleArchiveFile((FilePath, DirectoryPath) args) async {
  final stream = InputFileStream(args.$1.path);
  try {
    final archive = ZipDecoder().decodeStream(stream);
    _requireModulePayload(archive);
    // extractArchiveToDisk is async and reads each entry lazily from [stream];
    // it must complete before the input stream is closed, otherwise only the
    // first entry is written and the rest fail mid-read.
    await extractArchiveToDisk(archive, args.$2.path);
  } finally {
    await stream.close();
  }
}

/// Removes the temporary module archive at [path], on every outcome.
///
/// Awaited, and deliberately not fire-and-forget: a rejection -- the file still
/// being held by the `compute` isolate that just finished is the realistic one
/// on Windows -- would otherwise surface as an unhandled asynchronous error with
/// no context instead of a log line. It is also swallowed rather than rethrown,
/// because cleanup must never replace the outcome its caller already decided.
///
/// What a failure costs is disk, not correctness: the archive is written to the
/// session-scoped [PathInfo.tempDir] under a fixed name, so the next update
/// attempt overwrites it and a later launch's `sweepTempSessions` removes the
/// whole session directory.
///
/// Public only so the two guarantees above -- that it waits, and that a refusal
/// does not escape -- can be tested; nothing outside this library calls it.
@visibleForTesting
Future<void> deleteDownloadedArchive(FilePath path) async {
  try {
    await path.delete(emptyOk: true);
  } catch (exception, stackTrace) {
    logger.w("Failed to delete the downloaded module archive.", exception, stackTrace);
  }
}

/// Installs a manually provided modules zip into the modules directory.
///
/// The zip is extracted into the parent of [PathInfo.modulesDir] exactly like
/// the auto-updater does, so a server-distributed `modules.zip` (whose top-level
/// directory is `modules/`) lands at `modulesDir` as-is. The target follows the
/// configurable data root: `modulesDir.parent` is `dataRoot ?? supportDir`, so a
/// relocated install writes to the same place the app reads from. The archive
/// is refused unless it carries a recognition module, by the same rule the
/// byte-based install applies (see [installModuleArchiveFile]).
///
/// On success the caller must invalidate [moduleVersionLoader] (guarded by its
/// own widget lifecycle) so the freshly extracted module takes effect without an
/// app restart. This function never touches [ref] after the extraction await, so
/// it is safe even if the originating widget is disposed mid-install.
///
/// Returns true on success.
Future<bool> installModuleFromZip(RefBase ref, FilePath zipPath) async {
  try {
    final pathInfo = await ref.read(pathInfoLoader.future);
    await compute(installModuleArchiveFile, (zipPath, pathInfo.modulesDir.parent));
  } catch (exception, stackTrace) {
    logger.e("Failed to install module from zip: path=${zipPath.path}", exception, stackTrace);
    captureException(exception, stackTrace);
    if (_isAccessDeniedError(exception)) {
      sendModuleVersionCheckToast(ToastType.error, ModuleVersionCheckResultCode.accessDenied);
    } else {
      sendModuleVersionCheckToast(ToastType.error, ModuleVersionCheckResultCode.manualUpdateFailure);
    }
    return false;
  }
  sendModuleVersionCheckToast(ToastType.success, ModuleVersionCheckResultCode.manualUpdateSuccess);
  return true;
}

/// Installs a manually provided modules zip from its **bytes**.
///
/// Byte-based counterpart of [installModuleFromZip], for the platforms where a
/// picked or dropped file has no filesystem path to stream from: in a browser
/// `PlatformFile.path` is always null and the archive only exists in memory, so
/// the path-based route above consumed the click and returned without doing
/// anything. The extraction goes through [extractModuleZipBytes], the same OPFS
/// writer the web bootstrap ([_downloadAndExtractModuleToOpfs]) uses, so a
/// manual install lands exactly where the automatic one does.
///
/// Reports the outcome with the same toasts as [installModuleFromZip] — both
/// success and failure — so the manual update is never silent. Like it, this
/// function never touches [ref] after the extraction await, and the caller owns
/// invalidating [moduleVersionLoader].
///
/// Returns true on success.
Future<bool> installModuleFromZipBytes(RefBase ref, List<int> bytes) async {
  try {
    final pathInfo = await ref.read(pathInfoLoader.future);
    await extractModuleZipBytes(bytes, pathInfo.modulesDir);
  } catch (exception, stackTrace) {
    logger.e("Failed to install module from zip bytes: size=${bytes.length}", exception, stackTrace);
    captureException(exception, stackTrace);
    sendModuleVersionCheckToast(ToastType.error, ModuleVersionCheckResultCode.manualUpdateFailure);
    return false;
  }
  sendModuleVersionCheckToast(ToastType.success, ModuleVersionCheckResultCode.manualUpdateSuccess);
  return true;
}

/// Extracts a whole modules zip held in memory into [modulesDir].
///
/// Both payloads are always written (a manual install replaces the module
/// wholesale, unlike the bootstrap, which fills in only the missing halves), and
/// each payload's commit marker is still written last, so an install that fails
/// part-way leaves the markers absent and the next boot re-bootstraps rather
/// than reading a half-written module.
///
/// Throws a [FormatException] when the bytes do not carry a recognition module.
Future<void> extractModuleZipBytes(List<int> bytes, DirectoryPath modulesDir) {
  return installModuleArchiveBytes(bytes, modulesDir, extractJson: true, extractOnnx: true);
}

/// Decodes a module zip held in [bytes], refuses it unless it carries a
/// recognition module, and writes the requested payloads into [modulesDir].
///
/// The single entry point for every in-memory install, manual or automatic,
/// because the refusal has to cover both. Bytes that are not a zip at all — an
/// HTML error page, a captive-portal interception, a response cut short — decode
/// into an *empty* archive instead of throwing, and extracting that would commit
/// the payload markers over nothing. The ONNX sentinel would then tell every
/// later boot that the recognizer set is present, so the browser would never
/// fetch it again: a permanent, silent loss of recognition that no retry clears.
/// Refusing before the first write leaves both markers exactly as they were, so
/// the caller reports a failure and the next boot starts the same fetch over.
///
/// Public only so the refusal can be tested; nothing outside this library calls
/// it.
///
/// Throws a [FormatException] when the bytes do not carry a recognition module.
Future<void> installModuleArchiveBytes(
  List<int> bytes,
  DirectoryPath modulesDir, {
  required bool extractJson,
  required bool extractOnnx,
}) async {
  final archive = ZipDecoder().decodeBytes(bytes);
  _requireModulePayload(archive);
  await _extractModuleArchiveTo(archive, modulesDir, extractJson: extractJson, extractOnnx: extractOnnx);
}

/// Refuses [archive] unless it carries a recognition module.
///
/// The single refusal for every install route on either platform -- the
/// in-memory one ([installModuleArchiveBytes]) and the file one
/// ([installModuleArchiveFile]) -- so the predicate, the exception type and the
/// message are one thing rather than two implementations that agree today.
void _requireModulePayload(Archive archive) {
  if (!_holdsModulePayload(archive)) {
    throw const FormatException("The archive holds no recognition module.");
  }
}

/// Whether [archive] carries both halves a module install has to commit: the
/// `version_info.json` marker and at least one nested recognizer entry.
bool _holdsModulePayload(Archive archive) {
  var hasVersionInfo = false;
  var hasNestedEntry = false;
  for (final file in archive) {
    if (!file.isFile) {
      continue;
    }
    final relative = _moduleRelativePath(file.name);
    hasVersionInfo |= relative.length == 1 && relative.single == _versionFileName;
    hasNestedEntry |= relative.length >= 2;
  }
  return hasVersionInfo && hasNestedEntry;
}

/// The archive entry [name] relative to the module root, with the leading
/// `modules/` wrapper (which the desktop extraction also strips) removed.
List<String> _moduleRelativePath(String name) {
  final segments = name.split("/").where((s) => s.isNotEmpty).toList();
  return (segments.isNotEmpty && segments.first == "modules") ? segments.sublist(1) : segments;
}

const _versionFileName = "version_info.json";

/// Whether the latest automatic module check failed to obtain or apply the
/// recognition module. True when the module is unavailable entirely or when the
/// latest could not be downloaded but an older local module is still in use;
/// false on success and on intentional skips (debug, pin, app-version block).
/// Consumers decide how to react (e.g. ModuleUpdaterGroup shows a manual-update
/// banner). Distinct from the transient failure toast.
final moduleUpdateFailedProvider = settableNotifierProvider<bool>(false);

/// File name of the ONNX-extraction sentinel written into the OPFS `modulesDir`.
///
/// This marker is independent of `version_info.json` (the display-layer JSON
/// commit marker). The recognizer ONNX payload and the top-level JSON have
/// different install lifecycles, so gating them on the same marker would strand
/// one when only the other landed. In particular, a browser that already ran the
/// Stage-5 bootstrap has `version_info.json` present but never extracted the ONNX
/// — a naive shared marker would skip the fetch forever (the "migration trap" in
/// the Stage-6 design §3.2). Written LAST, after every ONNX entry, so a partial
/// extraction re-runs cleanly on the next boot.
const _onnxSentinelFileName = ".onnx_ready";

/// Bootstraps the web module data into OPFS and returns the local module version.
///
/// Two payloads with independent markers are ensured:
/// - the display-layer top-level `*.json`, committed by `version_info.json`; and
/// - the recognizer ONNX set (`<category>/prediction.onnx`), committed by
///   [_onnxSentinelFileName].
///
/// A boot on which **either** marker is missing downloads [Const.moduleZipUrl]
/// once and installs both payloads out of it — the first web boot, where both
/// are absent, and the migration boot of a browser that ran the Stage-5
/// bootstrap and so has only the JSON marker (design §3.2). The missing half is
/// never installed on its own: the recognizer set is read through the top-level
/// JSON that shipped with it (labels, thresholds, `recognizer.json`'s model
/// paths), so half of the current release beside half of the previous one is a
/// pairing nothing is built or tested for, and it would stand for the whole
/// session. The markers record which payloads are installed; they do not
/// license installing them from different builds. Once both markers are present
/// the boot no longer needs a module, but it still asks whether the published
/// one moved ([_refreshWebModule]) — the markers say "installed", not "current".
/// Any download/extract failure is logged and yields a null version — the same
/// "no module" outcome the desktop loader reports when nothing is available, so
/// the record-version check downstream stays inert rather than crashing the boot
/// — and raises [moduleUpdateFailedProvider] so the dashboard offers the manual
/// install instead of leaving the user with an invisible dead end.
Future<ModuleVersion?> _bootstrapWebModule(Ref ref) async {
  final pathInfo = await ref.watch(pathInfoLoader.future);
  final modulesDir = pathInfo.modulesDir;
  final versionFile = modulesDir.filePath(_versionFileName);
  final onnxSentinel = modulesDir.filePath(_onnxSentinelFileName);
  final needJson = !await versionFile.exists();
  final needOnnx = !await onnxSentinel.exists();
  if (!needJson && !needOnnx) {
    return _refreshWebModule(ref, modulesDir, versionFile);
  }
  // Safe to write providers here: we are past the awaits above, so the
  // synchronous build frame that the modify-during-build guard checks is done.
  void setUpdateFailed(bool value) => ref.read(moduleUpdateFailedProvider.notifier).set(value);

  try {
    await _downloadAndExtractModuleToOpfs(modulesDir);
  } catch (exception, stackTrace) {
    await logNetworkException(
      operation: "bootstrap_web_module",
      exception: exception,
      stackTrace: stackTrace,
      url: Const.moduleZipUrl,
    );
    setUpdateFailed(true);
    return null;
  }
  // What was just written came out of the currently published zip — all of it,
  // including on a migration boot — so a version comparison can add nothing on
  // this boot.
  setUpdateFailed(false);
  final local = await ModuleVersionRawData.load(versionFile);
  return local?.toModuleVersion();
}

/// What a boot should do about the module that is already installed on OPFS.
enum WebModuleRefreshVerdict {
  /// The installed module is the published one.
  upToDate,

  /// The published module differs from the installed one and can be applied.
  updateAvailable,

  /// Updating is intentionally suppressed: the local module is pinned, or the
  /// published one requires a newer app build than the one being served.
  blocked,

  /// The published version could not be read, so nothing can be concluded.
  checkFailed,
}

/// Decides whether the web build should re-download the recognition module.
///
/// Mirrors the desktop loader's ordering (pin, then equality, then the required
/// app version) so a given pair of `version_info.json` files produces the same
/// decision on both platforms; only the way the outcome is applied differs.
/// A different version is enough — as on desktop, a rollback is a valid update.
///
/// Pure and public so every boot outcome can be tested without a network.
WebModuleRefreshVerdict evaluateWebModuleRefresh({
  required ModuleVersionRawData? local,
  required ModuleVersionRawData? latest,
  required Version appVersion,
}) {
  // Pin first, as the desktop loader does. A pinned module is not replaced
  // whatever the published one says, so whether the published version could be
  // read cannot change the verdict — and answering `checkFailed` there would
  // raise the manual-install banner (and its warning toast) on every offline
  // boot for a user who has deliberately frozen the module, which is exactly
  // what desktop stays silent about under the same conditions.
  if (local?.pinVersion == true) {
    return WebModuleRefreshVerdict.blocked;
  }
  if (latest == null) {
    return WebModuleRefreshVerdict.checkFailed;
  }
  if (local?.recognizerVersion == latest.recognizerVersion) {
    return WebModuleRefreshVerdict.upToDate;
  }
  // An `application_version` that does not parse blocks the update instead of
  // waving it through: the field states a requirement, and a requirement that
  // cannot be read has not been shown to be met.
  final requiredAppVersion = latest.applicationVersion.toVersionOrNull();
  if (requiredAppVersion == null || requiredAppVersion > appVersion) {
    return WebModuleRefreshVerdict.blocked;
  }
  return WebModuleRefreshVerdict.updateAvailable;
}

/// Compares the installed module against the published one and re-downloads it
/// into OPFS when they differ.
///
/// The commit markers alone made the very first download permanent: every later
/// boot found both, skipped the network, and kept running an ever older
/// recognizer while nothing on screen said so. Recognition quality degrading
/// silently is worse than a visible failure, so the check runs on every boot and
/// a check that cannot be completed is reported rather than ignored.
Future<ModuleVersion?> _refreshWebModule(Ref ref, DirectoryPath modulesDir, FilePath versionFile) async {
  final local = await ModuleVersionRawData.load(versionFile);
  final appVersion = await ref.watch(localAppVersionLoader.future);
  ModuleVersionRawData? latest;
  try {
    latest = await ModuleVersionRawData.download(Uri.parse(Const.moduleVersionInfoUrl));
  } catch (exception, stackTrace) {
    await logNetworkException(
      operation: "check_latest_module_version",
      exception: exception,
      stackTrace: stackTrace,
      url: Const.moduleVersionInfoUrl,
    );
  }
  final verdict = evaluateWebModuleRefresh(local: local, latest: latest, appVersion: appVersion);
  logger.i(
    "Web module version: local=${local?.recognizerVersion}"
    ", latest=${latest?.recognizerVersion}, verdict=${verdict.name}",
  );
  void setUpdateFailed(bool value) => ref.read(moduleUpdateFailedProvider.notifier).set(value);

  switch (verdict) {
    case WebModuleRefreshVerdict.upToDate:
    case WebModuleRefreshVerdict.blocked:
      setUpdateFailed(false);
      return local?.toModuleVersion();
    case WebModuleRefreshVerdict.checkFailed:
      // The installed module still works, so this is a warning rather than an
      // outage -- but it has to be visible, because "kept working on an old
      // model" is exactly the state this path exists to prevent.
      setUpdateFailed(true);
      sendModuleVersionCheckToast(ToastType.warning, ModuleVersionCheckResultCode.latestVersionNotAvailable);
      return local?.toModuleVersion();
    case WebModuleRefreshVerdict.updateAvailable:
      try {
        await _downloadAndExtractModuleToOpfs(modulesDir);
      } catch (exception, stackTrace) {
        await logNetworkException(
          operation: "download_modules",
          exception: exception,
          stackTrace: stackTrace,
          url: Const.moduleZipUrl,
        );
        setUpdateFailed(true);
        sendModuleVersionCheckToast(ToastType.warning, ModuleVersionCheckResultCode.latestVersionNotAvailable);
        return local?.toModuleVersion();
      }
      setUpdateFailed(false);
      sendModuleVersionCheckToast(ToastType.success, ModuleVersionCheckResultCode.updated);
      return latest?.toModuleVersion();
  }
}

/// Downloads the module zip once and writes **both** payloads into [modulesDir]
/// on OPFS through [_extractModuleArchiveTo].
///
/// Takes no payload selector on purpose. The recognizer set and the top-level
/// JSON that interprets it are one published module, so every automatic install
/// writes the pair; selecting one half would install it next to whatever the
/// previous release left behind. [installModuleArchiveBytes] keeps the selector
/// because the manual byte install is handed an archive it did not fetch.
Future<void> _downloadAndExtractModuleToOpfs(DirectoryPath modulesDir) async {
  logger.i("Bootstrapping web module data from ${Const.moduleZipUrl}");
  final response = await createDiagnosticDio(
    operation: "bootstrap_web_module",
  ).get<List<int>>(Const.moduleZipUrl, options: Options(responseType: ResponseType.bytes));
  // Validated like a manual install: a body that is not a module (an error page
  // served with a 200, a truncated transfer) must not reach the extraction, or
  // the markers would be committed over an empty archive and the fetch would
  // never be attempted again. See [installModuleArchiveBytes].
  await installModuleArchiveBytes(response.data ?? const <int>[], modulesDir, extractJson: true, extractOnnx: true);
}

/// Writes the requested payloads of an already-decoded module [archive] into
/// [modulesDir], committing each payload's marker last.
///
/// Shared by the automatic bootstrap and the manual byte-based install so both
/// produce the same on-OPFS layout; only the source of the archive differs.
///
/// The zip wraps everything under a `modules/` directory (matching the desktop
/// extraction, which unpacks it into `modulesDir.parent`). Two payloads are
/// selectable:
/// - [extractJson]: the single-level `*.json` files the web UI reads, with
///   `version_info.json` written LAST as the commit marker (a write that fails
///   partway leaves it absent, so the next boot re-fetches rather than stranding
///   an incomplete module).
/// - [extractOnnx]: the nested recognizer payload (`<category>/prediction.onnx`
///   and any other nested files), preserving the subdirectory tree so the worker
///   can read each model by its `recognizer.json` `module_path` key. The
///   [_onnxSentinelFileName] marker is written LAST, after every nested entry,
///   mirroring the JSON marker's "commit last" idempotency.
Future<void> _extractModuleArchiveTo(
  Archive archive,
  DirectoryPath modulesDir, {
  required bool extractJson,
  required bool extractOnnx,
}) async {
  await modulesDir.create(recursive: true);

  List<int>? versionBytes;
  var jsonCount = 0;
  var onnxCount = 0;
  for (final file in archive) {
    if (!file.isFile) {
      continue;
    }
    final relative = _moduleRelativePath(file.name);
    if (relative.isEmpty) {
      continue;
    }
    final isTopLevelJson = relative.length == 1 && relative.single.endsWith(".json");
    if (isTopLevelJson) {
      if (!extractJson) {
        continue;
      }
      if (relative.single == _versionFileName) {
        versionBytes = file.content;
        continue;
      }
      await modulesDir.filePath(relative.single).writeAsBytes(file.content);
      jsonCount++;
    } else if (relative.length >= 2) {
      // A nested entry (the ONNX recognizer payload). Preserve the subtree so
      // `<category>/prediction.onnx` resolves under modulesDir.
      if (!extractOnnx) {
        continue;
      }
      final target = modulesDir.filePath(relative.join("/"));
      await target.parent.create(recursive: true);
      await target.writeAsBytes(file.content);
      onnxCount++;
    }
  }
  if (extractJson && versionBytes != null) {
    await modulesDir.filePath(_versionFileName).writeAsBytes(versionBytes);
    jsonCount++;
  }
  // Commit the ONNX marker only after every nested entry has landed.
  if (extractOnnx) {
    await modulesDir.filePath(_onnxSentinelFileName).writeAsBytes(const [1]);
  }
  logger.i("Stored $jsonCount JSON + $onnxCount ONNX file(s) into OPFS at ${modulesDir.path}");
}

final moduleVersionLoader = FutureProvider<ModuleVersion?>((ref) async {
  // Web has no desktop-style auto-updater (no dart:io FS, no on-disk zip
  // extraction). Instead it bootstraps the module data into OPFS once from the
  // same network source the desktop app uses, then reads the local
  // version_info.json back. Both the display-layer top-level JSON (read by the
  // UI) and the recognizer ONNX set (read by the Wasm worker) are extracted,
  // each gated on its own commit marker (Stage-6 design §3.2).
  if (kIsWeb) {
    return _bootstrapWebModule(ref);
  }
  final appVersion = await ref.watch(appVersionCheckLoader.future);
  if (appVersion.isUpdatable) {
    logger.w("The module version check is not guaranteed to work properly when the app is updatable.");
  }

  final pathInfo = await ref.watch(pathInfoLoader.future);
  final local = await compute(ModuleVersionRawData.load, pathInfo.modulesDir.filePath("version_info.json"));
  ModuleVersionRawData? latest;
  try {
    latest = await ModuleVersionRawData.download(Uri.parse(Const.moduleVersionInfoUrl));
  } catch (exception, stackTrace) {
    await logNetworkException(
      operation: "check_latest_module_version",
      exception: exception,
      stackTrace: stackTrace,
      url: Const.moduleVersionInfoUrl,
    );
  }
  logger.i("Module version: local=${local?.recognizerVersion}, latest=${latest?.recognizerVersion}");

  // Safe to write providers here: we are past the awaits above, so the
  // synchronous build frame that the modify-during-build guard checks is done.
  void setUpdateFailed(bool value) => ref.read(moduleUpdateFailedProvider.notifier).set(value);

  if (kDebugMode) {
    logger.w("Updating modules is disabled in debug mode.");
    // The update is disabled here, not attempted, so this is not a failure.
    // Keep null-safe (the `!` crashed when no local module was present).
    setUpdateFailed(false);
    return local?.toModuleVersion();
  }

  if (local?.pinVersion == true) {
    logger.w("Updating modules is disabled by pin_version flag in local version_info.json.");
    setUpdateFailed(false);
    return local!.toModuleVersion();
  }

  if (local == null && latest == null) {
    setUpdateFailed(true);
    sendModuleVersionCheckToast(ToastType.error, ModuleVersionCheckResultCode.noVersionAvailable);
    return null;
  }
  if (latest == null) {
    setUpdateFailed(true);
    sendModuleVersionCheckToast(ToastType.warning, ModuleVersionCheckResultCode.latestVersionNotAvailable);
    return local!.toModuleVersion();
  }
  // No need to update. (Rollback is allowed)
  if (local?.recognizerVersion == latest.recognizerVersion) {
    setUpdateFailed(false);
    return local!.toModuleVersion();
  }

  // Same rule as the web verdict: an unreadable requirement is not a met one.
  final requiredAppVersion = latest.applicationVersion.toVersionOrNull();
  if (requiredAppVersion == null || requiredAppVersion > appVersion.local) {
    logger.i("Updating the module is disallowed because it does not meet the required app version.");
    // Intentionally blocked, not failed: the proper fix is an app update
    // (handled by its own banner), not a manual module install.
    setUpdateFailed(false);
    return null;
  }

  final downloadPath = pathInfo.tempDir.filePath("modules.zip");
  try {
    await createDiagnosticDio(operation: "download_modules").download(Const.moduleZipUrl, downloadPath.path);
    // Refuses a body that is not a module before writing anything, and so
    // reaches the catch below instead of the success toast underneath it.
    await compute(installModuleArchiveFile, (downloadPath, pathInfo.modulesDir.parent));
  } catch (exception, stackTrace) {
    await logNetworkException(
      operation: "download_modules",
      exception: exception,
      stackTrace: stackTrace,
      url: Const.moduleZipUrl,
    );
    setUpdateFailed(true);
    if (_isAccessDeniedError(exception)) {
      sendModuleVersionCheckToast(ToastType.error, ModuleVersionCheckResultCode.accessDenied);
    } else {
      if (local == null) {
        sendModuleVersionCheckToast(ToastType.error, ModuleVersionCheckResultCode.noVersionAvailable);
      } else {
        sendModuleVersionCheckToast(ToastType.warning, ModuleVersionCheckResultCode.latestVersionNotAvailable);
      }
    }
    return local?.toModuleVersion();
  } finally {
    // In a `finally` and not at the end of the `try`: a download that arrived
    // and was then refused (not a module) or failed to extract leaves the same
    // temp file behind, and the refusal added above makes that outcome routine.
    await deleteDownloadedArchive(downloadPath);
  }

  setUpdateFailed(false);
  sendModuleVersionCheckToast(ToastType.success, ModuleVersionCheckResultCode.updated);
  return latest.toModuleVersion();
});

class AppVersionCheckResult {
  final Version local;
  final Version latest;
  final bool hasError;

  AppVersionCheckResult({required this.local, required this.latest, this.hasError = false});

  bool get isUpdatable => local != latest;
}

enum AppVersionCheckResultCode { noUpdateRequired, newVersionAvailable, latestVersionNotAvailable, accessDenied }

void _sendAppVersionCheckToast(ToastType type, AppVersionCheckResultCode code) {
  // This function can be called before EasyLocalization is initialized.
  // For this reason, a delay is required for now.
  Future.delayed(const Duration(milliseconds: 300), () {
    Toaster.show(ToastData(type: type, description: "$tr_toast.app_version_check.${code.name.snakeCase}".tr()));
  });
}

enum VersionCheckEntryKey { lastAppVersionChecked, latestAppVersion, localAppVersion }

extension StringExtension on String {
  /// Parses a semver string, answering `null` when it is not one.
  ///
  /// Null rather than a `0.0.0` stand-in: every caller compares the result
  /// against a real app version, and `0.0.0` is smaller than all of them, so a
  /// value that could not be read used to read as "no constraint" and lifted
  /// the very gate it was there to raise. "Unreadable" has to stay
  /// distinguishable from "readable and low" at each call site, which then
  /// decides which way is the safe one for it.
  Version? toVersionOrNull() {
    try {
      return Version.parse(this);
    } catch (error, stackTrace) {
      logger.e("Failed to parse Version: value=$this", error, stackTrace);
      captureException(error, stackTrace);
      return null;
    }
  }
}

FutureOr<Version?> _checkLatestAppVersion(Version currentLocalVersion) async {
  final box = StorageBox(StorageBoxKey.versionCheck);
  final lastAppVersionCheckedEntry = box.entry<DateTime>(VersionCheckEntryKey.lastAppVersionChecked.name);
  final latestAppVersionEntry = box.entry<String>(VersionCheckEntryKey.latestAppVersion.name);
  final localAppVersionEntry = box.entry<String>(VersionCheckEntryKey.localAppVersion.name);

  final hasExpired = lastAppVersionCheckedEntry.pull()?.hasExpired(const Duration(hours: 20)) ?? true;
  // A stored value that no longer parses reads as null here, which fails the
  // two guards below and sends this through the network check again — the same
  // path a first run takes. Never as `0.0.0`, which would have passed as a
  // known-latest smaller than anything and reported "no update available".
  final knownLocalAppVersion = localAppVersionEntry.pull()?.toVersionOrNull();
  final knownLatestAppVersion = latestAppVersionEntry.pull()?.toVersionOrNull();
  logger.d(
    "last=${lastAppVersionCheckedEntry.pull()}"
    ", current-local=$currentLocalVersion"
    ", known-local=$knownLocalAppVersion"
    ", known-latest=$knownLatestAppVersion"
    ", hasExpired=$hasExpired",
  );

  if (!hasExpired && knownLatestAppVersion != null && knownLocalAppVersion == currentLocalVersion) {
    return knownLatestAppVersion;
  }

  try {
    lastAppVersionCheckedEntry.push(DateTime.now());
    localAppVersionEntry.push(currentLocalVersion.toString());
    latestAppVersionEntry.delete();
    final latest = await createDiagnosticDio(
      operation: "check_latest_app_version",
    ).get(Const.appVersionInfoUrl).then((response) => Version.parse(jsonDecode(response.toString())['version']));
    latestAppVersionEntry.push(latest.toString());
    logger.d("latest=$latest");
    return latest;
  } catch (exception, stackTrace) {
    await logNetworkException(
      operation: "check_latest_app_version",
      exception: exception,
      stackTrace: stackTrace,
      url: Const.appVersionInfoUrl,
    );
    if (_isAccessDeniedError(exception)) {
      _sendAppVersionCheckToast(ToastType.error, AppVersionCheckResultCode.accessDenied);
    }
    return null;
  }
}

Future<Version> loadLocalAppVersion() async {
  return rootBundle.loadString("assets/version_info.json").then((info) => Version.parse(jsonDecode(info)['version']));
}

final localAppVersionLoader = FutureProvider<Version>((ref) async {
  return loadLocalAppVersion();
});

final appVersionCheckLoader = FutureProvider<AppVersionCheckResult>((ref) async {
  final local = await ref.watch(localAppVersionLoader.future);
  // No self-update on web: skip the network check (and the dart:io Platform
  // reads in its failure path) and report the local version as current.
  // (Minimal boot guard; the full version_check web treatment is stage 3.)
  if (kIsWeb) {
    return AppVersionCheckResult(local: local, latest: local);
  }
  final latest = await _checkLatestAppVersion(local);
  logger.i("App version: local=$local, latest=$latest");

  if (latest == null) {
    _sendAppVersionCheckToast(ToastType.warning, AppVersionCheckResultCode.latestVersionNotAvailable);
    return AppVersionCheckResult(local: local, latest: local, hasError: true);
  }

  final result = AppVersionCheckResult(local: local, latest: latest);
  if (result.isUpdatable) {
    _sendAppVersionCheckToast(ToastType.info, AppVersionCheckResultCode.newVersionAvailable);
  }
  return result;
});
