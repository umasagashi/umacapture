import 'dart:convert';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'byte_compare.dart';
import 'fs_backend.dart' show FsEntry;
import 'storage_persistence_web.dart' show requestPersistOnce;
import 'vfs_path.dart' show vfsChildPath;

/// Path separators accepted by the VFS. Hoisted because [WebVfs._split] runs at
/// the head of every single filesystem operation.
final RegExp _pathSeparator = RegExp(r'[/\\]');

/// Thin async adapter over the Origin Private File System (OPFS).
///
/// It resolves virtual [PathEntity] paths onto nested OPFS directory handles
/// and exposes the async read/write/list/delete/rename primitives the web
/// [FsBackend] needs. It uses only standard OPFS APIs reachable from the main
/// thread (`navigator.storage.getDirectory()`, `getDirectoryHandle`,
/// `getFileHandle`, `createWritable`, `removeEntry`) — no
/// `createSyncAccessHandle` (Worker-only) and no Chromium-only File System
/// Access entry points such as `showDirectoryPicker`.
///
/// There is no in-memory mirror or write-behind cache: every call goes straight
/// to OPFS, so the backend holds no state that could drift from disk.
class WebVfs {
  const WebVfs();

  web.StorageManager get _storage => web.window.navigator.storage;

  /// Verifies the OPFS root is reachable. Requests nothing eagerly.
  Future<void> mount() async {
    await _storage.getDirectory().toDart;
  }

  Future<web.FileSystemDirectoryHandle> _root() => _storage.getDirectory().toDart;

  List<String> _split(String path) => path.split(_pathSeparator).where((s) => s.isNotEmpty).toList();

