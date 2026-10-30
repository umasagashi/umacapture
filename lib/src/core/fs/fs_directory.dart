/// The asynchronous path operations both backends answer, a directory resolved once, and the questions and changes a
/// caller then makes of what lies beneath it.
///
/// Kept free of `package:flutter` so that the OPFS implementation (`opfs_directory.dart`) can implement it and still be
/// compiled by `dart test --platform chrome`, the only runner that reaches OPFS.
library;

import 'dart:typed_data';

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
///   on web only**, for the same reason `FsBackend.modified` throws there:
///   `FileSystemDirectoryHandle` exposes no metadata. This is a listing, so the
///   miss is reported as an absent value rather than as an exception — one
///   unreachable child must not fail the whole enumeration.
typedef FsEntry = ({String path, bool isDirectory, int? size, DateTime? modified});

/// The asynchronous operations on a path, given in full as `PathEntity.path` spells it.
///
/// `FsBackend` answers them for any path, and its members carry the contract of each. An [FsDirectory] answers them
/// for the paths beneath it, with the same answers and the same failures `FsBackend` gives for the same full path, so
/// that code written against this interface reads and changes the disk the same way whichever of the two it is handed.
abstract interface class FsPathOperations {
  Future<bool> exists(String path);

  Future<bool> isFile(String path);

  Future<String> readString(String path);

  Future<Uint8List> readBytes(String path);

  Future<Uint8List?> readBytesIfPresent(String path);

  Future<void> writeString(String path, String contents);

  Future<void> writeBytes(String path, List<int> bytes, {bool flush = false});

  Future<List<FsEntry>> list(
    String path, {
    bool recursive = false,
    bool followLinks = false,
    bool withMetadata = false,
  });

  Future<void> delete(String path, {bool recursive = false});

  Future<void> rename(String source, String destination);

  Future<void> createDir(String path, {bool recursive = false});

  Future<void> copyFile(String source, String destination);

  Future<int> length(String path);

  Future<bool> sameFileBytes(String a, String b);
}

/// A directory resolved once, whose descendants are then reached from that resolution instead of from the storage
/// root (`FsBackend.openDirectory`).
///
/// On web every path operation walks OPFS from the origin root one directory handle at a time, so a caller with
/// several questions about one directory — a record's three files, a record's slots in two journals — pays that walk
/// once per question unless it resolves the directory first and asks here. On io a path is one call into the
/// operating system and there is nothing to carry, so the io directory hands each full path to the backend.
///
/// Every method takes the **full path** of a descendant, as `PathEntity.path` spells it, so a caller names files the
/// way it does everywhere else; a path that is not beneath [path] is an [ArgumentError], and so is a [delete] of
/// [path] itself, which no directory can be asked to remove from within.
///
/// Each answer is about the disk at the moment it is asked: a directory that was not there when it was opened, or
/// has been removed since, has no descendants, so a read finds nothing and [isDirectory] says false. A change made
/// through it that needs the directory — a [createDir] with `recursive` beneath it — creates it.
///
/// What is held between two questions is the directory itself and, for one made by [remembering], every directory
/// beneath it that a question or a change has walked to. A caller that hands one of these from one operation to the
/// next, or keeps a remembering one while something else changes the tree beneath it, is the one deciding that no
/// writer can replace what it holds in between: what this directory removes, it forgets, and nothing else tells it.
abstract interface class FsDirectory implements FsPathOperations {
  /// The directory's own path.
  String get path;

  /// Whether [path] is a directory — false for a file and for nothing.
  ///
  /// One lookup per segment below the directory's own path that is not already held, so a name that is not there
  /// costs one failed lookup.
  Future<bool> isDirectory(String path);

  /// This directory, from the same resolution, holding every directory beneath it that a question or a change walks
  /// to until it is dropped, and forgetting the ones it removes. A new one holds nothing beneath it yet.
  ///
  /// For one operation that asks and changes many paths in one tree and holds what keeps other writers out of that
  /// tree while it runs: the record write transaction, under the record's lock. Where resolving saves nothing (io)
  /// the answer is this directory itself.
  FsDirectory remembering();
}

final RegExp _separators = RegExp(r'[/\\]');

/// The segments of [descendant] below [directory], both split on either separator; an [ArgumentError] where
/// [descendant] is not [directory] or beneath it. Every [FsDirectory] checks its argument through this, so a path
/// from the wrong tree is refused the same way on both backends.
List<String> segmentsBelow(String directory, String descendant) {
  List<String> split(String path) => path.split(_separators).where((s) => s.isNotEmpty).toList();
  final own = split(directory);
  final segments = split(descendant);
  final beneath =
      segments.length >= own.length && Iterable<int>.generate(own.length).every((i) => segments[i] == own[i]);
  if (!beneath) {
    throw ArgumentError.value(descendant, 'descendant', 'is not beneath $directory');
  }
  return segments.sublist(own.length);
}

/// [segmentsBelow] for a path an [FsDirectory] is asked to remove, which has to be strictly beneath it.
List<String> segmentsToRemoveBelow(String directory, String descendant) {
  final below = segmentsBelow(directory, descendant);
  if (below.isEmpty) {
    throw ArgumentError.value(descendant, 'descendant', 'is the opened directory itself, which it cannot remove');
  }
  return below;
}
