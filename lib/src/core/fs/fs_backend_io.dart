import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'byte_compare.dart';
import 'fs_backend.dart';

/// Creates the desktop/VM filesystem backend. Referenced by the conditional
/// import in `fs_backend.dart`.
FsBackend createFsBackend() => const IoFsBackend();

/// Reduces a raw [FileStat] to the `(size, modified)` pair [FsEntry] carries,
/// treating a `notFound` stat as "no metadata" rather than as real values.
///
/// `FileStat.stat`/`statSync` never throw for a missing path: they answer with
/// a `notFound` stat whose `modified` is the Unix epoch and whose `size` is
/// `-1` (verified directly: `FileStat.statSync('<missing path>')` on the
/// current Dart SDK returns exactly that pair). A directory listing walks the
/// tree and then stats each entry as a second, unsynchronized step, so an
/// entry that existed when the walk saw it can be gone by the time it is
/// stat()ed -- e.g. a `temp/` directory a capture is actively writing into.
/// Passing the sentinel through as if it were a real reading would show
/// "-1 B" / "1970-01-01" in the UI; "the size is unknown" and "the size is -1
/// bytes" are different claims, and only the first one is true here.
///
/// [IoFsBackend.modified] makes the same `notFound` check but throws, because
/// it answers for exactly one path the caller named. A listing is different:
/// one entry vanishing must not fail the whole enumeration (see [FsEntry]), so
/// here the outcome is a pair of `null`s rather than an exception.
@visibleForTesting
({int? size, DateTime? modified}) metadataFromStat(FileStat stat) {
  if (stat.type == FileSystemEntityType.notFound) {
    return (size: null, modified: null);
  }
  return (size: stat.size, modified: stat.modified);
}

/// [dart:io]-backed filesystem, mapping each leaf operation onto the native
/// `File`/`Directory` API. This preserves the exact desktop behavior that
/// [PathEntity] had before the backend was extracted.
class IoFsBackend implements FsBackend {
  const IoFsBackend();

  /// Resolves [path] to a typed entity the same way the old `toEntity()` did: a
  /// [File] when the path currently points at a file, a [Directory] otherwise
  /// (including when nothing exists yet).
  FileSystemEntity _entity(String path) {
    return FileSystemEntity.isFileSync(path) ? File(path) : Directory(path);
  }

  @override
  Future<bool> exists(String path) => _entity(path).exists();

  @override
  Future<String> readString(String path) => File(path).readAsString();

  @override
  Future<Uint8List> readBytes(String path) => File(path).readAsBytes();

