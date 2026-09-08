// The browser half of `WebVfs.readHead`: what a `Blob` slice taken off an OPFS
// file handle actually returns.
//
//   .fvm/flutter_sdk/bin/dart test --platform chrome test/fs_ranged_read_web_test.dart
//
// `FsBackend.readHead` promises a bounded read rather than a bounded return
// value, and on web the whole promise rests on three claims about the browser's
// objects, none of which a VM run can establish:
//
// 1. The `File` that `FileSystemFileHandle.getFile()` hands back **is a Blob**,
//    so `slice` exists on it at all. Without that, `WebVfs.readHead` would have
//    to read the file and cut, which is the implementation it was written to
//    replace.
// 2. `slice(0, n)` yields a blob whose `size` is `n` *before* anything is read,
//    and whose awaited `arrayBuffer()` holds exactly the first `n` bytes of the
//    file. The size being right on the un-awaited blob is what shows the slice
//    is a view and not a copy of the file.
// 3. An end offset past the file's own size is clamped rather than rejected --
//    the reason `WebVfs.readHead` may pass `min(maxBytes, file.size)` and treat
//    a bound larger than the file as "the whole file".
//
// WHAT THIS SUITE DOES NOT REACH, and why -- the same limitation
// fs_metadata_web_test.dart and opfs_delete_failure_web_test.dart record. It
// drives the OPFS API directly and does **not** execute `WebVfs` /
// `WebFsBackend` / `FsBackendPreviewSource`. `dart test` cannot compile them:
// `web_vfs.dart` imports `fs_backend.dart`, whose first line is
// `package:flutter/foundation.dart`, and dart2js cannot build
// `package:flutter` without `dart:ui`. So the Dart side of `WebVfs.readHead` --
// the null-handle throw, the non-positive bound, the `math.min` clamp -- is
// verified on the VM through the io backend behind the same interface
// (storage_file_preview_test.dart) and by review; what is verified here is the
// browser behaviour those lines are written against.
//
// CI runs this in the `Browser tests` job in .github/workflows/ci.yml; a file
// not named on that command line is run by nothing.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:typed_data';

// `package:test` resolves transitively through `flutter_test`, which is why the
// Browser tests job needs no dev_dependency for it; the sibling browser suites
// silence the same lint the same way.
// ignore: depend_on_referenced_packages
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

/// A file large enough that a slice of it is unambiguously a slice: the head
/// asked for below is three orders of magnitude smaller.
const _fileBytes = 4 * 1024 * 1024;

Future<web.FileSystemDirectoryHandle> _freshDir(String name) async {
  final root = await web.window.navigator.storage.getDirectory().toDart;
  try {
    await root.removeEntry(name, web.FileSystemRemoveOptions(recursive: true)).toDart;
  } catch (_) {
    // Absent is the expected state; only a leftover from a previous run is not.
  }
  return await root.getDirectoryHandle(name, web.FileSystemGetDirectoryOptions(create: true)).toDart;
}

/// Writes [bytes] bytes whose values cycle 0..255, so a returned range can be
/// checked against the offset it claims to come from rather than only by length.
Future<web.FileSystemFileHandle> _writeRamp(web.FileSystemDirectoryHandle dir, String name, int bytes) async {
  final handle = await dir.getFileHandle(name, web.FileSystemGetFileOptions(create: true)).toDart;
  final writable = await handle.createWritable().toDart;
  await writable.write(Uint8List.fromList(List<int>.generate(bytes, (i) => i & 0xff)).toJS).toDart;
  await writable.close().toDart;
  return handle;
}

Future<Uint8List> _blobBytes(web.Blob blob) async {
  final buffer = await blob.arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}

void main() {
  test('a slice off an OPFS file handle returns exactly the bytes asked for', () async {
    final dir = await _freshDir('fs_ranged_read_web_test_head');
    final handle = await _writeRamp(dir, 'ramp.bin', _fileBytes);
    final file = await handle.getFile().toDart;
    expect(file.size, _fileBytes);
    // Claim 1: the handle's `File` is a `Blob`, which is what makes a ranged
    // read available here at all.
    expect(file.isA<web.Blob>(), isTrue);

    const head = 4096;
    final slice = file.slice(0, head);
    // Claim 2, first half: the size is settled before a byte is fetched.
    expect(slice.size, head, reason: 'a slice must be a view with a known length, not a lazy full read');

    final bytes = await _blobBytes(slice);
    expect(bytes.length, head);
    expect(bytes.toList(), List<int>.generate(head, (i) => i & 0xff));
  });

  test('an end offset past the file is clamped to the file, not rejected', () async {
    // Claim 3: `WebVfs.readHead` clamps with `math.min` for its own reasons, but
    // a bound larger than the file must not become an error even so -- the io
    // side answers it with the whole file, and the two backends have to agree.
    final dir = await _freshDir('fs_ranged_read_web_test_clamp');
    final handle = await _writeRamp(dir, 'short.bin', 10);
    final file = await handle.getFile().toDart;

    final slice = file.slice(0, 1 << 20);
    expect(slice.size, 10);
    expect((await _blobBytes(slice)).toList(), List<int>.generate(10, (i) => i));
  });

  test('a zero-length slice reads nothing and is still a blob', () async {
    // The non-positive branch of `WebVfs.readHead` short-circuits before it gets
    // here, but the browser answering an empty range with an empty blob rather
    // than an error is what makes that short-circuit an optimisation instead of
    // a required guard.
    final dir = await _freshDir('fs_ranged_read_web_test_empty');
    final handle = await _writeRamp(dir, 'ramp.bin', 1024);
    final file = await handle.getFile().toDart;

    final slice = file.slice(0, 0);
    expect(slice.size, 0);
    expect(await _blobBytes(slice), isEmpty);
  });
}
