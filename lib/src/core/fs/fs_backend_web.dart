import 'dart:typed_data';

import 'fs_backend.dart';
import 'web_vfs.dart';

/// Creates the web filesystem backend. Referenced by the conditional import in
/// `fs_backend.dart`.
FsBackend createFsBackend() => WebFsBackend();

/// OPFS-backed filesystem for the browser.
///
/// The async surface delegates to [WebVfs]; the sync surface throws
/// [UnsupportedError] because OPFS offers no synchronous main-thread API. No
/// shared (runs-on-both-platforms) code path reaches the sync methods, so the
/// throw is unreachable in practice — it exists to make an accidental sync call
/// on web fail loudly rather than silently.
class WebFsBackend implements FsBackend {
  WebFsBackend();

  final WebVfs _vfs = const WebVfs();

  @override
  Future<bool> exists(String path) => _vfs.exists(path);

  @override
  Future<String> readString(String path) => _vfs.readString(path);

  @override
  Future<Uint8List> readBytes(String path) => _vfs.readBytes(path);

  @override
  Future<void> writeString(String path, String contents) => _vfs.writeString(path, contents);

  @override
  Future<void> writeBytes(String path, List<int> bytes) => _vfs.writeBytes(path, bytes);

  @override
  Future<List<FsEntry>> list(String path, {bool recursive = false, bool followLinks = false}) {
    return _vfs.list(path, recursive: recursive);
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) => _vfs.delete(path, recursive: recursive);

  @override
  Future<void> rename(String source, String destination) => _vfs.rename(source, destination);

  @override
  Future<void> createDir(String path, {bool recursive = false}) => _vfs.createDir(path, recursive: recursive);

  @override
  Future<void> copyFile(String source, String destination) => _vfs.copyFile(source, destination);

  @override
  Future<int> length(String path) => _vfs.length(path);

  @override
  Future<bool> sameFileBytes(String a, String b) => _vfs.sameFileBytes(a, b);

  @override
  Future<bool> isFile(String path) => _vfs.isFile(path);

  @override
  bool existsSync(String path) => throw _sync('existsSync');

  @override
  String readStringSync(String path) => throw _sync('readStringSync');

  @override
  Uint8List readBytesSync(String path) => throw _sync('readBytesSync');

  @override
  void writeStringSync(String path, String contents) => throw _sync('writeStringSync');

  @override
  List<FsEntry> listSync(String path, {bool recursive = false, bool followLinks = false}) => throw _sync('listSync');

  @override
  void deleteSync(String path, {bool recursive = false}) => throw _sync('deleteSync');

  @override
  void renameSync(String source, String destination) => throw _sync('renameSync');

  @override
  bool isFileSync(String path) => throw _sync('isFileSync');

  UnsupportedError _sync(String method) {
    return UnsupportedError('FsBackend.$method is not available on web (OPFS has no synchronous main-thread API).');
  }
}
