// The browser half of stage 5d: a folder that really is on OPFS, bundled by the
// production assembler and read back.
//
//   .fvm/flutter_sdk/bin/dart test --platform chrome test/storage_zip_export_web_test.dart
//
// WHY THIS EXISTS AS A BROWSER SUITE. The browser leg's whole reason for being
// bounded is that the archive is built in the view's own memory from bytes the
// tab read out of OPFS. The VM suite (storage_zip_web_export_test.dart) runs the
// production preflight and runner, but over `dart:io` files through
// `WebLikeFsBackend`; it cannot say that bytes pulled out of an OPFS handle
// survive `ZipEncoder` in `dart2js`, where `Uint8List` is a JS typed array and
// the encoder's arithmetic is JS numbers. That is a claim about the browser, so
// it is checked in one.
//
// WHAT IS RUN HERE IS PRODUCTION CODE: `buildStorageZipBytes` and
// `decideStorageZipLimit`, imported from `lib/`. They are pure Dart precisely so
// that this suite can reach them -- `zip_export_web.dart` itself imports
// `PathEntity` and therefore `package:flutter`, which `dart2js` cannot build.
//
// WHAT THIS SUITE DOES NOT REACH, and why:
//
//  * `platformStorageZipPreflight` / `platformStorageZipRunner`, and with them
//    `WebVfs`'s own walk and `aggregateDirectoryTotals` -- not a preference:
//    `dart test` cannot compile them (`package:flutter` needs `dart:ui`). The
//    walk here is written against the same OPFS API `web_vfs.dart` uses, so what
//    is verified is the browser behaviour that code is written against. The
//    sibling suites fs_metadata_web_test.dart and opfs_delete_failure_web_test.dart
//    record the same limitation for the same reason.
//  * `FilePicker.saveFile`'s anchor click, which needs a user gesture and a real
//    download directory.
//  * The 256 MiB limit met by an actual folder. Writing that much into OPFS on
//    every CI run would trade minutes for a boundary the pure decision already
//    states exactly.
//
// CI runs this in the `Browser tests` job in .github/workflows/ci.yml; a file
// not named on that command line is run by nothing.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:archive/archive.dart';
// `package:test` resolves transitively through `flutter_test`, which is why the
// Browser tests job needs no dev_dependency for it; the sibling browser suites
// silence the same lint the same way.
// ignore: depend_on_referenced_packages
import 'package:test/test.dart';
import 'package:umacapture/src/core/storage/zip_bundle.dart';
import 'package:umacapture/src/core/storage/zip_export_limit.dart';
import 'package:web/web.dart' as web;

import 'support/zip_layout_cases.dart';

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

Future<web.FileSystemDirectoryHandle> _freshDir(String name) async {
  final root = await web.window.navigator.storage.getDirectory().toDart;
  try {
    await root.removeEntry(name, web.FileSystemRemoveOptions(recursive: true)).toDart;
  } catch (_) {
    // Absent is the expected state; only a leftover from a previous run is not.
  }
  return await root.getDirectoryHandle(name, web.FileSystemGetDirectoryOptions(create: true)).toDart;
}

Future<void> _write(web.FileSystemDirectoryHandle dir, String name, List<int> bytes) async {
  final handle = await dir.getFileHandle(name, web.FileSystemGetFileOptions(create: true)).toDart;
  final writable = await handle.createWritable().toDart;
  await writable.write(Uint8List.fromList(bytes).toJS).toDart;
  await writable.close().toDart;
}

Future<web.FileSystemDirectoryHandle> _child(web.FileSystemDirectoryHandle dir, String name) =>
    dir.getDirectoryHandle(name, web.FileSystemGetDirectoryOptions(create: true)).toDart;

/// What a walk of an OPFS subtree found: the files with their bytes, and the
/// directories that hold no file anywhere beneath them.
typedef _Tree = ({List<StorageZipSourceFile> files, List<List<String>> emptyDirectories});

/// Walks [dir] the way the web leg's enumeration does, reading each file whole.
Future<_Tree> _readTree(web.FileSystemDirectoryHandle dir, [List<String> prefix = const <String>[]]) async {
  final files = <StorageZipSourceFile>[];
  final emptyDirectories = <List<String>>[];
  final iterator = _DirIterable(dir).values();
  while (true) {
    final result = await iterator.next().toDart;
    if (result.done.toDart) {
      break;
    }
    final handle = result.value as web.FileSystemHandle;
    final segments = [...prefix, handle.name];
    if (handle.kind == 'file') {
      final file = await (handle as web.FileSystemFileHandle).getFile().toDart;
      final buffer = await file.arrayBuffer().toDart;
      files.add((
        relativeSegments: segments,
        bytes: buffer.toDart.asUint8List(),
        // The same field `web_vfs.dart`'s walk resolves, from the same browser
        // API, so what the assembler is handed here is what production hands it.
        modified: DateTime.fromMillisecondsSinceEpoch(file.lastModified),
      ));
    } else {
      final nested = await _readTree(handle as web.FileSystemDirectoryHandle, segments);
      files.addAll(nested.files);
      emptyDirectories.addAll(nested.emptyDirectories);
      if (nested.files.isEmpty) {
        emptyDirectories.add(segments);
      }
    }
  }
  return (files: files, emptyDirectories: emptyDirectories);
}

