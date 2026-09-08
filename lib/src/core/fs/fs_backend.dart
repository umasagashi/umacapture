import 'package:flutter/foundation.dart';

import 'fs_backend_io.dart' if (dart.library.js_interop) 'fs_backend_web.dart';

/// One directory entry, carrying the kind the listing already determined and,
/// when the caller asked for it, the metadata the listing could resolve.
///
/// Both backends know each entry's kind while they enumerate it — io from the
/// `FileSystemEntity` subtype, web from `FileSystemHandle.kind` — so returning it
/// costs nothing and saves the caller a second root-to-leaf resolution per entry.
/// That extra resolution is cheap on io and expensive on OPFS, where every probe
/// re-walks the whole handle chain from the storage root.
///
/// [size] and [modified] are `null` unless the listing was made with
/// `withMetadata: true`, and stay `null` even then in the cases named below.
/// They are opt-in because collecting them is **not** free the way the kind is:
/// io has to `stat()` each entry (measured on Windows over a 2,000-file
/// directory: 2.95 ms for the listing alone against 282 ms with a stat per
/// entry, ~96x) and OPFS has to `getFile()` each file handle, one extra promise
/// per entry. Every existing caller here is a tree walk — record loading, the
/// record directory transaction, `sameDirectoryTree` — that wants paths and
/// kinds only, so charging them for metadata they never read would be a
/// regression on both platforms.
///
/// When metadata *was* requested:
///
/// * [size] is the file size in bytes, and is `null` for a directory on **both**
///   backends. A directory's own `stat().size` on io is an inode figure with no
///   relation to its contents, and reporting it would make io answer a question
///   web cannot answer at all with a number that means nothing; a recursive
///   total is a separate aggregation over the tree.
/// * [modified] is the last-modified timestamp. It is `null` for a **directory
///   on web only**, for the same reason [FsBackend.modified] throws there:
///   `FileSystemDirectoryHandle` exposes no metadata. This is a listing, so the
///   miss is reported as an absent value rather than as an exception — one
///   unreachable child must not fail the whole enumeration.
typedef FsEntry = ({String path, bool isDirectory, int? size, DateTime? modified});

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
abstract interface class FsBackend {
  // --- async: primary, both platforms -------------------------------------

  /// Whether a file or directory exists at [path].
  Future<bool> exists(String path);

  /// Reads [path] as a UTF-8 string.
  Future<String> readString(String path);

  /// Reads [path] as raw bytes.
  Future<Uint8List> readBytes(String path);

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
  Future<void> writeString(String path, String contents);

  /// Writes [bytes] to [path], replacing any existing file.
  ///
  /// Same parent-directory contract as [writeString].
  Future<void> writeBytes(String path, List<int> bytes);

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
  Future<List<FsEntry>> list(
    String path, {
    bool recursive = false,
    bool followLinks = false,
    bool withMetadata = false,
  });

  /// Deletes the file or directory at [path].
  Future<void> delete(String path, {bool recursive = false});

  /// Renames/moves [source] to [destination] (same volume on io).
  ///
  /// **Files only** on both backends: io renames through `File`, and OPFS has no
  /// directory rename at all. Moving a directory goes through
  /// [DirectoryPath.moveSyncSafe] / [DirectoryPath.moveAsyncSafe], or
  /// `RecordDirectoryTransaction` when the move must be recoverable.
  Future<void> rename(String source, String destination);

  /// Creates the directory at [path].
  ///
  /// With [recursive] false the parent must already exist, and a missing parent
  /// is an error; with [recursive] true every missing ancestor is created.
  /// Creating a directory that already exists is a no-op on both backends.
  Future<void> createDir(String path, {bool recursive = false});

  /// Copies the file [source] to [destination].
  Future<void> copyFile(String source, String destination);

  /// The size of the file at [path], in bytes.
  ///
  /// Throws when [path] does not resolve to a file. Tree comparison uses this to
  /// reject a differing pair without reading either file's contents.
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
  Future<bool> sameFileBytes(String a, String b);

  /// Whether [path] currently resolves to a file (as opposed to a directory or
  /// nothing).
  ///
  /// The async counterpart of [isFileSync], usable on web: tree walks that must
  /// branch on entry kind (e.g. [DirectoryPath.copyTreeInto]) go through this so
  /// they never touch the sync surface the web backend rejects.
  Future<bool> isFile(String path);

  // --- sync: io backend only (throws on web) -------------------------------

  /// Synchronous counterpart of [exists] (io backend only).
  bool existsSync(String path);

  /// Synchronous counterpart of [readString] (io backend only).
  String readStringSync(String path);

  /// Synchronous counterpart of [readBytes] (io backend only).
  Uint8List readBytesSync(String path);

  /// Synchronous counterpart of [writeString] (io backend only).
  void writeStringSync(String path, String contents);

  /// Synchronous counterpart of [list] (io backend only).
  List<FsEntry> listSync(String path, {bool recursive = false, bool followLinks = false, bool withMetadata = false});

  /// Synchronous counterpart of [delete] (io backend only).
  void deleteSync(String path, {bool recursive = false});

  /// Synchronous counterpart of [rename] (io backend only).
  void renameSync(String source, String destination);

  /// Whether [path] currently resolves to a file (io backend only).
  bool isFileSync(String path);
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