  /// Walks [segments] from the OPFS root, returning the directory handle, or
  /// `null` when a lookup ([create] false) finds a segment missing.
  ///
  /// The two modes fail differently on purpose, because a failed
  /// `getDirectoryHandle` means two different things:
  ///
  /// * [create] false — the walk is a *question* ("is anything there?"). A
  ///   `NotFoundError` is the expected answer, so it becomes `null` and the
  ///   probing callers ([exists], [isFile], [isDirectory], [list], [delete])
  ///   keep reporting absence as a value rather than as an exception.
  /// * [create] true — the walk is an *instruction* ("make this path"). There is
  ///   no "expected" failure: the browser only rejects for a real fault (quota
  ///   exhausted, a file occupying a directory name, storage revoked). Returning
  ///   `null` there would let [createDir] report success for a directory it
  ///   never made, which is exactly the silent divergence from io's throwing
  ///   `Directory.create` that this rethrow removes.
  ///
  /// The browser's own error is propagated rather than a synthesized one: its
  /// name (`QuotaExceededError`, `TypeMismatchError`, …) is the diagnostic the
  /// caller needs, and [delete] already lets genuine failures through the same
  /// way.
  Future<web.FileSystemDirectoryHandle?> _dir(List<String> segments, {required bool create}) async {
    var handle = await _root();
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

  /// Resolves the file handle at [path], or `null` when the file (with [create]
  /// false) or its parent directory (either mode) is missing.
  ///
  /// The **parent chain is always resolved as a lookup**, never created, even
  /// with [create] true. `FsBackend.writeString`/`writeBytes` document that the
  /// caller creates the parent first, and `File.writeAsBytes` on io throws when
  /// it has not; auto-creating the ancestors here would make web the more
  /// permissive backend, so a shared code path that forgot a
  /// `parent.create(recursive: true)` would work in the browser and fail on
  /// desktop. It would also let a write land outside any prepared tree, which is
  /// exactly the property the transaction machinery reasons from.
  ///
  /// The final segment splits failure the same way [_dir] does, and for the same
  /// reason: with [create] true a rejection is a real fault, and swallowing it
  /// would make [writeBytes] report "no such file" for what is actually a quota
  /// or type error. With [create] false a rejection means the file is not there.
  Future<web.FileSystemFileHandle?> _file(String path, {required bool create}) async {
    final segments = _split(path);
    if (segments.isEmpty) return null;
    final parent = await _dir(segments.sublist(0, segments.length - 1), create: false);
    if (parent == null) return null;
    try {
      return await parent.getFileHandle(segments.last, web.FileSystemGetFileOptions(create: create)).toDart;
    } catch (_) {
      if (create) rethrow;
      return null;
    }
  }

  Future<bool> exists(String path) async {
    final segments = _split(path);
    if (segments.isEmpty) return true; // The OPFS root always exists.
    final parent = await _dir(segments.sublist(0, segments.length - 1), create: false);
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
  /// The record loader uses this to skip stray non-directory entries under
  /// `active/`, mirroring the desktop loader's `whereType<Directory>()` filter.
  Future<bool> isDirectory(String path) async {
    final segments = _split(path);
    if (segments.isEmpty) {
      return true; // The OPFS root is a directory.
    }
    final parent = await _dir(segments.sublist(0, segments.length - 1), create: false);
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
  /// The async counterpart of the io backend's `isFileSync`, used by tree walks
  /// (e.g. `DirectoryPath.copyTreeInto`) that must branch on entry kind without
  /// touching a synchronous FS API.
  Future<bool> isFile(String path) async {
    final segments = _split(path);
    if (segments.isEmpty) {
      return false; // The OPFS root is a directory, never a file.
    }
    final parent = await _dir(segments.sublist(0, segments.length - 1), create: false);
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

  Future<Uint8List> readBytes(String path) async {
    final handle = await _file(path, create: false);
    if (handle == null) {
      throw _notFound(path);
    }
    final file = await handle.getFile().toDart;
    final buffer = await file.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  /// The first [maxBytes] bytes of the file at [path]; see `FsBackend.readHead`
  /// for the contract.
  ///
  /// `getFile()` yields a `File`, which is a `Blob`, and `Blob.slice` returns a
  /// *view*: no byte is fetched until the returned blob's `arrayBuffer()` is
  /// awaited, which is why the same construction already bounds
  /// [sameFileBytes] to two chunks. The end offset is clamped to `file.size`
  /// because `slice` clamps silently and a bound larger than the file would
  /// otherwise read as an error the caller cannot see.
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

  Future<String> readString(String path) async => utf8.decode(await readBytes(path));

  /// The size of the file at [path], in bytes.
  ///
  /// `getFile()` hands back a `File` whose `size` is metadata, so this never
  /// pulls the contents into memory.
  Future<int> length(String path) async {
    final handle = await _file(path, create: false);
    if (handle == null) {
      throw _notFound(path);
    }
    return (await handle.getFile().toDart).size;
  }

  /// The last-modified timestamp of the file at [path].
  ///
  /// **A directory throws [UnsupportedError] — this is the web side of the
  /// divergence documented on `FsBackend.modified`, and the browser API is what
  /// forces it.** OPFS resolves a directory to a `FileSystemDirectoryHandle`,
  /// whose entire interface is `name` / `kind` / `isSameEntry` plus the child
  /// accessors: it exposes no timestamp, no size, and nothing that could be
  /// derived into one, and no proposal adds any. There is no `getFile()`
  /// equivalent to fall back on the way [length] does for a file. Faking it —
  /// returning the epoch, or the newest child's timestamp — would put a number
  /// in front of the user that the platform never measured, so the absence is
  /// reported instead.
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
  /// Slices both files chunk by chunk instead of reading them whole, so peak
  /// memory stays at two chunks and a difference near the start stops the scan
  /// immediately. `Blob.slice` is lazy: only the awaited `arrayBuffer()` reads.
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

  Future<void> writeBytes(String path, List<int> bytes) async {
    // Best-effort and once per session; see [requestPersistOnce] for why the
    // first write is the trigger and why an unanswered prompt is abandoned
    // rather than awaited. The state it settles on is readable from settings.
    await requestPersistOnce();
    final handle = await _file(path, create: true);
    if (handle == null) {
      throw _notFound(path);
    }
    final writable = await handle.createWritable().toDart;
    await writable.write(Uint8List.fromList(bytes).toJS).toDart;
    await writable.close().toDart;
  }

  Future<void> writeString(String path, String contents) => writeBytes(path, utf8.encode(contents));

  /// Creates the directory at [path], honouring the [recursive] contract.
  ///
  /// OPFS creates one level at a time — `getDirectoryHandle(create: true)` needs
  /// the parent handle in hand — so the non-recursive case is expressible here
  /// and is implemented rather than silently upgraded: with [recursive] false a
  /// missing parent throws, exactly as `Directory.create(recursive: false)` does
  /// on io. Creating an existing directory stays a no-op on both backends.
  Future<void> createDir(String path, {bool recursive = false}) async {
    final segments = _split(path);
    if (segments.isEmpty) {
      return; // The OPFS root always exists.
    }
    if (recursive) {
      await _dir(segments, create: true);
      return;
    }
    final parent = await _dir(segments.sublist(0, segments.length - 1), create: false);
    if (parent == null) {
      throw _notFound(path);
    }
    await parent.getDirectoryHandle(segments.last, web.FileSystemGetDirectoryOptions(create: true)).toDart;
  }

  /// Deletes the file or directory at [path].
  ///
  /// Deleting something that is not there is an error, as it is on io, and it is
  /// the *same* error whichever ancestor is missing. The two cases used to
  /// diverge — a missing parent reported success while a missing leaf rejected
  /// with the browser's `NotFoundError` — which made `PathEntity.delete` with
  /// `emptyOk: false` pass on web and throw on desktop for identical input.
  Future<void> delete(String path, {bool recursive = false}) async {
    final segments = _split(path);
    if (segments.isEmpty) {
      // Not the missing-entry case: the OPFS root always exists and has no
      // parent handle to remove it from, so there is nothing to do or report.
      return;
    }
    final parent = await _dir(segments.sublist(0, segments.length - 1), create: false);
    if (parent == null) {
      throw _notFound(path);
    }
    try {
      await parent.removeEntry(segments.last, web.FileSystemRemoveOptions(recursive: recursive)).toDart;
    } catch (_) {
      // Report a vanished entry as the same FileSystemException the missing
      // parent branch throws. Anything still present failed for another reason
      // (e.g. a non-recursive removal of a non-empty directory), so let the
      // browser's own error through.
      if (!await exists(path)) {
        throw _notFound(path);
      }
      rethrow;
    }
  }

  /// Lists [path], failing the way `Directory.list()` fails on io.
  ///
  /// A path that does not resolve to a directory throws instead of reporting an
  /// empty listing. Reporting `const []` for "missing" and for "a file is here"
  /// made web silently agree with any other empty tree: `sameDirectoryTree` read
  /// a file and an empty directory as **equal**, and `copyTreeInto` reported
  /// copying a file as success — which together let the record transaction reach
  /// its source delete with an empty payload.
  ///
  /// `_dir(create: false)` collapses both failures into `null` (its probing
  /// callers want absence as a value), so the kind is re-probed here to report
  /// the distinguishing error.
  Future<List<FsEntry>> list(String path, {bool recursive = false, bool withMetadata = false}) async {
    final dir = await _dir(_split(path), create: false);
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
      // [vfsChildPath], not a literal join: the OPFS root is the empty path, so
      // the rule has to be stated somewhere a test can reach. See that function.
      final childPath = vfsChildPath(prefix, handle.name);
      final isDirectory = handle.kind == 'directory';
      // The metadata comes off the handle the walk is already holding, so no
      // path is re-resolved from the root; `getFile()` reads the entry's
      // metadata record and not its bytes. A directory child carries neither
      // field: `FileSystemDirectoryHandle` has no metadata at all (the same
      // constraint [modified] throws for), and a directory's *size* is absent on
      // io as well, by the shared contract on `FsEntry`.
      //
      // A rejected `getFile()` costs this entry its metadata and nothing more.
      // The listing and the metadata read are two unsynchronized steps, so an
      // entry the iterator just handed out can be gone (or held by an open
      // writable) by the time it is asked for its size — a `temp/` directory a
      // capture is writing into does exactly that. The io backend answers the
      // same situation with a pair of `null`s (`metadataFromStat`), because
      // `FsEntry` contracts that "one unreachable child must not fail the whole
      // enumeration"; letting the rejection out here would make web throw away a
      // whole directory listing over one vanished file.
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
  /// Files only: the move is a byte copy followed by a delete, so passing a
  /// directory throws (`readBytes` finds no file handle and reports
  /// [FileSystemException]). OPFS has no directory rename to fall back on, and
  /// synthesising one here would be neither atomic nor crash-safe — a directory
  /// move belongs in `RecordDirectoryTransaction`, which stages and publishes
  /// the tree recoverably, or in `DirectoryPath.moveAsyncSafe` where losing the
  /// destination on a crash is acceptable.
  ///
  /// Not atomic even for a file: a crash between the two steps leaves both
  /// copies. Callers that need durability must go through a transaction.
  Future<void> rename(String source, String destination) async {
    // OPFS has no atomic rename, so copy the bytes across and drop the original.
    await writeBytes(destination, await readBytes(source));
    await delete(source);
  }

  Future<void> copyFile(String source, String destination) async {
    await writeBytes(destination, await readBytes(source));
  }

  Exception _notFound(String path) => FileSystemException('No such file or directory', path);

  Exception _notADirectory(String path) => FileSystemException('Not a directory', path);
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

/// Binds the async-iterator methods (`values()`) that `package:web` omits from
/// [web.FileSystemDirectoryHandle]. `values()` yields the child handles.
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
