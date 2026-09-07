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

  /// How many times [length] has been called through this backend.
  ///
  /// Counted because "does not call it" is a real requirement and not a style
  /// preference: on OPFS every `length()` re-walks the handle chain from the
  /// storage root, so a directory aggregation that probes per entry is O(N·d)
  /// where the listing already carried the sizes. A test can assert the absence
  /// of the call; it cannot assert the absence of the cost.
  int lengthCalls = 0;

  /// How many times [list] has been called through this backend, for the other
  /// half of the same claim: one enumeration, not one per entry.
  int listCalls = 0;

  /// How many times [readBytes] has been called through this backend.
  ///
  /// Counted for the preview decision, where "a file classified as binary
  /// has none of its content read" is a requirement rather than an
  /// optimisation: `.onnx` module sets and the font cache run to megabytes, and
  /// on web the read is a copy into the wasm heap that no widget will ever use.
  /// The absence of the call is the only observable form of that requirement --
  /// the returned value is identical whether or not the bytes were fetched and
  /// thrown away.
  int readBytesCalls = 0;

  /// How many times [readString] has been called through this backend, for the
  /// same claim by its other route. `WebVfs.readString` is
  /// `utf8.decode(await readBytes(path))`, so a preview that reaches it on
  /// binary content both reads the file and throws.
  int readStringCalls = 0;

  /// How many times [readHead] has been called through this backend, and the
  /// bound each call carried.
  ///
  /// The preview adapter has to reach the file through *this* method rather
  /// than [readBytes]: the two return the same bytes for a short file, so the
  /// choice of primitive is observable only as which one was called.
  final List<int> readHeadBounds = [];

  /// Zeroes the counters, so a test can exclude its own fixture setup.
  void resetCallCounts() {
    lengthCalls = 0;
    listCalls = 0;
    readBytesCalls = 0;
    readStringCalls = 0;
    readHeadBounds.clear();
  }

  @override
  Future<bool> exists(String path) => inner.exists(path);

  @override
  Future<String> readString(String path) {
    readStringCalls++;
    return inner.readString(path);
  }

  @override
  Future<Uint8List> readBytes(String path) {
    readBytesCalls++;
    return inner.readBytes(path);
  }

  @override
  Future<Uint8List> readHead(String path, int maxBytes) {
    readHeadBounds.add(maxBytes);
    return inner.readHead(path, maxBytes);
  }

  @override
  Future<void> writeString(String path, String contents) => inner.writeString(path, contents);

  @override
  Future<void> writeBytes(String path, List<int> bytes) => inner.writeBytes(path, bytes);

  @override
  Future<List<FsEntry>> list(
    String path, {
    bool recursive = false,
    bool followLinks = false,
    bool withMetadata = false,
  }) async {
    listCalls++;
    final entries = await inner.list(path, recursive: recursive, followLinks: followLinks, withMetadata: withMetadata);
    // The one place the metadata surface is *not* left at io semantics. A
    // directory has no timestamp on web at all (`FileSystemDirectoryHandle`
    // exposes no metadata), so io's answer is one web can never produce, and a
    // caller that reads it here would compile and pass on the VM and find `null`
    // in the browser. Sizes need no such treatment: both backends already agree
    // that a directory has none.
    return entries
        .map((e) => e.isDirectory ? (path: e.path, isDirectory: true, size: null, modified: null) : e)
        .toList();
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
  Future<int> length(String path) {
    lengthCalls++;
    return inner.length(path);
  }

  @override
  Future<bool> sameFileBytes(String a, String b) => inner.sameFileBytes(a, b);

  @override
  Future<bool> isFile(String path) => inner.isFile(path);

  /// The web backend's *second* prohibition, modelled for the same reason as the
  /// sync surface: a directory has no last-modified time on OPFS, so asking for
  /// one throws there. Forwarding to io would answer a question the browser
  /// cannot, and shared code written against that answer would only fail once it
  /// reached a real browser. A missing path still falls through to io, whose
  /// throw is the behaviour both backends agree on.
  @override
  Future<DateTime> modified(String path) async {
    if (!await inner.isFile(path) && await inner.exists(path)) {
      throw UnsupportedError(
        'FsBackend.modified is not available for a directory on web '
        '(FileSystemDirectoryHandle exposes no metadata): $path',
      );
    }
    return inner.modified(path);
  }

  @override
  bool existsSync(String path) => throw _sync('existsSync');

  @override
  String readStringSync(String path) => throw _sync('readStringSync');

  @override
  Uint8List readBytesSync(String path) => throw _sync('readBytesSync');

  @override
  void writeStringSync(String path, String contents) => throw _sync('writeStringSync');

  @override
  List<FsEntry> listSync(String path, {bool recursive = false, bool followLinks = false, bool withMetadata = false}) =>
      throw _sync('listSync');

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
