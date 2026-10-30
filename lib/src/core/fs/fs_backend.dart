import 'package:flutter/foundation.dart';

import 'fs_backend_io.dart' if (dart.library.js_interop) 'fs_backend_web.dart';
import 'fs_directory.dart';

export 'fs_directory.dart';

/// Filesystem leaf operations that back [PathEntity] and the record store.
///
/// The **async** surface is the primary, cross-platform contract: the desktop
/// ([dart:io]) and web (OPFS) backends both implement it natively. The **sync**
/// surface is a desktop-only escape hatch for the paths that genuinely require
/// synchronous I/O (capture ingest, isolate bulk-load); the web backend
/// implements every sync method as `throw UnsupportedError`, and no code path
/// that runs on web reaches them.
///
/// Paths are the platform-joined strings produced by [PathEntity.path]. On the
/// io backend they are OS paths; on the web backend they are virtual paths whose
/// segments map 1:1 onto nested OPFS directories.
abstract interface class FsBackend implements FsPathOperations {
  // --- async: primary, both platforms -------------------------------------

  /// Whether a file or directory exists at [path].
  @override
  Future<bool> exists(String path);

  /// Reads [path] as a UTF-8 string.
  @override
  Future<String> readString(String path);

  /// Reads [path] as raw bytes.
  @override
  Future<Uint8List> readBytes(String path);

  /// Reads [path] as raw bytes, or null where there is no file at [path].
  ///
  /// One lookup that answers both questions, for a file that is often not there: asking [exists] first is a
  /// second lookup of the same name, and on web each lookup walks the path from the OPFS root. Any other
  /// failure throws, as [readBytes] does.
  @override
  Future<Uint8List?> readBytesIfPresent(String path);

  /// The directory at [path], resolved once, for a caller with several questions about what lies beneath it.
  ///
  /// Never throws for a [path] that is not a directory: that directory has no descendants, so every read from it
  /// finds nothing, which is what the same reads by path would find. On web it is the walk from the OPFS root, made
  /// once instead of once per question; on io there is nothing to resolve, and the answer is a
  /// [PassThroughFsDirectory] that asks this backend by path — the same answers at the same cost as before.
  Future<FsDirectory> openDirectory(String path);

  /// Reads **at most** [maxBytes] bytes from the start of [path], never the
  /// whole file.
  ///
  /// The bound is the point of the method, so both backends have to reach it
  /// through a primitive that takes a range rather than by reading and then
  /// cutting: io opens the file and streams only `[0, maxBytes)`
  /// (`File.openRead`), web slices the `Blob` that `getFile()` returns
  /// (`Blob.slice`, which is lazy — only the awaited `arrayBuffer()` reads).
  /// A read-then-trim implementation satisfies the return value and none of the
  /// contract: the caller asks for a head precisely because materialising the
  /// file is what it cannot afford, and on web that cost is a copy into the
  /// wasm heap on the thread that paints.
  ///
  /// Returns fewer than [maxBytes] bytes only when the file is shorter, and an
  /// empty list for a non-positive [maxBytes]. Throws when [path] does not
  /// resolve to a file, as [readBytes] does.
  Future<Uint8List> readHead(String path, int maxBytes);

  /// Writes [contents] to [path] as UTF-8, replacing any existing file.
  ///
  /// The caller is responsible for creating the parent directory first (as
  /// [FilePath.writeAsString] does); a missing parent is an error on **both**
  /// backends.
  @override
  Future<void> writeString(String path, String contents);

  /// Writes [bytes] to [path], replacing any existing file.
  ///
  /// Same parent-directory contract as [writeString]. With [flush] the io backend syncs the file to the
  /// disk before the future completes; the web backend ignores it, because an OPFS write lands only at the
  /// writable stream's `close()`, which every write already awaits.
  @override
  Future<void> writeBytes(String path, List<int> bytes, {bool flush = false});

  /// Lists the entries directly (or, with [recursive], transitively) under
  /// [path], with each entry's kind.
  ///
  /// Throws when [path] does not resolve to a directory — including when it does
  /// not exist and when it names a file. "Missing" must never be reported as "an
  /// empty directory": callers such as `sameDirectoryTree` would then read two
  /// mismatched shapes as equal.
  ///
  /// With [withMetadata] the entries also carry [FsEntry.size] and
  /// [FsEntry.modified]; see [FsEntry] for what each backend can fill in and for
  /// why it is opt-in.
  @override
  Future<List<FsEntry>> list(
    String path, {
    bool recursive = false,
    bool followLinks = false,
    bool withMetadata = false,
  });

