import 'dart:async';
import 'dart:convert';

import 'package:archive/archive_io.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recase/recase.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:tuple/tuple.dart';
import 'package:version/version.dart';

import '/const.dart';
import '/src/core/json_adapter.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';
import '/src/preference/storage_box.dart';

// ignore: constant_identifier_names
const tr_toast = "toast";

StreamController<ToastData> _versionCheckEventController = StreamController();
final versionCheckEventProvider = StreamProvider<ToastData>((ref) {
  if (_versionCheckEventController.hasListener) {
    _versionCheckEventController = StreamController();
  }
  return _versionCheckEventController.stream;
});

@jsonSerializable
class ModuleVersionInfo {
  final String formatVersion;
  final String region;
  final String recognizerVersion;

  @JsonProperty(ignore: true)
  DateTime get version => DateTime.parse(recognizerVersion);

  ModuleVersionInfo(this.formatVersion, this.region, this.recognizerVersion);

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
}

void _sendModuleVersionCheckToast(ToastType type, ModuleVersionCheckResultCode code) {
  _versionCheckEventController.sink.add(
    ToastData(type, description: "$tr_toast.module_version_check.${code.name.snakeCase}".tr()),
  );
}

Future<void> _extractArchive(Tuple2<FilePath, DirectoryPath> args) {
  final stream = InputFileStream(args.item1.path);
  final archive = ZipDecoder().decodeBuffer(stream);
  extractArchiveToDisk(archive, args.item2.path);
  return stream.close();
}

final moduleVersionLoader = FutureProvider<DateTime?>((ref) async {
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
    return local!.version;
  }
  // Rollback is allowed.
  if (local?.version == latest.version) {
    return latest.version;
  }

  final downloadPath = pathInfo.tempDir.filePath("modules.zip");
  try {
    await Dio().download(Const.moduleZipUrl, downloadPath.path);
    await compute(_extractArchive, Tuple2(downloadPath, pathInfo.supportDir));
    downloadPath.toFile().delete();
  } catch (exception, stackTrace) {
    logger.e(exception);
    if (local == null) {
      _sendModuleVersionCheckToast(ToastType.error, ModuleVersionCheckResultCode.noVersionAvailable);
    } else {
      _sendModuleVersionCheckToast(ToastType.warning, ModuleVersionCheckResultCode.latestVersionNotAvailable);
    }
    await Sentry.captureException(exception, stackTrace: stackTrace);
    return local?.version;
  }

  _sendModuleVersionCheckToast(ToastType.success, ModuleVersionCheckResultCode.updated);
  return latest.version;
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
}

void _sendAppVersionCheckToast(ToastType type, AppVersionCheckResultCode code) {
  _versionCheckEventController.sink.add(
    ToastData(type, description: "$tr_toast.app_version_check.${code.name.snakeCase}".tr()),
  );
}

enum VersionCheckEntryKey {
  lastAppVersionChecked,
  latestAppVersion,
}

extension StringExtension on String {
  Version toVersion() => Version.parse(this);
}

FutureOr<Version?> _checkLatestAppVersion() async {
  final box = StorageBox(StorageBoxKey.versionCheck);
  final lastAppVersionCheckedEntry = box.entry<DateTime>(VersionCheckEntryKey.lastAppVersionChecked.name);
  final latestAppVersionEntry = box.entry<String>(VersionCheckEntryKey.latestAppVersion.name);

  final durationSinceLastChecked =
      lastAppVersionCheckedEntry.pull()?.difference(DateTime.now()).abs() ?? const Duration(days: 30);
  final knownLatestAppVersion = latestAppVersionEntry.pull()?.toVersion();
  logger.d("last=$durationSinceLastChecked, latest=$knownLatestAppVersion");

  if (durationSinceLastChecked <= const Duration(hours: 20) && knownLatestAppVersion != null) {
    return knownLatestAppVersion;
  } else {
    lastAppVersionCheckedEntry.push(DateTime.now());
    latestAppVersionEntry.delete();
    try {
      final latest = await Dio()
          .get(Const.appVersionInfoUrl)
          .then((response) => Version.parse(jsonDecode(response.toString())['version']));
      latestAppVersionEntry.push(latest.toString());
      return latest;
    } catch (e) {
      logger.w(e);
      return null;
    }
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
  final latest = await _checkLatestAppVersion();
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
