import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recase/recase.dart';
import 'package:tuple/tuple.dart';
import 'package:version/version.dart';

import '/const.dart';
import '/src/core/json_adapter.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';
import '/src/preference/storage_box.dart';

// ignore: constant_identifier_names
const tr_toast = "toast";

@jsonSerializable
class ModuleVersionInfo {
  final String formatVersion;
  final String region;
  final String recognizerVersion;

  @JsonProperty(defaultValue: "0.0.0")
  final String applicationVersion;

  ModuleVersionInfo(this.formatVersion, this.region, this.recognizerVersion, this.applicationVersion);

  static Future<ModuleVersionInfo?> load(FilePath file) async {
    if (!file.existsSync()) {
      return Future.value(null);
    }
    initializeJsonReflectable();
    const options = DeserializationOptions(caseStyle: CaseStyle.snake);
    try {
      return await file.readAsString().then((content) => JsonMapper.deserialize<ModuleVersionInfo>(content, options));
    } catch (e) {
      return null;
    }
  }

  static Future<ModuleVersionInfo?> download(Uri url) async {
    initializeJsonReflectable();
    const options = DeserializationOptions(caseStyle: CaseStyle.snake);
    try {
      return await Dio()
          .get(url.toString())
          .then((response) => JsonMapper.deserialize<ModuleVersionInfo>(response.toString(), options));
    } catch (e) {
      return null;
    }
  }
}

enum ModuleVersionCheckResultCode {
  noUpdateRequired,
  updated,
  latestVersionNotAvailable,
  noVersionAvailable,
  accessDenied,
}

void _sendModuleVersionCheckToast(ToastType type, ModuleVersionCheckResultCode code) {
  Toaster.show(ToastData(type: type, description: "$tr_toast.module_version_check.${code.name.snakeCase}".tr()));
}

Future<void> _extractArchive(Tuple2<FilePath, DirectoryPath> args) {
  final stream = InputFileStream(args.item1.path);
  final archive = ZipDecoder().decodeBuffer(stream);
  extractArchiveToDisk(archive, args.item2.path);
  return stream.close();
}

final moduleVersionLoader = FutureProvider<DateTime?>((ref) async {
  final appVersion = await ref.watch(appVersionCheckLoader.future);
  if (appVersion.isUpdatable) {
    logger.i("Skipping module version check because app is updatable.");
    return null;
  }

  final pathInfo = await ref.watch(pathInfoLoader.future);
  final local = await compute(ModuleVersionInfo.load, pathInfo.modulesDir.filePath("version_info.json"));
  final latest = await compute(ModuleVersionInfo.download, Uri.parse(Const.moduleVersionInfoUrl));
  logger.i("Module version: local=${local?.recognizerVersion}, latest=${latest?.recognizerVersion}");

  if (local == null && latest == null) {
    _sendModuleVersionCheckToast(ToastType.error, ModuleVersionCheckResultCode.noVersionAvailable);
    return null;
  }
  if (latest == null) {
    _sendModuleVersionCheckToast(ToastType.warning, ModuleVersionCheckResultCode.latestVersionNotAvailable);
    return local!.recognizerVersion.toDateTime();
  }
  // Rollback is allowed.
  if (local?.recognizerVersion == latest.recognizerVersion) {
    return latest.recognizerVersion.toDateTime();
  }

  if (latest.applicationVersion.toVersion() > appVersion.local) {
    logger.i("Updating the module is disallowed because it does not meet the required app version.");
    return null;
  }

  final downloadPath = pathInfo.tempDir.filePath("modules.zip");
  try {
    await Dio().download(Const.moduleZipUrl, downloadPath.path);
    await compute(_extractArchive, Tuple2(downloadPath, pathInfo.supportDir));
    downloadPath.toFile().delete();
  } catch (exception, stackTrace) {
    logger.e("Failed to download modules.", exception, stackTrace);
    if (exception is FileSystemException && exception.osError?.errorCode == 5) {
      _sendModuleVersionCheckToast(ToastType.error, ModuleVersionCheckResultCode.accessDenied);
    } else {
      if (local == null) {
        _sendModuleVersionCheckToast(ToastType.error, ModuleVersionCheckResultCode.noVersionAvailable);
      } else {
        _sendModuleVersionCheckToast(ToastType.warning, ModuleVersionCheckResultCode.latestVersionNotAvailable);
      }
      captureException(exception, stackTrace);
    }
    return local?.recognizerVersion.toDateTime();
  }

  _sendModuleVersionCheckToast(ToastType.success, ModuleVersionCheckResultCode.updated);
  return latest.recognizerVersion.toDateTime();
});

class AppVersionCheckResult {
  final Version local;
  final Version latest;
  final bool hasError;

  AppVersionCheckResult({
    required this.local,
    required this.latest,
    this.hasError = false,
  });

  bool get isUpdatable => local != latest;
}

enum AppVersionCheckResultCode {
  noUpdateRequired,
  newVersionAvailable,
  latestVersionNotAvailable,
  accessDenied,
}

void _sendAppVersionCheckToast(ToastType type, AppVersionCheckResultCode code) {
  Toaster.show(ToastData(type: type, description: "$tr_toast.app_version_check.${code.name.snakeCase}".tr()));
}

enum VersionCheckEntryKey {
  lastAppVersionChecked,
  latestAppVersion,
  localAppVersion,
}

extension StringExtension on String {
  Version toVersion() => Version.parse(this);
  DateTime toDateTime() => DateTime.parse(this);
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
    final latest = await Dio()
        .get(Const.appVersionInfoUrl)
        .then((response) => Version.parse(jsonDecode(response.toString())['version']));
    latestAppVersionEntry.push(latest.toString());
    logger.d("latest=$latest");
    return latest;
  } catch (exception, stackTrace) {
    logger.e("Failed to get latest app version.", exception, stackTrace);
    if (exception is FileSystemException && exception.osError?.errorCode == 5) {
      _sendAppVersionCheckToast(ToastType.error, AppVersionCheckResultCode.accessDenied);
    } else {
      captureException(exception, stackTrace);
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
