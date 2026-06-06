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

  ModuleVersion toModuleVersion() {
    return ModuleVersion(
      recognizerVersion: recognizerVersion.toDateTime(),
      minimumVersion: minimumVersion.toDateTime(),
    );
  }

  static Future<ModuleVersionRawData?> load(FilePath file) async {
    if (!file.existsSync()) {
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

Map<String, dynamic> _networkExceptionContext({required String operation, required Object exception, String? url}) {
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
    "os": Platform.operatingSystem,
    "os_version": Platform.operatingSystemVersion,
    "locale": Platform.localeName,
  };
}

Future<void> _logNetworkException({
  required String operation,
  required Object exception,
  required StackTrace stackTrace,
  String? url,
}) async {
  final context = _networkExceptionContext(operation: operation, exception: exception, url: url);
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

  captureExceptionWithScope(
    exception,
    stackTrace,
    tags: {
      "network.operation": operation,
      if (context["host"] != null) "network.host": context["host"] as String,
      if (context["is_handshake_error"] == true) "network.tls_handshake": "true",
      if (probe != null && probe["probe_outcome"] != null) "network.tls_probe": probe["probe_outcome"] as String,
    },
    contexts: {"network_failure": context, "tls_probe": ?probe},
  );
}

Future<void> _extractArchive((FilePath, DirectoryPath) args) async {
  final stream = InputFileStream(args.$1.path);
  try {
    final archive = ZipDecoder().decodeStream(stream);
    // extractArchiveToDisk is async and reads each entry lazily from [stream];
    // it must complete before the input stream is closed, otherwise only the
    // first entry is written and the rest fail mid-read.
    await extractArchiveToDisk(archive, args.$2.path);
  } finally {
    await stream.close();
  }
}

/// Installs a manually provided modules zip into the support directory.
///
/// The zip is extracted into the support directory exactly like the
/// auto-updater does, so a server-distributed `modules.zip` (whose top-level
/// directory is `modules/`) can be applied as-is. No validation is performed.
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
    await compute(_extractArchive, (zipPath, pathInfo.supportDir));
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

/// Whether the latest automatic module check failed to obtain or apply the
/// recognition module. True when the module is unavailable entirely or when the
/// latest could not be downloaded but an older local module is still in use;
/// false on success and on intentional skips (debug, pin, app-version block).
/// Consumers decide how to react (e.g. ModuleUpdaterGroup shows a manual-update
/// banner). Distinct from the transient failure toast.
final moduleUpdateFailedProvider = settableNotifierProvider<bool>(false);

final moduleVersionLoader = FutureProvider<ModuleVersion?>((ref) async {
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
    await _logNetworkException(
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

  if (latest.applicationVersion.toVersion() > appVersion.local) {
    logger.i("Updating the module is disallowed because it does not meet the required app version.");
    // Intentionally blocked, not failed: the proper fix is an app update
    // (handled by its own banner), not a manual module install.
    setUpdateFailed(false);
    return null;
  }

  final downloadPath = pathInfo.tempDir.filePath("modules.zip");
  try {
    await createDiagnosticDio(operation: "download_modules").download(Const.moduleZipUrl, downloadPath.path);
    await compute(_extractArchive, (downloadPath, pathInfo.supportDir));
    downloadPath.toFile().delete();
  } catch (exception, stackTrace) {
    await _logNetworkException(
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
  Version toVersion() {
    try {
      return Version.parse(this);
    } catch (error, stackTrace) {
      logger.e("Failed to parse Version: value=$this", error, stackTrace);
      captureException(error, stackTrace);
      return Version(0, 0, 0);
    }
  }
}

FutureOr<Version?> _checkLatestAppVersion(Version currentLocalVersion) async {
  final box = StorageBox(StorageBoxKey.versionCheck);
  final lastAppVersionCheckedEntry = box.entry<DateTime>(VersionCheckEntryKey.lastAppVersionChecked.name);
  final latestAppVersionEntry = box.entry<String>(VersionCheckEntryKey.latestAppVersion.name);
  final localAppVersionEntry = box.entry<String>(VersionCheckEntryKey.localAppVersion.name);

  final hasExpired = lastAppVersionCheckedEntry.pull()?.hasExpired(const Duration(hours: 20)) ?? true;
  final knownLocalAppVersion = localAppVersionEntry.pull()?.toVersion();
  final knownLatestAppVersion = latestAppVersionEntry.pull()?.toVersion();
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
    await _logNetworkException(
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
