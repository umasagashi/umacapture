/// The OPFS handle walk `WebVfs` is built on, and the directory a caller resolves once and then asks from
/// ([OpfsDirectory]).
///
/// Kept free of `package:flutter` — `web_vfs.dart` is not, through `requestPersistOnce` and the logger — so that
/// `dart test --platform chrome` can compile it: the walk and the resolved directory are reachable from a browser
/// suite only here.
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'fs_directory.dart';

/// Path separators accepted by the VFS. Hoisted because [splitVfsPath] runs at the head of every single filesystem
/// operation.
final RegExp _pathSeparator = RegExp(r'[/\\]');

/// The segments of the VFS path [path]; the OPFS root is the path with none.
List<String> splitVfsPath(String path) => path.split(_pathSeparator).where((s) => s.isNotEmpty).toList();

/// Walks [segments] down from [start], returning the directory handle, or `null` when a lookup ([create] false)
/// finds a segment missing or naming a file. With [create] true every failure is rethrown; `WebVfs._dir` states why
/// the two modes fail differently.
Future<web.FileSystemDirectoryHandle?> descendOpfs(
  web.FileSystemDirectoryHandle start,
  List<String> segments, {
  required bool create,
}) async {
  var handle = start;
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

/// The whole contents of the file behind [handle].
Future<Uint8List> readOpfsFile(web.FileSystemFileHandle handle) async {
  final file = await handle.getFile().toDart;
  final buffer = await file.arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}

/// A directory resolved from the OPFS root once; see [FsDirectory].
///
/// Holds the directory's handle, and walks only the segments below it for each question, so a record's three files
/// cost one walk from the root between them rather than one each, and a name that is not there costs one failed
/// lookup.
class OpfsDirectory implements FsDirectory {
  OpfsDirectory._(this.path, this._handle);

  /// Resolves [path] from [root].
  static Future<OpfsDirectory> open(web.FileSystemDirectoryHandle root, String path) async {
    return OpfsDirectory._(path, await descendOpfs(root, splitVfsPath(path), create: false));
  }

  @override
  final String path;

  /// The directory, or null where none was at [path] when it was opened.
  final web.FileSystemDirectoryHandle? _handle;

  List<String> _below(String descendant) => segmentsBelow(path, descendant);

  /// The directory [below] this one, or null where there is none.
  Future<web.FileSystemDirectoryHandle?> _directoryAt(List<String> below) async {
    final handle = _handle;
    return handle == null ? null : descendOpfs(handle, below, create: false);
  }

  @override
  Future<Uint8List?> readBytesIfPresent(String descendant) async {
    final below = _below(descendant);
    if (below.isEmpty) {
      return null; // The directory itself, which is no file.
    }
    final parent = await _directoryAt(below.sublist(0, below.length - 1));
    if (parent == null) {
      return null;
    }
    final web.FileSystemFileHandle file;
    try {
      file = await parent.getFileHandle(below.last).toDart;
    } catch (_) {
      return null;
    }
    return readOpfsFile(file);
  }

  @override
  Future<Uint8List> readBytes(String descendant) async {
    return await readBytesIfPresent(descendant) ?? (throw FileSystemException('No such file or directory', descendant));
  }

  @override
  Future<String> readString(String descendant) async => utf8.decode(await readBytes(descendant));

  @override
  Future<bool> isDirectory(String descendant) async {
    final below = _below(descendant);
    if (below.isEmpty) {
      return _handle != null;
    }
    final parent = await _directoryAt(below.sublist(0, below.length - 1));
    if (parent == null) {
      return false;
    }
    try {
      await parent.getDirectoryHandle(below.last).toDart;
      return true;
    } catch (_) {
      return false;
    }
  }
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
