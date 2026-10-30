/// The OPFS operations `WebVfs` and [OpfsDirectory] are both built on ([OpfsPathOperations]), and the directory a
/// caller resolves once and then asks and changes things beneath ([OpfsDirectory]).
///
/// Kept free of `package:flutter` — `web_vfs.dart` is not, through `requestPersistOnce` — so that
/// `dart test --platform chrome` can compile it: the operations and the resolved directory are reachable from a
/// browser suite only here.
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'byte_compare.dart';
import 'fs_directory.dart';
import 'vfs_path.dart' show vfsChildPath;

/// Path separators accepted by the VFS. Hoisted because [splitVfsPath] runs at the head of every single filesystem
/// operation.
final RegExp _pathSeparator = RegExp(r'[/\\]');

/// The segments of the VFS path [path]; the OPFS root is the path with none.
List<String> splitVfsPath(String path) => path.split(_pathSeparator).where((s) => s.isNotEmpty).toList();

/// Walks [segments] down from [start], returning the directory handle, or `null` when a lookup ([create] false)
/// finds a segment missing or naming a file. With [create] true every failure is rethrown;
/// [OpfsPathOperations.directoryAt] states why the two modes fail differently.
Future<web.FileSystemDirectoryHandle?> descendOpfs(
  web.FileSystemDirectoryHandle start,
  List<String> segments, {
  required bool create,
}) async {
  var handle = start;
  for (final segment in segments) {
    try {
      handle = await handle.getDirectoryHandle(segment, web.FileSystemGetDirectoryOptions(create: create)).toDart;
    } catch (_) {
      if (create) rethrow;
      return null;
    }
  }
  return handle;
}

/// The whole contents of the file behind [handle].
Future<Uint8List> readOpfsFile(web.FileSystemFileHandle handle) async {
  final file = await handle.getFile().toDart;
  final buffer = await file.arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}

/// What a write awaits before its first byte; see `requestPersistOnce`, which `WebVfs` passes.
typedef OpfsBeforeWrite = Future<void> Function();

/// The async read/write/list/delete/rename primitives over the Origin Private File System, written once for every way
/// of reaching the directories a path names.
///
/// A subclass says only how a path splits into segments ([segmentsOf]) and how the directory handle at some segments
/// is reached ([directoryAt]): `WebVfs` walks from the OPFS root for every operation, and [OpfsDirectory] walks from a
/// directory it resolved once, and — made by [OpfsDirectory.remembering] — from the deepest directory it already
/// walked to. Every operation is the same code either way, so the two answer the same question the same way.
///
/// It uses only standard OPFS APIs reachable from the main thread (`getDirectoryHandle`, `getFileHandle`,
/// `createWritable`, `removeEntry`) — no `createSyncAccessHandle` (Worker-only) and no Chromium-only File System
/// Access entry points such as `showDirectoryPicker`. There is no in-memory mirror or write-behind cache: every call
/// goes straight to OPFS, and a remembering directory holds handles, never contents.
abstract class OpfsPathOperations implements FsPathOperations {
  OpfsPathOperations({this.beforeWrite});

  /// Awaited at the head of every write.
  final OpfsBeforeWrite? beforeWrite;

  /// The segments [path] names, as [directoryAt] counts them.
  List<String> segmentsOf(String path);

  /// [segmentsOf] for a path [delete] is asked to remove.
  List<String> segmentsToRemove(String path) => segmentsOf(path);

