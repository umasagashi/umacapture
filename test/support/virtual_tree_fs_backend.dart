// A backend whose whole content is a table of directories and their children,
// used to describe a *path shape* that the VM's own filesystem cannot hold.
//
// WHY NOT A REAL TEMPORARY DIRECTORY. The io-backed fixtures elsewhere in the
// suite give every root a distinct, non-empty absolute path, because that is the
// only kind a real filesystem has. Web's roots are not like that: OPFS is
// origin-private, so `platform_dirs_web.dart` returns `DirectoryPath([])` — the
// **empty** path — for the support and executable directories, and the documents
// directory is `umacapture`, i.e. a child of that same root. Neither the empty
// root nor one root nesting inside another can be built out of `Directory.systemTemp`.
//
// WHY THE CHILD SPELLING IS A PARAMETER. A directory listing is the one place a
// backend *invents* a path rather than being handed one, and the two backends
// invent them differently:
//
//   * io returns `FileSystemEntity.path`, i.e. the parent joined to the name with
//     the platform separator;
//   * `WebVfs._walk` composes `'$prefix/${handle.name}'` verbatim.
//
// Those agree for every non-empty prefix and disagree for the empty one, where
// web yields a leading separator (`/modules`) that no `PathInfo` getter ever
// produces (`PathInfo.modulesDir.path` is `modules`). Code that compares a listed
// path against a `PathInfo` path is sensitive to exactly that, so the spelling
// has to be describable here rather than fixed.
//
// WHAT THIS DOES NOT MODEL. Everything except `exists` and `list`: any other
// member throws through [noSuchMethod]. There are no bytes behind these entries,
// so nothing that reads or writes one will work, and the sizes are whatever the
// table says. It describes a shape, not a filesystem.
import 'package:umacapture/src/core/fs/fs_backend.dart';

/// One child of a directory in a [VirtualTreeFsBackend]'s table.
typedef VirtualEntry = ({String name, bool isDirectory, int? size});

/// Joins a directory path to a child name the way one backend's listing does.
typedef ChildSpelling = String Function(String prefix, String name);

/// The spelling `Directory.list()` produces on Windows: parent, separator, name.
String windowsChildSpelling(String prefix, String name) => '$prefix\\$name';

/// The spelling `WebVfs._walk` produces: `'$prefix/${handle.name}'`, with no
/// special case for the empty OPFS root — which is what puts the leading
/// separator on a child of it.
String opfsChildSpelling(String prefix, String name) => '$prefix/$name';

class VirtualTreeFsBackend implements FsBackend {
  VirtualTreeFsBackend({required this.tree, required this.spelling});

  /// Directory path (spelled the way `PathInfo` spells it) to its direct
  /// children. A path absent from this map does not exist.
  final Map<String, List<VirtualEntry>> tree;

  final ChildSpelling spelling;

  @override
  Future<bool> exists(String path) async => tree.containsKey(path);

  @override
  Future<List<FsEntry>> list(
    String path, {
    bool recursive = false,
    bool followLinks = false,
    bool withMetadata = false,
  }) async {
    final children = tree[path];
    if (children == null) {
      throw StateError('No directory in the table at "$path".');
    }
    if (recursive) {
      throw UnimplementedError('This table describes one level per directory.');
    }
    return [
      for (final child in children)
        (
          path: spelling(path, child.name),
          isDirectory: child.isDirectory,
          // Both backends agree a directory has no size; the rest follows
          // `FsEntry`, where metadata is absent unless it was asked for.
          size: child.isDirectory || !withMetadata ? null : child.size,
          modified: null,
        ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError('VirtualTreeFsBackend only answers exists() and list().');
  }
}