  @override
  Future<Uint8List> readHead(String path, int maxBytes) async {
    if (maxBytes <= 0) {
      return Uint8List(0);
    }
    // `openRead(0, maxBytes)` seeks and stops at the end offset, so the bytes
    // past the bound are never handed to this process; the accumulator is the
    // only allocation and it can never exceed `maxBytes`.
    final builder = BytesBuilder(copy: false);
    await for (final chunk in File(path).openRead(0, maxBytes)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<void> writeString(String path, String contents) => File(path).writeAsString(contents);

  @override
  Future<void> writeBytes(String path, List<int> bytes) => File(path).writeAsBytes(bytes);

  /// A listed entity plus the kind `FileSystemEntity` already resolved for it.
  ///
  /// A [Link] that was not followed is reported as a non-directory: it has no
  /// children to walk, and the record store contains no links, so the record
  /// paths never observe the distinction.
  FsEntry _listed(FileSystemEntity entity) =>
      (path: entity.path, isDirectory: entity is Directory, size: null, modified: null);

  /// [_listed] plus the metadata [stat] resolved for the same entity.
  ///
  /// `size` is suppressed for a directory: `FileStat.size` on a directory is an
  /// inode figure unrelated to its contents, and [FsEntry] contracts that a
  /// directory's size is absent on both backends. The `notFound` case (entity
  /// deleted between enumeration and `stat()`) is handled by [metadataFromStat]
  /// before that suppression is applied, so a vanished entry reports `null` for
  /// both fields rather than the `-1`/epoch sentinel `FileStat` hands back.
  FsEntry _listedWithMetadata(FileSystemEntity entity, FileStat stat) {
    final isDirectory = entity is Directory;
    final metadata = metadataFromStat(stat);
    return (
      path: entity.path,
      isDirectory: isDirectory,
      size: isDirectory ? null : metadata.size,
      modified: metadata.modified,
    );
  }

  @override
  Future<List<FsEntry>> list(
    String path, {
    bool recursive = false,
    bool followLinks = false,
    bool withMetadata = false,
  }) {
    final entities = Directory(path).list(recursive: recursive, followLinks: followLinks);
    if (!withMetadata) {
      return entities.map(_listed).toList();
    }
    return entities.asyncMap((e) async => _listedWithMetadata(e, await e.stat())).toList();
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) => _entity(path).delete(recursive: recursive);

  @override
  Future<void> rename(String source, String destination) => File(source).rename(destination);

  @override
  Future<void> createDir(String path, {bool recursive = false}) => Directory(path).create(recursive: recursive);

  @override
  Future<void> copyFile(String source, String destination) => File(source).copy(destination);

  @override
  Future<int> length(String path) => File(path).length();

  @override
  Future<DateTime> modified(String path) async {
    final stat = await FileStat.stat(path);
    // `FileStat.stat` reports a missing path as a `notFound` stat whose
    // `modified` is the epoch rather than by throwing, so the check is what turns
    // "there is nothing here" into an error instead of a 1970 timestamp.
    if (stat.type == FileSystemEntityType.notFound) {
      throw FileSystemException('No such file or directory', path);
    }
    return stat.modified;
  }

  @override
  Future<bool> sameFileBytes(String a, String b) async {
    final left = await File(a).open();
    try {
      final right = await File(b).open();
      try {
        if (await left.length() != await right.length()) return false;
        // One buffer per side, reused for every chunk: the comparison never
        // materialises a whole file, however large the record images are.
        final leftChunk = Uint8List(fileCompareChunkSize);
        final rightChunk = Uint8List(fileCompareChunkSize);
        while (true) {
          final read = await left.readInto(leftChunk);
          if (read == 0) return true;
          // `readInto` may return a short read, so keep pulling until the right
          // side has as many bytes as the left chunk holds.
          var filled = 0;
          while (filled < read) {
            final got = await right.readInto(rightChunk, filled, read);
            if (got == 0) return false;
            filled += got;
          }
          if (!sameByteRange(leftChunk, rightChunk, read)) return false;
        }
      } finally {
        await right.close();
      }
    } finally {
      await left.close();
    }
  }

  @override
  Future<bool> isFile(String path) => FileSystemEntity.isFile(path);

  @override
  bool existsSync(String path) => _entity(path).existsSync();

  @override
  String readStringSync(String path) => File(path).readAsStringSync();

  @override
  Uint8List readBytesSync(String path) => File(path).readAsBytesSync();

  @override
  void writeStringSync(String path, String contents) => File(path).writeAsStringSync(contents);

  @override
  List<FsEntry> listSync(String path, {bool recursive = false, bool followLinks = false, bool withMetadata = false}) {
    final entities = Directory(path).listSync(recursive: recursive, followLinks: followLinks);
    if (!withMetadata) {
      return entities.map(_listed).toList();
    }
    return entities.map((e) => _listedWithMetadata(e, e.statSync())).toList();
  }

  @override
  void deleteSync(String path, {bool recursive = false}) => _entity(path).deleteSync(recursive: recursive);

  @override
  void renameSync(String source, String destination) => File(source).renameSync(destination);

  @override
  bool isFileSync(String path) => FileSystemEntity.isFileSync(path);
}