  /// Deletes the file or directory at [path].
  @override
  Future<void> delete(String path, {bool recursive = false});

  /// Renames/moves [source] to [destination] (same volume on io).
  ///
  /// **Files only** on both backends: io renames through `File`, and OPFS has no
  /// directory rename at all. Moving a directory goes through
  /// [DirectoryPath.moveSyncSafe] / [DirectoryPath.moveAsyncSafe], or
  /// `RecordDirectoryTransaction` when the move must be recoverable.
  @override
  Future<void> rename(String source, String destination);

  /// Whether [rename] of a file onto an existing one replaces it atomically, so that a reader, or a
  /// crash, finds either the old file or the new one and never neither nor a torn one.
  ///
  /// True on io, where a same-volume rename is the operating system's replace. False on web: OPFS has no
  /// rename, and `WebVfs.rename` is a byte copy followed by a delete, interruptible between the two.
  bool get renameReplacesFileAtomically;

  /// Creates the directory at [path].
  ///
  /// With [recursive] false the parent must already exist, and a missing parent
  /// is an error; with [recursive] true every missing ancestor is created.
  /// Creating a directory that already exists is a no-op on both backends.
  @override
  Future<void> createDir(String path, {bool recursive = false});

  /// Copies the file [source] to [destination].
  @override
  Future<void> copyFile(String source, String destination);

  /// The size of the file at [path], in bytes.
  ///
  /// Throws when [path] does not resolve to a file. Tree comparison uses this to
  /// reject a differing pair without reading either file's contents.
  @override
  Future<int> length(String path);

  /// The last-modified timestamp of the file or directory at [path].
  ///
  /// Throws when [path] does not resolve to anything. On io a missing path is
  /// *not* an exception at the OS layer — `FileStat.stat` answers with a
  /// `notFound` stat whose `modified` is the epoch — so the io backend converts
  /// that answer into a throw rather than handing back 1970 as if it were a
  /// timestamp.
  ///
  /// **Divergence, web only: a directory throws [UnsupportedError].** The
  /// constraint is the browser API, not a choice: OPFS hands out a
  /// `FileSystemDirectoryHandle`, and that interface carries no metadata member
  /// of any kind — no size, no timestamps — in the standard or in any proposal.
  /// The file case is unaffected, because a `FileSystemFileHandle` yields a
  /// `File` whose `lastModified` is exactly this value. The throw is stated here,
  /// in the shared interface, so every reader of the contract sees it; the web
  /// backend only carries it out.
  ///
  /// Callers that want a directory's timestamp on both platforms must aggregate
  /// over its descendants instead of asking for the directory itself.
  Future<DateTime> modified(String path);

  /// Whether the files at [a] and [b] hold exactly the same bytes.
  ///
  /// Streams both files in fixed-size chunks and stops at the first difference,
  /// so peak memory is bounded by the chunk size rather than by the file size,
  /// and a mismatch near the start costs one chunk instead of two full reads.
  /// Throws when either path does not resolve to a file.
  @override
  Future<bool> sameFileBytes(String a, String b);

  /// Whether [path] currently resolves to a file (as opposed to a directory or
  /// nothing).
  ///
  /// The async counterpart of [isFileSync], usable on web: tree walks that must
  /// branch on entry kind (e.g. [DirectoryPath.copyTreeInto]) go through this so
  /// they never touch the sync surface the web backend rejects.
  @override
  Future<bool> isFile(String path);

  // --- sync: io backend only (throws on web) -------------------------------

  /// Synchronous counterpart of [exists] (io backend only).
  bool existsSync(String path);

  /// Synchronous counterpart of [readString] (io backend only).
  String readStringSync(String path);

  /// Synchronous counterpart of [readBytes] (io backend only).
  Uint8List readBytesSync(String path);

  /// Synchronous counterpart of [readBytesIfPresent] (io backend only).
  Uint8List? readBytesIfPresentSync(String path);

  /// Synchronous counterpart of [writeString] (io backend only).
  void writeStringSync(String path, String contents);

