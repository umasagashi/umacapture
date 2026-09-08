/// The `FsBackend` implementation of [PreviewByteSource].
///
/// Separate from `file_preview.dart` so the decision layer stays pure Dart:
/// `fs_backend.dart` imports `package:flutter/foundation.dart`, and a decision
/// layer that imports Flutter is one no browser test can reach.
library;

import 'dart:typed_data';

import '/src/core/fs/fs_backend.dart';
import '/src/core/storage/file_preview.dart';

/// Reads one file's size and head through the process-wide [fsBackend].
class FsBackendPreviewSource implements PreviewByteSource {
  const FsBackendPreviewSource(this.path);

  final String path;

  /// Neither backend reads contents to answer this: io calls `File.length()`,
  /// web takes the `size` of the `File` that `getFile()` returns, which
  /// `web_vfs.dart` documents as metadata that "never pulls the contents into
  /// memory".
  @override
  Future<int> length() => fsBackend.length(path);

  /// **The bound is applied by the backend read, not after it.**
  ///
  /// `FsBackend.readHead` is a ranged read on both platforms -- `File.openRead`
  /// on io, `Blob.slice` on OPFS -- so a file past the bound is never
  /// materialised. Trimming after an unbounded `readBytes` would return the
  /// same value and defeat the whole purpose of the cap: the reason
  /// [textPreviewByteLimit] exists is that an unbounded read takes the web tab
  /// with it, and a read-then-trim implementation performs exactly the read it
  /// was introduced to prevent.
  @override
  Future<Uint8List> readHead(int maxBytes) => fsBackend.readHead(path, maxBytes);
}
