import '/src/core/path_entity.dart';

import 'platform_dirs_io.dart' if (dart.library.js_interop) 'platform_dirs_web.dart';

/// Resolves the OS-managed base directories `pathInfoLoader` needs, standing in
/// for the `path_provider` plugin.
///
/// On desktop/VM the io backend defers to `path_provider` (and
/// [Platform.resolvedExecutable]); on web there is no OS filesystem, so the web
/// backend returns fixed **virtual** roots that map 1:1 onto nested OPFS
/// directories (see the web backend). Keeping the resolution
/// behind this facade lets `pathInfoLoader` stay platform-agnostic while the
/// `path_provider` calls never enter the web execution path.
abstract interface class PlatformDirs {
  /// The user documents directory (Android uses the external documents dir).
  Future<DirectoryPath> documentsDir();

  /// The app support directory (native default for relocatable data).
  Future<DirectoryPath> supportDir();

  /// The downloads directory, or `null` where the platform has none.
  Future<DirectoryPath?> downloadsDir();

  /// The directory containing the running executable.
  Future<DirectoryPath> executableDir();
}

/// The process-wide platform-directory resolver, selected at compile time by the
/// conditional import above (io on desktop/VM, virtual roots on web).
final PlatformDirs platformDirs = createPlatformDirs();
