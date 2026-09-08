// The browser half of fs_metadata_test.dart: what OPFS itself can tell a
// listing about an entry, and what it cannot.
//
//   .fvm/flutter_sdk/bin/dart test --platform chrome test/fs_metadata_web_test.dart
//
// Three facts the web implementation is built on, none of which a VM run can
// establish:
//
// 1. A `FileSystemFileHandle` yields a `File` whose `lastModified` is a real
//    clock reading for the write that just happened, and whose `size` is the
//    byte count -- so `WebVfs.modified` and a metadata-carrying `WebVfs.list`
//    are possible at all, and cost one `getFile()` on a handle the walk already
//    holds rather than a fresh root-to-leaf resolution.
// 2. A `FileSystemDirectoryHandle` carries **no metadata member of any kind**.
//    This is the stated reason `FsBackend.modified` throws `UnsupportedError`
//    for a directory on web and the reason a directory entry in a listing has
//    no timestamp there. It is a claim about the browser's object, so it is
//    checked against the browser's object instead of being asserted in a
//    comment.
// 3. The async-iterator walk (`values()`) hands out handles that are already
//    typed by `kind`, and the metadata for each child is reachable from the
//    handle in hand -- which is what makes the size in a listing free of a
//    second walk.
//
// WHAT THIS SUITE DOES NOT REACH, and why. It drives the OPFS API directly and
// does **not** execute `WebVfs` / `WebFsBackend` / `DirectoryPath`. That is not
// a preference: `dart test` cannot compile them. `web_vfs.dart` imports
// `fs_backend.dart`, whose first line is `package:flutter/foundation.dart`, and
// `storage_persistence_web.dart`, which imports `app_logger.dart` (riverpod +
// sentry_flutter); dart2js cannot build `package:flutter` without `dart:ui`.
// The sibling suite opfs_delete_failure_web_test.dart records the same
// limitation for the same files. So the *Dart* side of the web metadata path --
// `_walk`'s null-for-directory branch, `modified`'s directory throw -- is
// verified on the VM through `WebLikeFsBackend` (fs_metadata_test.dart) and by
// review; what is verified here is the browser behaviour those branches are
// written against.
//
// CI runs this in the `Browser tests` job in .github/workflows/ci.yml; a file
// not named on that command line is run by nothing.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

// `package:test` resolves transitively through `flutter_test`, which is why the
// Browser tests job needs no dev_dependency for it; the sibling browser suites
// silence the same lint the same way.
// ignore: depend_on_referenced_packages
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

/// Binds the async-iterator method `package:web` omits from
/// `FileSystemDirectoryHandle`, the same way `web_vfs.dart` does.
extension type _DirIterable(JSObject _handle) implements JSObject {
  external _AsyncIterator values();
}

extension type _AsyncIterator._(JSObject _) implements JSObject {
  external JSPromise<_IterResult> next();
}

extension type _IterResult._(JSObject _) implements JSObject {
  external JSBoolean get done;
  external JSAny? get value;
}

/// Widest gap accepted between a write and the timestamp read back for it, for
/// the same reason as in fs_metadata_test.dart: what is being excluded is the
/// epoch, not a second of jitter.
const _clockSlack = Duration(seconds: 30);

Future<web.FileSystemDirectoryHandle> _freshDir(String name) async {
  final root = await web.window.navigator.storage.getDirectory().toDart;
  try {
    await root.removeEntry(name, web.FileSystemRemoveOptions(recursive: true)).toDart;
  } catch (_) {
    // Absent is the expected state; only a leftover from a previous run is not.
  }
  return await root.getDirectoryHandle(name, web.FileSystemGetDirectoryOptions(create: true)).toDart;
}

Future<web.FileSystemFileHandle> _write(web.FileSystemDirectoryHandle dir, String name, int bytes) async {
  final handle = await dir.getFileHandle(name, web.FileSystemGetFileOptions(create: true)).toDart;
  final writable = await handle.createWritable().toDart;
  await writable.write(Uint8List.fromList(List<int>.filled(bytes, 0x41)).toJS).toDart;
  await writable.close().toDart;
  return handle;
}

void main() {
  test('a file handle reports the size and the time of the write just made', () async {
    final dir = await _freshDir('fs_metadata_web_test_file');
    final before = DateTime.now();
    final handle = await _write(dir, 'fresh.bin', 4096);
    final file = await handle.getFile().toDart;
    final after = DateTime.now();

    expect(file.size, 4096);

    final stamp = DateTime.fromMillisecondsSinceEpoch(file.lastModified);
    expect(
      stamp.isAfter(before.subtract(_clockSlack)) && stamp.isBefore(after.add(_clockSlack)),
      isTrue,
      reason: 'expected a timestamp near $before..$after, got $stamp',
    );
  });

  test('a directory handle exposes no metadata member at all', () async {
    final dir = await _freshDir('fs_metadata_web_test_dir');
    final child = await dir.getDirectoryHandle('branch', web.FileSystemGetDirectoryOptions(create: true)).toDart;
    final asObject = child as JSObject;

    // Every spelling a caller might reach for. `has` walks the prototype chain,
    // so this covers the interface as well as own properties. If any of these
    // ever becomes true, the `UnsupportedError` in `WebVfs.modified` has an
    // answer to give instead and should stop throwing.
    for (final member in ['lastModified', 'size', 'getFile', 'stat', 'getMetadata', 'lastModifiedDate']) {
      expect(asObject.has(member), isFalse, reason: 'FileSystemDirectoryHandle unexpectedly has `$member`');
    }
    // `queryPermission` was on that list until this suite reported it present:
    // Chromium ships the File System Access permission methods on every
    // `FileSystemHandle`, directories included. It answers "may I read this",
    // not "when was it written", so it does not weaken the finding -- but it is
    // the reason the list names metadata members specifically rather than
    // asserting the handle is bare. It is not asserted either way here, being a
    // File System Access extra that need not exist in every engine.

    // The members it *does* have are the ones `web_vfs.dart` walks with, so the
    // absence above is a gap in the interface and not a mistyped handle.
    expect(asObject.has('kind'), isTrue);
    expect(asObject.has('values'), isTrue);
    expect(child.kind, 'directory');
  });

  test('the walk can read each file entry metadata off the handle it already holds', () async {
    final dir = await _freshDir('fs_metadata_web_test_walk');
    const sizes = {'a.bin': 1, 'b.bin': 2048, 'c.bin': 65537};
    for (final entry in sizes.entries) {
      await _write(dir, entry.key, entry.value);
    }
    await dir.getDirectoryHandle('nested', web.FileSystemGetDirectoryOptions(create: true)).toDart;

    // The same loop shape as `WebVfs._walk`, with no path re-resolution: the
    // metadata comes from the handle the iterator produced.
    final seenSizes = <String, int>{};
    final directories = <String>[];
    final iterator = _DirIterable(dir).values();
    while (true) {
      final step = await iterator.next().toDart;
      if (step.done.toDart) break;
      final value = step.value;
      if (value == null) break;
      final handle = value as web.FileSystemHandle;
      if (handle.kind == 'directory') {
        directories.add(handle.name);
        continue;
      }
      final file = await (handle as web.FileSystemFileHandle).getFile().toDart;
      seenSizes[handle.name] = file.size;
      expect(file.lastModified, greaterThan(0), reason: 'a file listed with no usable timestamp');
    }

    expect(seenSizes, sizes);
    expect(directories, ['nested']);
  });
}
