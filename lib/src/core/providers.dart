import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '/const.dart';
import '/src/core/path_entity.dart';

final packageInfoLoader = FutureProvider<PackageInfo>((ref) {
  return PackageInfo.fromPlatform();
});

/// A minimal [Notifier] holding an externally-settable value seeded with
/// [initial]. Replaces the many one-off `build() => default; set(v) => state = v`
/// notifiers the riverpod 3 migration produced when `StateProvider` was dropped.
/// Use [settableNotifierProvider] to declare a provider backed by it.
class SettableNotifier<T> extends Notifier<T> {
  SettableNotifier(this._initial);

  final T _initial;

  @override
  T build() => _initial;

  void set(T value) => state = value;
}

/// Convenience constructor for a [NotifierProvider] backed by [SettableNotifier].
NotifierProvider<SettableNotifier<T>, T> settableNotifierProvider<T>(T initial) {
  return NotifierProvider<SettableNotifier<T>, T>(() => SettableNotifier<T>(initial));
}

class PathInfo {
  final DirectoryPath documentDir;
  final DirectoryPath supportDir;
  final DirectoryPath executableDir;
  final DirectoryPath downloadDir;

  const PathInfo({
    required this.documentDir,
    required this.supportDir,
    required this.executableDir,
    required this.downloadDir,
  });

  DirectoryPath get tempDir => documentDir / "temp";

  DirectoryPath get storageDir => documentDir / "storage";

  DirectoryPath get modulesDir => supportDir / "modules";

  DirectoryPath get charaDetailDir => storageDir / "chara_detail";

  DirectoryPath get charaDetailActiveDir => charaDetailDir / "active";

  DirectoryPath get charaDetailMetadataDir => charaDetailDir / "metadata";

  DirectoryPath get charaDetailRatingDir => charaDetailMetadataDir / "rating";

  DirectoryPath get charaDetailMemoDir => charaDetailMetadataDir / "memo";

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
  final downloadDir = DirectoryPath(await getDownloadsDirectory());
  final info = PathInfo(
    documentDir: documentDir / appName,
    supportDir: supportDir,
    executableDir: FilePath.resolvedExecutable.parent,
    downloadDir: downloadDir,
  );
  return info;
});

final pathInfoProvider = Provider<PathInfo>((ref) {
  return ref.watch(pathInfoLoader).value!;
});

final isInstallerModeLoader = FutureProvider<bool>((ref) async {
  final info = await ref.watch(pathInfoLoader.future);
  return info.executableDir
      .listSync(recursive: false, followLinks: false)
      .where((e) => Const.uninstallerPattern.hasMatch(e.path))
      .isNotEmpty;
});