void main() {
  // The archive's shape, compiled by `dart2js` and run in the browser that will
  // build it. The same cases run on the VM in storage_zip_web_export_test.dart:
  // this is the half of the web runner that used to live in `zip_export_web.dart`
  // where no suite could reach it.
  runStorageZipLayoutCases();

  test('a tree written to OPFS survives the round trip through the zip', () async {
    final dir = await _freshDir('storage_zip_export_web_test_roundtrip');
    await _write(dir, 'root.txt', 'root'.codeUnits);
    final nested = await _child(dir, 'nested');
    await _write(nested, 'same.bin', List<int>.generate(256, (i) => i));
    final other = await _child(dir, 'other');
    await _write(other, 'same.bin', List<int>.generate(256, (i) => 255 - i));
    await _child(dir, 'empty');

    final tree = await _readTree(dir);
    expect(tree.files.length, 3);

    final bytes = buildStorageZipBytes(
      rootName: 'source',
      files: tree.files,
      emptyDirectorySegments: tree.emptyDirectories,
    );

    final unpacked = <String, List<int>>{};
    final dated = <String, DateTime>{};
    final directories = <String>{};
    for (final entry in ZipDecoder().decodeBytes(bytes)) {
      expect(entry.name, startsWith('source/'));
      final relative = entry.name.substring('source/'.length);
      if (entry.isFile) {
        unpacked[relative] = entry.readBytes() ?? <int>[];
        dated[relative] = entry.lastModDateTime;
      } else {
        directories.add(relative.replaceAll(RegExp(r'/$'), ''));
      }
    }

    // The date survives `dart2js`: `lastModTime` is seconds computed from a JS
    // number and written into the DOS date/time field, which the format
    // quantises to two seconds. What this *cannot* say is that the file's own
    // date was preserved rather than replaced by "now" -- a file OPFS just
    // wrote is dated now -- so the preservation itself is held by
    // storage_zip_web_export_test.dart, over a file dated in the past.
    for (final file in tree.files) {
      final expected = file.modified;
      expect(expected, isNotNull, reason: 'the walk resolves a date for every file');
      final written = dated[file.relativeSegments.join('/')];
      expect(written, isNotNull, reason: file.relativeSegments.join('/'));
      // Day and hour, not the second: the format quantises to two seconds and
      // the fixture was written a moment ago, so a second-level comparison would
      // be a clock race rather than a check on the code.
      expect(
        [written!.year, written.month, written.day, written.hour],
        [expected!.year, expected.month, expected.day, expected.hour],
        reason: file.relativeSegments.join('/'),
      );
    }

    expect(unpacked.keys.toSet(), {'root.txt', 'nested/same.bin', 'other/same.bin'});
    expect(unpacked['root.txt'], 'root'.codeUnits);
    expect(unpacked['nested/same.bin'], List<int>.generate(256, (i) => i));
    expect(unpacked['other/same.bin'], List<int>.generate(256, (i) => 255 - i));
    expect(directories, contains('empty'));
  });

  test('an empty folder produces a readable archive rather than a failure', () async {
    final dir = await _freshDir('storage_zip_export_web_test_empty');
    final tree = await _readTree(dir);
    final bytes = buildStorageZipBytes(rootName: 'empty', files: tree.files);
    expect(ZipDecoder().decodeBytes(bytes).files, isEmpty);
  });

  test('the limit the browser is offered is the one the view can survive', () {
    // In the browser, not only on the VM: this decision is what stands between a
    // press and an allocation of roughly twice the folder's size, and it is
    // compiled by `dart2js` here -- 268435456 is beyond the 32-bit range that JS
    // bitwise arithmetic truncates to, so "the constant is what it says" is a
    // claim worth making on this platform too.
    expect(storageZipWebMaxTotalBytes, 268435456);
    expect(decideStorageZipLimit(totalBytes: 268435456).verdict, StorageZipLimitVerdict.withinLimit);
    expect(decideStorageZipLimit(totalBytes: 268435457).verdict, StorageZipLimitVerdict.tooLarge);

    final refused = decideStorageZipLimit(totalBytes: 459359434);
    expect(refused.verdict, StorageZipLimitVerdict.tooLarge, reason: 'the active-record group on a real machine');
    expect(
      decideStorageZipLimit(totalBytes: 10223416).verdict,
      StorageZipLimitVerdict.withinLimit,
      reason: 'the largest single training record measured on a real machine',
    );
  });
}
