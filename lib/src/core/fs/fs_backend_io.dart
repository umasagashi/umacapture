import 'dart:io';
import 'dart:typed_data';

import 'byte_compare.dart';
import 'fs_backend.dart';

/// Creates the desktop/VM filesystem backend. Referenced by the conditional
/// import in `fs_backend.dart`.
FsBackend createFsBackend() => const IoFsBackend();

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
  Future<void> writeString(String path, String contents) => File(path).writeAsString(contents);

  @override
  Future<void> writeBytes(String path, List<int> bytes) => File(path).writeAsBytes(bytes);

  /// A listed entity plus the kind `FileSystemEntity` already resolved for it.
  ///
  /// A [Link] that was not followed is reported as a non-directory: it has no
  /// children to walk, and the record store contains no links, so the record
  /// paths never observe the distinction.
  FsEntry _listed(FileSystemEntity entity) => (path: entity.path, isDirectory: entity is Directory);

  @override
  Future<List<FsEntry>> list(String path, {bool recursive = false, bool followLinks = false}) {
    return Directory(path).list(recursive: recursive, followLinks: followLinks).map(_listed).toList();
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
  List<FsEntry> listSync(String path, {bool recursive = false, bool followLinks = false}) {
    return Directory(path).listSync(recursive: recursive, followLinks: followLinks).map(_listed).toList();
  }

  @override
  void deleteSync(String path, {bool recursive = false}) => _entity(path).deleteSync(recursive: recursive);

  @override
  void renameSync(String source, String destination) => File(source).renameSync(destination);

  @override
  bool isFileSync(String path) => FileSystemEntity.isFileSync(path);
}
