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

StreamController<ToastData> _moduleVersionCheckEventController = StreamController();
final moduleVersionCheckEventProvider = StreamProvider<ToastData>((ref) {
  if (_moduleVersionCheckEventController.hasListener) {
    _moduleVersionCheckEventController = StreamController();
  }
  return _moduleVersionCheckEventController.stream;
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

Future<void> _extractArchive(Tuple2<FilePath, DirectoryPath> args) {
  final stream = InputFileStream(args.item1.path);
  final archive = ZipDecoder().decodeBuffer(stream);
  extractArchiveToDisk(archive, args.item2.path);
  return stream.close();
}

ModuleVersionCheckResultCode _sendModuleVersionCheckToast(ToastType type, ModuleVersionCheckResultCode code) {
  _moduleVersionCheckEventController.sink.add(
    ToastData(type, description: "$tr_toast.module_version_check.${code.name.snakeCase}".tr()),
  );
  return code;
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
    // _sendModuleVersionCheckToast(ToastType.info, VersionCheck.noUpdateRequired);
    return latest.version;
  }

  final downloadPath = pathInfo.tempDir.filePath("modules.zip");
  try {
    await Dio().download(Const.moduleZipUrl, downloadPath);
    await compute(_extractArchive, Tuple2(downloadPath, pathInfo.supportDir));
    downloadPath.toFile().delete();
  } catch (e) {
    if (local == null) {
      _sendModuleVersionCheckToast(ToastType.error, ModuleVersionCheckResultCode.noVersionAvailable);
    } else {
      _sendModuleVersionCheckToast(ToastType.warning, ModuleVersionCheckResultCode.latestVersionNotAvailable);
    }
    return local?.version;
  }

  _sendModuleVersionCheckToast(ToastType.success, ModuleVersionCheckResultCode.updated);
  return latest.version;
});

class AppVersionCheckResult {
  final Version local;
  final Version latest;
  final bool isSkipped;

  AppVersionCheckResult({
    required this.local,
    required this.latest,
    this.isSkipped = false,
  });

  bool get isUpdatable => local != latest;
}

enum VersionCheckEntryKey {
  lastAppVersionChecked,
}

final appVersionCheckLoader = FutureProvider<AppVersionCheckResult>((ref) async {
  final local = await rootBundle
      .loadString("assets/version_info.json")
      .then((info) => Version.parse(jsonDecode(info)['version']));

  final entry = StorageBox(StorageBoxKey.versionCheck).entry<DateTime>(VersionCheckEntryKey.lastAppVersionChecked.name);
  final lastChecked = entry.pull();
  if (lastChecked != null && DateTime.now().difference(lastChecked).inHours <= 20) {
    logger.i("App version: local=$local, last_checked=${lastChecked.toLocal()}");
    return AppVersionCheckResult(local: local, latest: local, isSkipped: true);
  }

  try {
    final latest = await Dio()
        .get(Const.appVersionInfoUrl)
        .then((response) => Version.parse(jsonDecode(response.toString())['version']));
    entry.push(DateTime.now());
    logger.i("App version: local=$local, latest=$latest");
    return AppVersionCheckResult(local: local, latest: latest);
  } catch (e) {
    logger.w(e);
  }
  return AppVersionCheckResult(local: local, latest: local, isSkipped: true);
});
