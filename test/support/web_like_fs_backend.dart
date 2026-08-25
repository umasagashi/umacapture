// A test double that reproduces the web (OPFS) FsBackend restriction on the VM:
// every synchronous method throws `UnsupportedError`, while the async surface is
// delegated to the real io backend so files actually land on disk.
//
// The desktop unit tests run on the io backend, whose sync surface works, so a
// bug that only manifests when a shared code path touches the sync API on web
// (e.g. `DirectoryPath.copyTreeInto` branching on `isFileSync`) slips through.
// Installing this backend via the `fsBackend` test setter makes such a path fail
// on the VM exactly as it would on web, without a browser host.
//
// WHAT THIS DOES NOT MODEL. The prohibition is the whole of it. Every async
// method below is `=> inner.<same>(...)`, so a suite running on this backend is
// still observing *io* semantics for everything the async surface decides: which
// exception type a failure throws, what `list` answers for a missing path (the
// real `WebVfs` is unverified on exactly that point), whether `rename` is atomic
// or even supported, how a partial write is left, and what a quota refusal looks
// like. A suite passing here therefore proves "no shared code path reaches the
// sync API", not "this behaves the same on web" — a change that turns on OPFS's
// async behaviour still needs a browser run.
import 'dart:typed_data';

import 'package:umacapture/src/core/fs/fs_backend.dart';

/// Wraps [inner] (an io backend), forwarding the async surface and throwing on
/// every sync method, mirroring `WebFsBackend`.
class WebLikeFsBackend implements FsBackend {
  WebLikeFsBackend(this.inner);

  final FsBackend inner;

  @override
  Future<bool> exists(String path) => inner.exists(path);

  @override
  Future<String> readString(String path) => inner.readString(path);

  @override
  Future<Uint8List> readBytes(String path) => inner.readBytes(path);

  @override
  Future<void> writeString(String path, String contents) => inner.writeString(path, contents);

  @override
  Future<void> writeBytes(String path, List<int> bytes) => inner.writeBytes(path, bytes);

  @override
  Future<List<FsEntry>> list(String path, {bool recursive = false, bool followLinks = false}) {
    return inner.list(path, recursive: recursive, followLinks: followLinks);
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) => inner.delete(path, recursive: recursive);

  @override
  Future<void> rename(String source, String destination) => inner.rename(source, destination);

  @override
  Future<void> createDir(String path, {bool recursive = false}) => inner.createDir(path, recursive: recursive);

  @override
  Future<void> copyFile(String source, String destination) => inner.copyFile(source, destination);

  @override
  Future<int> length(String path) => inner.length(path);

  @override
  Future<bool> sameFileBytes(String a, String b) => inner.sameFileBytes(a, b);

  @override
  Future<bool> isFile(String path) => inner.isFile(path);

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
    return UnsupportedError('FsBackend.$method is unavailable on this (web-like) backend.');
  }
}
