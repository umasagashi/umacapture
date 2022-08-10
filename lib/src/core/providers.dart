import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '/src/core/path_entity.dart';
import '/src/core/utils.dart';

final packageInfoLoader = FutureProvider<PackageInfo>((ref) {
  return PackageInfo.fromPlatform();
});

class PathInfo {
  final DirectoryPath documentDir;
  final DirectoryPath supportDir;

  const PathInfo({
    required this.documentDir,
    required this.supportDir,
  });

  DirectoryPath get tempDir => documentDir / "temp";

  DirectoryPath get storageDir => documentDir / "storage";

  DirectoryPath get modulesDir => supportDir / "modules";

  DirectoryPath get charaDetailActiveDir => storageDir / "chara_detail" / "active";

  @override
  String toString() => 'PathInfo{documentDir: $documentDir, supportDir: $supportDir}';
}

final pathInfoLoader = FutureProvider<PathInfo>((ref) async {
  final appName = (await ref.watch(packageInfoLoader.future)).appName;
  late final DirectoryPath documentDir;
  if (CurrentPlatform.isAndroid()) {
    // To make it easier for users to export manually.
    documentDir =
        DirectoryPath(await getExternalStorageDirectories(type: StorageDirectory.documents).then((e) => e!.first));
  } else {
    documentDir = DirectoryPath(await getApplicationDocumentsDirectory());
  }
  final supportDir = DirectoryPath(await getApplicationSupportDirectory());
  final info = PathInfo(
    documentDir: documentDir / appName,
    supportDir: supportDir,
  );
  return info;
});

final pathInfoProvider = Provider<PathInfo>((ref) {
  return ref.watch(pathInfoLoader).value!;
});
