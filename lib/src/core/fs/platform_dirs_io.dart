import 'package:path_provider/path_provider.dart';

import '/const.dart';
import '/src/core/path_entity.dart';

import 'platform_dirs.dart';

/// Creates the desktop/VM platform-directory resolver. Referenced by the
/// conditional import in `platform_dirs.dart`.
PlatformDirs createPlatformDirs() => const IoPlatformDirs();

/// Resolves the base directories through the `path_provider` plugin, preserving
/// the exact resolution `pathInfoLoader` performed inline before the facade was
/// extracted.
class IoPlatformDirs implements PlatformDirs {
  const IoPlatformDirs();

  @override
  Future<DirectoryPath> documentsDir() async {
    if (CurrentPlatform.isAndroid()) {
      // To make it easier for users to export manually.
      return DirectoryPath(await getExternalStorageDirectories(type: StorageDirectory.documents).then((e) => e!.first));
    }
    return DirectoryPath(await getApplicationDocumentsDirectory());
  }

  @override
  Future<DirectoryPath> supportDir() async => DirectoryPath(await getApplicationSupportDirectory());

  @override
  Future<DirectoryPath?> downloadsDir() async {
    // getDownloadsDirectory returns null on Android/unsupported platforms.
    final raw = await getDownloadsDirectory();
    return raw == null ? null : DirectoryPath(raw);
  }

  @override
  Future<DirectoryPath> executableDir() async => FilePath.resolvedExecutable.parent;
}
