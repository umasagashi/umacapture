import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '/src/core/utils.dart';

final packageInfoLoader = FutureProvider<PackageInfo>((ref) {
  return PackageInfo.fromPlatform();
});

class PathInfo {
  final String documentDir;
  final String supportDir;

  const PathInfo({
    required this.documentDir,
    required this.supportDir,
  });

  String get temp => "$documentDir/temp";

  String get storage => "$documentDir/storage";

  String get modules => "$supportDir/modules";

  String get charaDetail => "$storage/chara_detail";

  @override
  String toString() => 'PathInfo{documentDir: $documentDir, supportDir: $supportDir}';
}

final pathInfoLoader = FutureProvider<PathInfo>((ref) async {
  final appName = (await ref.watch(packageInfoLoader.future)).appName;
  late final Directory documentDir;
  if (CurrentPlatform.isAndroid()) {
    // To make it easier for users to export manually.
    documentDir = await getExternalStorageDirectories(type: StorageDirectory.documents).then((e) => e!.first);
  } else {
    documentDir = await getApplicationDocumentsDirectory();
  }
  late final Directory supportDir;
  supportDir = await getApplicationSupportDirectory();
  final info = PathInfo(
    documentDir: "${documentDir.absolute.path}/$appName",
    supportDir: supportDir.absolute.path,
  );
  return info;
});

final pathInfoProvider = Provider<PathInfo>((ref) {
  return ref.watch(pathInfoLoader).value!;
});
