import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '/src/core/utils.dart';

final packageInfoLoader = FutureProvider<PackageInfo>((ref) {
  return PackageInfo.fromPlatform();
});

class PathInfo {
  final String data;

  const PathInfo(this.data);

  String get storage => "$data/storage";

  String get modules => "$data/modules";

  String get charaDetail => "$storage/chara_detail";
}

final pathInfoLoader = FutureProvider<PathInfo>((ref) async {
  final appName = (await ref.watch(packageInfoLoader.future)).appName;
  late Directory directory;
  if (CurrentPlatform.isAndroid()) {
    directory = await getExternalStorageDirectories(type: StorageDirectory.documents).then((e) => e!.first);
  } else {
    directory = await getApplicationDocumentsDirectory();
  }
  return PathInfo("${directory.absolute.path}/$appName");
});

final pathInfoProvider = Provider<PathInfo>((ref) {
  return ref.watch(pathInfoLoader).value!;
});