  /// The directory handle at [segments], or `null` when a lookup ([create] false) finds a segment missing.
  ///
  /// The two modes fail differently on purpose, because a failed `getDirectoryHandle` means two different things:
  ///
  /// * [create] false — the walk is a *question* ("is anything there?"). A `NotFoundError` is the expected answer,
  ///   so it becomes `null` and the probing callers ([exists], [isFile], [isDirectory], [list], [delete]) keep
  ///   reporting absence as a value rather than as an exception.
  /// * [create] true — the walk is an *instruction* ("make this path"). There is no "expected" failure: the browser
  ///   only rejects for a real fault (quota exhausted, a file occupying a directory name, storage revoked).
  ///   Returning `null` there would let [createDir] report success for a directory it never made, which is exactly
  ///   the silent divergence from io's throwing `Directory.create` that this rethrow removes.
  ///
  /// The browser's own error is propagated rather than a synthesized one: its name (`QuotaExceededError`,
  /// `TypeMismatchError`, …) is the diagnostic the caller needs, and [delete] already lets genuine failures through
  /// the same way.
  Future<web.FileSystemDirectoryHandle?> directoryAt(List<String> segments, {required bool create});

  /// Holds [handle] as the directory at [segments], which an operation has just created there itself.
  void rememberAt(List<String> segments, web.FileSystemDirectoryHandle handle) {}

  /// Drops whatever is held for the directory at [segments] and beneath it, which [delete] is about to remove.
  void forgetBeneath(List<String> segments) {}

  /// Resolves the file handle at [path], or `null` when the file (with [create] false) or its parent directory
  /// (either mode) is missing.
  ///
  /// The **parent chain is always resolved as a lookup**, never created, even with [create] true.
  /// `FsBackend.writeString`/`writeBytes` document that the caller creates the parent first, and `File.writeAsBytes`
  /// on io throws when it has not; auto-creating the ancestors here would make web the more permissive backend, so a
  /// shared code path that forgot a `parent.create(recursive: true)` would work in the browser and fail on desktop.
  /// It would also let a write land outside any prepared tree, which is exactly the property the transaction
  /// machinery reasons from.
  ///
  /// The final segment splits failure the same way [directoryAt] does, and for the same reason: with [create] true a
  /// rejection is a real fault, and swallowing it would make [writeBytes] report "no such file" for what is actually
  /// a quota or type error. With [create] false a rejection means the file is not there.
  Future<web.FileSystemFileHandle?> _file(String path, {required bool create}) async {
    final segments = segmentsOf(path);
    if (segments.isEmpty) return null;
    final parent = await directoryAt(segments.sublist(0, segments.length - 1), create: false);
    if (parent == null) return null;
    try {
      return await parent.getFileHandle(segments.last, web.FileSystemGetFileOptions(create: create)).toDart;
    } catch (_) {
      if (create) rethrow;
      return null;
    }
  }

