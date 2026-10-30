import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'fs_directory.dart';
import 'opfs_directory.dart';

/// Thin async adapter over the Origin Private File System (OPFS), for a path given from the OPFS root.
///
/// It resolves virtual [PathEntity] paths onto nested OPFS directory handles, walking from
/// `navigator.storage.getDirectory()` for every operation, and exposes the primitives the web [FsBackend] needs.
/// The primitives themselves are [OpfsPathOperations]', shared with [OpfsDirectory]; this class says only that a
/// path starts at the OPFS root, and that every write — its own and those of the directories it opens — awaits
/// [beforeWrite] first.
///
/// It holds nothing between two calls, so it holds no state that could drift from disk. A caller with many questions
/// about one tree resolves it once instead ([openDirectory]).
///
/// [beforeWrite] is passed in, the way [OpfsDirectory.open] takes it, so that this file imports nothing from Flutter
/// and a browser suite under `dart test` can construct it.
class WebVfs extends OpfsPathOperations {
  WebVfs({super.beforeWrite});

  web.StorageManager get _storage => web.window.navigator.storage;

  /// Verifies the OPFS root is reachable. Requests nothing eagerly.
  Future<void> mount() async {
    await _storage.getDirectory().toDart;
  }

  Future<web.FileSystemDirectoryHandle> _root() => _storage.getDirectory().toDart;

  @override
  List<String> segmentsOf(String path) => splitVfsPath(path);

  /// Walks [segments] from the OPFS root; see [OpfsPathOperations.directoryAt] for how the two modes fail.
  @override
  Future<web.FileSystemDirectoryHandle?> directoryAt(List<String> segments, {required bool create}) async {
    return descendOpfs(await _root(), segments, create: create);
  }

  /// The directory at [path], walked to from the OPFS root once; its descendants are then reached from its handle.
  /// See `FsBackend.openDirectory`. Writes made through it await [beforeWrite] the way this adapter's do.
  Future<FsDirectory> openDirectory(String path) async {
    return OpfsDirectory.open(await _root(), path, beforeWrite: beforeWrite);
  }
}
