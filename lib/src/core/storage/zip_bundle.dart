/// Assembling one folder's files into zip bytes, in memory (stage 5d).
///
/// **Pure Dart, for the same reason `zip_export_limit.dart` is**: this is the
/// half of the browser leg a browser can actually execute. `zip_export_web.dart`
/// reaches `PathEntity` and therefore `package:flutter`, which `dart2js` cannot
/// build, so an assembler written in there could be round-tripped by no suite at
/// all. Written here, `dart test --platform chrome` can build a tree on real
/// OPFS, hand its bytes to this function, and read the archive back.
///
/// **In memory, and only here.** The native leg streams through
/// `ZipFileEncoder` and never holds the archive (`zip_export_io.dart`); a
/// browser has no isolate to stream on (`archive_executor_web.dart`), so it
/// assembles the whole thing on the thread that draws the frame and peaks at
/// roughly twice the folder's size. That peak is what `zip_export_limit.dart`
/// bounds, and why the limit is consulted before this function is ever called.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

/// One file to put in the archive: where it sits under the folder, its bytes,
/// and when it was last written.
///
/// Segments rather than a joined path because the separator differs between the
/// hosts that produce them and the zip format takes exactly one (`/`); joining
/// here means a caller cannot supply a name that is right on one platform and
/// wrong in the archive.
///
/// [modified] is **required rather than optional** so that a caller cannot drop
/// a timestamp it holds by simply not mentioning it: the native leg preserves
/// every file's date (`ZipFileEncoder.addFile` reads it from the file's stat),
/// and an archive from the other leg has to carry the same field or the two legs
/// hand the user different files. `null` is for a producer that genuinely has no
/// timestamp to give, and [buildStorageZipBytes] says what that costs.
typedef StorageZipSourceFile = ({List<String> relativeSegments, Uint8List bytes, DateTime? modified});

/// Builds a zip holding [files] under a top-level [rootName] directory.
///
/// The top-level directory is not decoration: it is what `ZipFileEncoder`'s
/// default `includeDirName` produces on the native leg, so an archive from
/// either host expands into a copy of the folder instead of scattering its
/// contents into whatever directory it was opened in. The two legs owe the user
/// the same file.
///
/// [emptyDirectorySegments] carries the folders that hold no files, which
/// nothing else can express: an entry list alone cannot say a directory existed
/// and was empty, and the native encoder does record them. Omitting them would
/// make the browser's archive a *different* tree from the one on screen, in the
/// one respect nobody notices until they restore from it.
///
/// **Each file entry is dated from [StorageZipSourceFile.modified].**
/// `ArchiveFile`'s own default is the moment the entry is constructed, so an
/// assembler that leaves it alone stamps the whole archive with the time of the
/// export and silently discards the dates the folder had. The native leg keeps
/// them (`ZipFileEncoder` reads each file's stat), and "the two legs owe the
/// user the same file" is not satisfied by an archive whose every entry is dated
/// today.
///
/// **The empty-directory entries are the one part that stays undated, and only
/// on the browser leg.** A folder's timestamp is not something a browser can
/// read at all: OPFS's `FileSystemDirectoryHandle` exposes no metadata, which is
/// why `FsBackend.modified` throws for a directory on web and why
/// `DirectoryPath.listWithMetadata` answers `null` there. So this assembler is
/// given no directory date to write, and leaves those entries at the encoder's
/// default rather than inventing one. That is a platform constraint, not a
/// choice: the value does not exist on the host this function runs on.
Uint8List buildStorageZipBytes({
  required String rootName,
  required List<StorageZipSourceFile> files,
  List<List<String>> emptyDirectorySegments = const <List<String>>[],
}) {
  final archive = Archive();
  for (final segments in emptyDirectorySegments) {
    // A trailing separator is how the zip format spells a directory entry, and
    // what `ArchiveFile.directory` writes.
    archive.addFile(ArchiveFile.directory(_entryName(rootName, segments)));
  }
  for (final file in files) {
    final entry = ArchiveFile.bytes(_entryName(rootName, file.relativeSegments), file.bytes);
    final modified = file.modified;
    if (modified != null) {
      // Whole seconds since the epoch, which is the unit `ArchiveFile` holds and
      // the same conversion `ZipFileEncoder` applies on the native leg; the zip
      // format itself then quantises to two seconds.
      entry.lastModTime = modified.millisecondsSinceEpoch ~/ 1000;
    }
    archive.addFile(entry);
  }
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

/// `<rootName>/<segments joined by '/'>`.
String _entryName(String rootName, List<String> segments) => [rootName, ...segments].join('/');

/// What an archive of one folder contains: the files, and the folders that need
/// an entry of their own.
///
/// Both lists are **relative to the folder being bundled**, which is the form
/// [buildStorageZipBytes] takes.
typedef StorageZipLayout = ({List<List<String>> fileSegments, List<List<String>> emptyDirectorySegments});

/// Turns one recursive listing into the layout of the archive it becomes.
///
/// [fileSegments] and [directorySegments] are the *absolute* segments of what the
/// walk found, split by kind; [rootSegmentCount] is how many leading segments the
/// bundled folder itself occupies, so the rest is the path inside the archive.
///
/// **[StorageZipLayout.fileSegments] comes back in the order it was given, one
/// for one**, so a caller that holds the objects it derived the segments from —
/// the web runner holds `FilePath`s it still has to read — pairs them by index
/// rather than re-deriving a path a second time.
///
/// **A directory that has a file anywhere under it gets no entry**, because that
/// file's own entry already creates it. Only the ones nothing lands in need one,
/// and they cannot be inferred from an entry list at all — which is why
/// [buildStorageZipBytes] has to be told.
///
/// **Split out here rather than left in `zip_export_web.dart` because of what
/// that file can be compiled by.** The web runner reaches `FilePath` /
/// `DirectoryPath`, which reach `package:flutter`, which `dart2js` cannot build
/// and which is therefore out of `dart test --platform chrome`'s reach; written
/// there, the relative slicing and the ancestor rule below were executed by no
/// suite at all, and a broken folder hierarchy or a dropped empty folder would
/// only surface in an archive a user had already downloaded. Taking plain
/// segment lists is what makes this checkable from both suites: the segments are
/// data, and only the `is FilePath` test that produces them needs the entity
/// types.
StorageZipLayout planStorageZipLayout({
  required int rootSegmentCount,
  required List<List<String>> fileSegments,
  required List<List<String>> directorySegments,
}) {
  final files = [for (final segments in fileSegments) segments.sublist(rootSegmentCount)];
  final directories = [for (final segments in directorySegments) segments.sublist(rootSegmentCount)];
  directories.removeWhere((candidate) => files.any((file) => _isAncestor(candidate, file)));
  return (fileSegments: files, emptyDirectorySegments: directories);
}

/// Whether [ancestor] is a strict prefix of [descendant] — i.e. the directory
/// contains it.
///
/// Strict: equal paths are not an ancestor relation, so a directory is never
/// suppressed by itself.
bool _isAncestor(List<String> ancestor, List<String> descendant) {
  if (ancestor.length >= descendant.length) {
    return false;
  }
  for (var index = 0; index < ancestor.length; index++) {
    if (ancestor[index] != descendant[index]) {
      return false;
    }
  }
  return true;
}