  @override
  Future<bool> exists(String path) async {
    final segments = segmentsOf(path);
    if (segments.isEmpty) return await directoryAt(segments, create: false) != null;
    final parent = await directoryAt(segments.sublist(0, segments.length - 1), create: false);
    if (parent == null) return false;
    final name = segments.last;
    try {
      await parent.getFileHandle(name).toDart;
      return true;
    } catch (_) {
      // Not a file; fall through and probe as a directory.
    }
    try {
      await parent.getDirectoryHandle(name).toDart;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Whether [path] resolves to a directory (as opposed to a file or nothing).
  ///
  /// The record loader uses this to skip stray non-directory entries under `active/`, mirroring the desktop loader's
  /// `whereType<Directory>()` filter.
  Future<bool> isDirectory(String path) async {
    final segments = segmentsOf(path);
    if (segments.isEmpty) return await directoryAt(segments, create: false) != null;
    final parent = await directoryAt(segments.sublist(0, segments.length - 1), create: false);
    if (parent == null) {
      return false;
    }
    try {
      await parent.getDirectoryHandle(segments.last).toDart;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Whether [path] resolves to a file (as opposed to a directory or nothing).
  ///
  /// The async counterpart of the io backend's `isFileSync`, used by tree walks (e.g. `DirectoryPath.copyTreeInto`)
  /// that must branch on entry kind without touching a synchronous FS API.
  @override
  Future<bool> isFile(String path) async {
    final segments = segmentsOf(path);
    if (segments.isEmpty) {
      return false; // A directory, never a file.
    }
    final parent = await directoryAt(segments.sublist(0, segments.length - 1), create: false);
    if (parent == null) {
      return false;
    }
    try {
      await parent.getFileHandle(segments.last).toDart;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    final bytes = await readBytesIfPresent(path);
    if (bytes == null) {
      throw _notFound(path);
    }
    return bytes;
  }

  /// The bytes of the file at [path], or null where [_file] finds none: one walk and one file lookup.
  @override
  Future<Uint8List?> readBytesIfPresent(String path) async {
    final handle = await _file(path, create: false);
    if (handle == null) {
      return null;
    }
    return readOpfsFile(handle);
  }

  /// The first [maxBytes] bytes of the file at [path]; see `FsBackend.readHead` for the contract.
  ///
  /// `getFile()` yields a `File`, which is a `Blob`, and `Blob.slice` returns a *view*: no byte is fetched until the
  /// returned blob's `arrayBuffer()` is awaited, which is why the same construction already bounds [sameFileBytes]
  /// to two chunks. The end offset is clamped to `file.size` because `slice` clamps silently and a bound larger than
  /// the file would otherwise read as an error the caller cannot see.
  Future<Uint8List> readHead(String path, int maxBytes) async {
    final handle = await _file(path, create: false);
    if (handle == null) {
      throw _notFound(path);
    }
    if (maxBytes <= 0) {
      return Uint8List(0);
    }
    final file = await handle.getFile().toDart;
    return _blobBytes(file.slice(0, math.min(maxBytes, file.size)));
  }

  @override
  Future<String> readString(String path) async => utf8.decode(await readBytes(path));

  /// The size of the file at [path], in bytes.
  ///
  /// `getFile()` hands back a `File` whose `size` is metadata, so this never pulls the contents into memory.
  @override
  Future<int> length(String path) async {
    final handle = await _file(path, create: false);
    if (handle == null) {
      throw _notFound(path);
    }
    return (await handle.getFile().toDart).size;
  }

  /// The last-modified timestamp of the file at [path].
  ///
  /// **A directory throws [UnsupportedError] — this is the web side of the divergence documented on
  /// `FsBackend.modified`, and the browser API is what forces it.** OPFS resolves a directory to a
  /// `FileSystemDirectoryHandle`, whose entire interface is `name` / `kind` / `isSameEntry` plus the child accessors:
  /// it exposes no timestamp, no size, and nothing that could be derived into one, and no proposal adds any. There is
  /// no `getFile()` equivalent to fall back on the way [length] does for a file. Faking it — returning the epoch, or
  /// the newest child's timestamp — would put a number in front of the user that the platform never measured, so the
  /// absence is reported instead.
  Future<DateTime> modified(String path) async {
    final handle = await _file(path, create: false);
    if (handle == null) {
      if (await isDirectory(path)) {
        throw UnsupportedError(
          'FsBackend.modified is not available for a directory on web '
          '(FileSystemDirectoryHandle exposes no metadata): $path',
        );
      }
      throw _notFound(path);
    }
    return DateTime.fromMillisecondsSinceEpoch((await handle.getFile().toDart).lastModified);
  }

  /// Whether the files at [left] and [right] hold exactly the same bytes.
  ///
  /// Slices both files chunk by chunk instead of reading them whole, so peak memory stays at two chunks and a
  /// difference near the start stops the scan immediately. `Blob.slice` is lazy: only the awaited `arrayBuffer()`
  /// reads.
  @override
  Future<bool> sameFileBytes(String left, String right) async {
    final leftHandle = await _file(left, create: false);
    if (leftHandle == null) {
      throw _notFound(left);
    }
    final rightHandle = await _file(right, create: false);
    if (rightHandle == null) {
      throw _notFound(right);
    }
    final leftFile = await leftHandle.getFile().toDart;
    final rightFile = await rightHandle.getFile().toDart;
    final size = leftFile.size;
    if (size != rightFile.size) {
      return false;
    }
    for (var offset = 0; offset < size; offset += fileCompareChunkSize) {
      final end = math.min(offset + fileCompareChunkSize, size);
      final leftChunk = await _blobBytes(leftFile.slice(offset, end));
      final rightChunk = await _blobBytes(rightFile.slice(offset, end));
      if (!sameByteRange(leftChunk, rightChunk, end - offset)) {
        return false;
      }
    }
    return true;
  }

  Future<Uint8List> _blobBytes(web.Blob blob) async {
    final buffer = await blob.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  /// Writes [bytes] to [path], replacing any file there.
  ///
  /// [flush] is not consulted: an OPFS write lands only at the writable stream's `close()`, which this awaits.
  @override
  Future<void> writeBytes(String path, List<int> bytes, {bool flush = false}) async {
    await beforeWrite?.call();
    final handle = await _file(path, create: true);
    if (handle == null) {
      throw _notFound(path);
    }
    final writable = await handle.createWritable().toDart;
    await writable.write(Uint8List.fromList(bytes).toJS).toDart;
    await writable.close().toDart;
  }

  @override
  Future<void> writeString(String path, String contents) => writeBytes(path, utf8.encode(contents));

  /// Creates the directory at [path], honouring the [recursive] contract.
  ///
  /// OPFS creates one level at a time — `getDirectoryHandle(create: true)` needs the parent handle in hand — so the
  /// non-recursive case is expressible here and is implemented rather than silently upgraded: with [recursive] false
  /// a missing parent throws, exactly as `Directory.create(recursive: false)` does on io. Creating an existing
  /// directory stays a no-op on both backends.
  @override
  Future<void> createDir(String path, {bool recursive = false}) async {
    final segments = segmentsOf(path);
    if (recursive || segments.isEmpty) {
      await directoryAt(segments, create: true);
      return;
    }
    final parent = await directoryAt(segments.sublist(0, segments.length - 1), create: false);
    if (parent == null) {
      throw _notFound(path);
    }
    rememberAt(
      segments,
      await parent.getDirectoryHandle(segments.last, web.FileSystemGetDirectoryOptions(create: true)).toDart,
    );
  }

  /// Deletes the file or directory at [path].
  ///
  /// Deleting something that is not there is an error, as it is on io, and it is the *same* error whichever ancestor
  /// is missing: a missing parent and a missing leaf both throw the [FileSystemException] below, so
  /// `PathEntity.delete` with `emptyOk: false` behaves on web as it does on desktop for identical input.
  ///
  /// What is held for [path] and beneath it is forgotten before the removal is attempted, so a removal that fails part
  /// way leaves nothing held that might name a directory it took.
  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    final segments = segmentsToRemove(path);
    if (segments.isEmpty) {
      // Not the missing-entry case: the OPFS root always exists and has no parent handle to remove it from, so there
      // is nothing to do or report.
      return;
    }
    forgetBeneath(segments);
    final parent = await directoryAt(segments.sublist(0, segments.length - 1), create: false);
    if (parent == null) {
      throw _notFound(path);
    }
    try {
      await parent.removeEntry(segments.last, web.FileSystemRemoveOptions(recursive: recursive)).toDart;
    } catch (_) {
      // Report a vanished entry as the same FileSystemException the missing parent branch throws. Anything still
      // present failed for another reason (e.g. a non-recursive removal of a non-empty directory), so let the
      // browser's own error through.
      if (!await exists(path)) {
        throw _notFound(path);
      }
      rethrow;
    }
  }

  /// Lists [path], failing the way `Directory.list()` fails on io.
  ///
  /// A path that does not resolve to a directory throws instead of reporting an empty listing. Reporting `const []`
  /// for "missing" and for "a file is here" would make web silently agree with any other empty tree:
  /// `sameDirectoryTree` would read a file and an empty directory as **equal**, and `copyTreeInto` would report
  /// copying a file as success — which together would let the record transaction reach its source delete with an
  /// empty payload.
  ///
  /// `directoryAt(create: false)` collapses both failures into `null` (its probing callers want absence as a value),
  /// so the kind is re-probed here to report the distinguishing error. [followLinks] is not consulted: OPFS has no
  /// links.
  @override
  Future<List<FsEntry>> list(
    String path, {
    bool recursive = false,
    bool followLinks = false,
    bool withMetadata = false,
  }) async {
    final dir = await directoryAt(segmentsOf(path), create: false);
    if (dir == null) {
      throw await isFile(path) ? _notADirectory(path) : _notFound(path);
    }
    final result = <FsEntry>[];
    await _walk(dir, path, recursive, withMetadata, result);
    return result;
  }

  Future<void> _walk(
    web.FileSystemDirectoryHandle dir,
    String prefix,
    bool recursive,
    bool withMetadata,
    List<FsEntry> out,
  ) async {
    final iterator = _DirIterable(dir).values();
    while (true) {
      final step = await iterator.next().toDart;
      if (step.done.toDart) break;
      final value = step.value;
      if (value == null) break;
      final handle = value as web.FileSystemHandle;
      // [vfsChildPath], not a literal join: the OPFS root is the empty path, so the rule has to be stated somewhere a
      // test can reach. See that function.
      final childPath = vfsChildPath(prefix, handle.name);
      final isDirectory = handle.kind == 'directory';
      // The metadata comes off the handle the walk is already holding, so no path is re-resolved from the root;
      // `getFile()` reads the entry's metadata record and not its bytes. A directory child carries neither field:
      // `FileSystemDirectoryHandle` has no metadata at all (the same constraint [modified] throws for), and a
      // directory's *size* is absent on io as well, by the shared contract on `FsEntry`.
      //
      // A rejected `getFile()` costs this entry its metadata and nothing more. The listing and the metadata read are
      // two unsynchronized steps, so an entry the iterator just handed out can be gone (or held by an open writable)
      // by the time it is asked for its size — a `temp/` directory a capture is writing into does exactly that. The
      // io backend answers the same situation with a pair of `null`s (`metadataFromStat`), because `FsEntry`
      // contracts that "one unreachable child must not fail the whole enumeration"; letting the rejection out here
      // would make web throw away a whole directory listing over one vanished file.
      web.File? file;
      if (withMetadata && !isDirectory) {
        try {
          file = await (handle as web.FileSystemFileHandle).getFile().toDart;
        } catch (_) {
          file = null;
        }
      }
      out.add((
        path: childPath,
        isDirectory: isDirectory,
        size: file?.size,
        modified: file == null ? null : DateTime.fromMillisecondsSinceEpoch(file.lastModified),
      ));
      if (recursive && isDirectory) {
        await _walk(handle as web.FileSystemDirectoryHandle, childPath, recursive, withMetadata, out);
      }
    }
  }

  /// Moves the **file** at [source] to [destination].
  ///
  /// Files only: the move is a byte copy followed by a delete, so passing a directory throws ([readBytes] finds no
  /// file handle and reports [FileSystemException]). OPFS has no directory rename to fall back on, and synthesising
  /// one here would be neither atomic nor crash-safe — a directory move belongs in `RecordDirectoryTransaction`,
  /// which stages and publishes the tree recoverably, or in `DirectoryPath.moveAsyncSafe` where losing the
  /// destination on a crash is acceptable.
  ///
  /// Not atomic even for a file: a crash between the two steps leaves both copies. Callers that need durability must
  /// go through a transaction.
  @override
  Future<void> rename(String source, String destination) async {
    // OPFS has no atomic rename, so copy the bytes across and drop the original.
    await writeBytes(destination, await readBytes(source));
    await delete(source);
  }

  @override
  Future<void> copyFile(String source, String destination) async {
    await writeBytes(destination, await readBytes(source));
  }

  Exception _notFound(String path) => FileSystemException('No such file or directory', path);

  Exception _notADirectory(String path) => FileSystemException('Not a directory', path);
}

/// A directory resolved from the OPFS root once; see [FsDirectory].
///
/// Holds the directory's handle, and walks only the segments below it for each question, so a record's three files
/// cost one walk from the root between them rather than one each, and a name that is not there costs one failed
/// lookup. One made by [remembering] also holds every directory beneath it that a question or a change walks to,
/// keyed by its segments, so a path asked again — or a path below one asked before — starts from the deepest of them
/// it already holds; [delete] forgets the removed directory and everything beneath it before it removes it.
class OpfsDirectory extends OpfsPathOperations implements FsDirectory {
  OpfsDirectory._(this._root, this.path, this._handle, this._remembered, {super.beforeWrite})
    : _ownSegments = splitVfsPath(path);

  /// Resolves [path] from [root]. [beforeWrite] is awaited at the head of every write made through it.
  static Future<OpfsDirectory> open(
    web.FileSystemDirectoryHandle root,
    String path, {
    OpfsBeforeWrite? beforeWrite,
  }) async {
    final handle = await descendOpfs(root, splitVfsPath(path), create: false);
    return OpfsDirectory._(root, path, handle, null, beforeWrite: beforeWrite);
  }

  /// The OPFS root this directory was resolved from, for creating it when it was not there.
  final web.FileSystemDirectoryHandle _root;

  final List<String> _ownSegments;

  @override
  final String path;

  /// The directory, or null where none was at [path] when it was opened and nothing has created it through this one
  /// since.
  web.FileSystemDirectoryHandle? _handle;

  /// The directories beneath this one walked to so far, keyed by their segments below it joined with `/` — no
  /// segment can hold one — or null where this one remembers nothing beneath it.
  final Map<String, web.FileSystemDirectoryHandle>? _remembered;

  @override
  OpfsDirectory remembering() => OpfsDirectory._(_root, path, _handle, {}, beforeWrite: beforeWrite);

  @override
  List<String> segmentsOf(String path) => segmentsBelow(this.path, path);

  @override
  List<String> segmentsToRemove(String path) => segmentsToRemoveBelow(this.path, path);

  @override
  Future<web.FileSystemDirectoryHandle?> directoryAt(List<String> segments, {required bool create}) async {
    final opened = _handle ?? (create ? _handle = await descendOpfs(_root, _ownSegments, create: true) : null);
    if (opened == null) return null;
    final remembered = _remembered;
    if (remembered == null) {
      return descendOpfs(opened, segments, create: create);
    }
    var handle = opened;
    var walked = 0;
    for (var depth = segments.length; depth > 0; depth--) {
      final held = remembered[_key(segments.take(depth))];
      if (held != null) {
        handle = held;
        walked = depth;
        break;
      }
    }
    for (; walked < segments.length; walked++) {
      final next = await descendOpfs(handle, [segments[walked]], create: create);
      if (next == null) return null;
      remembered[_key(segments.take(walked + 1))] = handle = next;
    }
    return handle;
  }

  @override
  void rememberAt(List<String> segments, web.FileSystemDirectoryHandle handle) {
    _remembered?[_key(segments)] = handle;
  }

  static String _key(Iterable<String> segments) => segments.join('/');

  @override
  void forgetBeneath(List<String> segments) {
    final key = _key(segments);
    _remembered?.removeWhere((held, _) => held == key || held.startsWith('$key/'));
  }
}

/// Binds the async-iterator methods (`values()`) that `package:web` omits from [web.FileSystemDirectoryHandle].
/// `values()` yields the child handles.
extension type _DirIterable(JSObject _handle) implements JSObject {
  external _AsyncIterator values();
}

extension type _AsyncIterator._(JSObject _) implements JSObject {
  external JSPromise<_IterResult> next();
}

extension type _IterResult._(JSObject _) implements JSObject {
  external JSBoolean get done;
  external JSAny? get value;
}

/// A minimal, web-only stand-in for `dart:io`'s `FileSystemException`, thrown by
/// the OPFS adapter so error handling reads the same as on desktop.
class FileSystemException implements Exception {
  final String message;
  final String path;

  FileSystemException(this.message, this.path);

  @override
  String toString() => 'FileSystemException: $message, path = $path';
}
