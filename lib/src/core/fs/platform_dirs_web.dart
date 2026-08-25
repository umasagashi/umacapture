import '/src/core/path_entity.dart';

import 'platform_dirs.dart';

/// Creates the web platform-directory resolver. Referenced by the conditional
/// import in `platform_dirs.dart`.
PlatformDirs createPlatformDirs() => const WebPlatformDirs();

/// Fixed virtual roots for the browser, where there is no OS filesystem.
///
/// OPFS is origin-private, so no application-namespace segment is needed here:
/// an empty root places every base directory at the OPFS root. `pathInfoLoader`
/// still appends `appName` to the documents dir (yielding `umacapture/storage`,
/// `umacapture/chara_detail/...`) and leaves the support dir unprefixed
/// (yielding `modules`), and the OPFS adapter maps each virtual segment onto a
/// nested OPFS directory (design §3).
///
/// Returning a non-empty `['umacapture']` root would double-nest the application
/// namespace because `pathInfoLoader` already appends `appName`. The empty root
/// avoids that duplication. Development-only data created under the former
/// layout is handled manually and is never copied or deleted at product startup.
///
/// The executable directory is a harmless placeholder: `isInstallerModeLoader`
/// lists it (now the OPFS root), finds no uninstaller, and reports `false`,
/// which is correct on web.
class WebPlatformDirs implements PlatformDirs {
  const WebPlatformDirs();

  static const _root = <String>[];

  @override
  Future<DirectoryPath> documentsDir() async => DirectoryPath(_root);

  @override
  Future<DirectoryPath> supportDir() async => DirectoryPath(_root);

  @override
  Future<DirectoryPath?> downloadsDir() async => null;

  @override
  Future<DirectoryPath> executableDir() async => DirectoryPath(_root);
}