  /// Synchronous counterpart of [writeBytes], [flush] included (io backend only).
  void writeBytesSync(String path, List<int> bytes, {bool flush = false});

  /// Synchronous counterpart of [list] (io backend only).
  List<FsEntry> listSync(String path, {bool recursive = false, bool followLinks = false, bool withMetadata = false});

  /// Synchronous counterpart of [delete] (io backend only).
  void deleteSync(String path, {bool recursive = false});

  /// Synchronous counterpart of [rename] (io backend only).
  void renameSync(String source, String destination);

  /// Whether [path] currently resolves to a file (io backend only).
  bool isFileSync(String path);
}

/// An [FsDirectory] that asks [backend] about each descendant by its full path, for a backend where resolving a
/// directory first saves nothing (io, and the test doubles over it). It holds nothing, so [remembering] is itself.
///
/// Every member checks its path is beneath [path] and then makes exactly the call `PathEntity` makes for that path, so
/// a caller reaching the disk through one of these reads and changes it the way it would by path.
class PassThroughFsDirectory implements FsDirectory {
  PassThroughFsDirectory(this.backend, this.path);

  final FsBackend backend;

  @override
  final String path;

  /// [descendant], once [segmentsBelow] has accepted it.
  String _checked(String descendant) {
    segmentsBelow(path, descendant);
    return descendant;
  }

  @override
  PassThroughFsDirectory remembering() => this;

  @override
  Future<bool> exists(String descendant) async => backend.exists(_checked(descendant));

  @override
  Future<bool> isFile(String descendant) async => backend.isFile(_checked(descendant));

  @override
  Future<String> readString(String descendant) async => backend.readString(_checked(descendant));

  @override
  Future<Uint8List> readBytes(String descendant) async => backend.readBytes(_checked(descendant));

  @override
  Future<Uint8List?> readBytesIfPresent(String descendant) async => backend.readBytesIfPresent(_checked(descendant));

  @override
  Future<void> writeString(String descendant, String contents) async {
    return backend.writeString(_checked(descendant), contents);
  }

  @override
  Future<void> writeBytes(String descendant, List<int> bytes, {bool flush = false}) async {
    return backend.writeBytes(_checked(descendant), bytes, flush: flush);
  }

  @override
  Future<List<FsEntry>> list(
    String descendant, {
    bool recursive = false,
    bool followLinks = false,
    bool withMetadata = false,
  }) async {
    return backend.list(
      _checked(descendant),
      recursive: recursive,
      followLinks: followLinks,
      withMetadata: withMetadata,
    );
  }

  @override
  Future<void> delete(String descendant, {bool recursive = false}) async {
    segmentsToRemoveBelow(path, descendant);
    return backend.delete(descendant, recursive: recursive);
  }

  @override
  Future<void> rename(String source, String destination) async {
    return backend.rename(_checked(source), _checked(destination));
  }

  @override
  Future<void> createDir(String descendant, {bool recursive = false}) async {
    return backend.createDir(_checked(descendant), recursive: recursive);
  }

  @override
  Future<void> copyFile(String source, String destination) async {
    return backend.copyFile(_checked(source), _checked(destination));
  }

  @override
  Future<int> length(String descendant) async => backend.length(_checked(descendant));

  @override
  Future<bool> sameFileBytes(String a, String b) async => backend.sameFileBytes(_checked(a), _checked(b));

  @override
  Future<bool> isDirectory(String descendant) async {
    final checked = _checked(descendant);
    return await backend.exists(checked) && !await backend.isFile(checked);
  }
}

/// The process-wide filesystem backend, selected at compile time by the
/// conditional import above (io on desktop/VM, OPFS on web).
FsBackend _fsBackend = createFsBackend();

/// The process-wide filesystem backend used by [PathEntity] and the record
/// store.
FsBackend get fsBackend => _fsBackend;

/// Overrides the process-wide backend, for tests only.
///
/// Lets a suite substitute a fake backend (e.g. one that throws on the sync
/// surface, to reproduce the web/OPFS restriction on the VM) around a block and
/// restore it in `tearDown`. Not for production use: the real backend is fixed
/// at startup by the compile-time conditional import.
@visibleForTesting
set fsBackend(FsBackend backend) => _fsBackend = backend;
