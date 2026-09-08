// Size and last-modified time across the `FsBackend` surface, on the io backend
// and on the web-shaped double.
//
//   .fvm/flutter_sdk/bin/flutter test test/fs_metadata_test.dart
//
// Three things are pinned here, and they are different claims:
//
// * `FsBackend.modified` exists and answers with a real clock reading, rather
//   than with the epoch that `FileStat.stat` hands back for a path that is not
//   there.
// * A listing made with `withMetadata: true` carries each file's size, and that
//   size is the same number `length()` reports -- so a browsing UI can enumerate
//   a directory once instead of enumerating it and then probing every entry,
//   which on OPFS re-walks the handle chain from the storage root each time.
// * `metadataFromStat` (`fs_backend_io.dart`) turns a `notFound` `FileStat` --
//   the answer `FileStat.stat`/`statSync` give for a path that vanished between
//   directory enumeration and the per-entry `stat()` call -- into absent
//   metadata rather than passing through its `-1`-byte, epoch-dated sentinel
//   values. `list`/`listSync` route every entry's metadata through it, so this
//   is checked at the reduction itself rather than by racing a real deletion
//   against a directory walk, which the enumeration order does not make
//   reproducible.
//
// The second claim is checked twice on purpose: once at the backend
// (`fsBackend.list`) and once at `DirectoryPath.listWithMetadata`, which is the
// function the storage tree calls. They can come apart -- `PathEntity.list` and
// `listSync` drop the metadata through `_typed`, and a UI built on those would
// see the backend test pass while every size it displayed was absent.
//
// The browser half of the same question is in fs_metadata_web_test.dart; what
// that suite can and cannot reach is stated in its own header.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/fs_backend_io.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/web_like_fs_backend.dart';

/// Widest gap accepted between a write and the timestamp read back for it.
///
/// It is bounded by the clock, not by the test: FAT-family filesystems quantise
/// modification times to two seconds, and the surrounding I/O is unbounded on a
/// loaded machine. Anything inside this window is "the write that just
/// happened"; the failure this guards against is the epoch, half a century away.
const _clockSlack = Duration(seconds: 30);

void main() {
  late Directory root;
  late FsBackend realBackend;

  setUp(() {
    realBackend = fsBackend;
    root = Directory.systemTemp.createTempSync('fs_metadata_test');
  });

  tearDown(() {
    fsBackend = realBackend;
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  String at(String name) => '${root.path}${Platform.pathSeparator}$name';

  Future<void> writeFile(String name, int bytes) {
    return fsBackend.writeBytes(at(name), List<int>.filled(bytes, 0x41));
  }

  group('FsBackend.modified', () {
    test('reads back the wall-clock time of a write that just happened', () async {
      final before = DateTime.now();
      await writeFile('fresh.bin', 128);
      final stamp = await fsBackend.modified(at('fresh.bin'));
      final after = DateTime.now();

      expect(
        stamp.isAfter(before.subtract(_clockSlack)) && stamp.isBefore(after.add(_clockSlack)),
        isTrue,
        reason: 'expected a timestamp near $before..$after, got $stamp',
      );
    });

    test('moves forward when the file is rewritten', () async {
      await writeFile('twice.bin', 8);
      final first = await fsBackend.modified(at('twice.bin'));
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await writeFile('twice.bin', 9);
      final second = await fsBackend.modified(at('twice.bin'));

      expect(second.isBefore(first), isFalse, reason: 'a later write must not report an earlier time');
    });

    test('reports a missing path as an error rather than as the epoch', () async {
      // `FileStat.stat` answers a missing path with a `notFound` stat whose
      // `modified` is 1970-01-01. Returning that would look like a valid, very
      // old file to every caller.
      await expectLater(fsBackend.modified(at('nothing-here.bin')), throwsA(isA<FileSystemException>()));
    });

    test('answers for a directory on io, which is the half web cannot', () async {
      await fsBackend.createDir(at('subdir'));
      expect(await fsBackend.modified(at('subdir')), isA<DateTime>());
    });

    test('throws UnsupportedError for a directory on the web-shaped backend', () async {
      await fsBackend.createDir(at('subdir'));
      fsBackend = WebLikeFsBackend(realBackend);

      await expectLater(fsBackend.modified(at('subdir')), throwsA(isA<UnsupportedError>()));
      // The file case is unaffected: it is only the directory handle that has no
      // metadata in OPFS.
      await writeFile('file.bin', 4);
      expect(await fsBackend.modified(at('file.bin')), isA<DateTime>());
    });
  });

  group('metadataFromStat -- the FileStat -> (size, modified) reduction listing uses', () {
    test('turns a real notFound FileStat into a pair of nulls, not the -1/epoch sentinel', () {
      final missing = at('nothing-here.bin');
      final stat = FileStat.statSync(missing);
      // Pin the SDK behavior this whole fix depends on: a missing path is
      // reported as a `notFound` stat, not as a thrown exception, and its
      // fields are a sentinel that looks like real (very wrong) data.
      expect(stat.type, FileSystemEntityType.notFound);
      expect(stat.size, -1);
      expect(stat.modified, DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));

      final metadata = metadataFromStat(stat);

      expect(metadata.size, isNull);
      expect(metadata.modified, isNull);
    });

    test('passes through the real size and modified time for a stat that resolves', () async {
      await writeFile('present.bin', 42);
      final stat = FileStat.statSync(at('present.bin'));

      final metadata = metadataFromStat(stat);

      expect(metadata.size, 42);
      expect(metadata.modified, stat.modified);
    });
  });

  group('FsBackend.list metadata', () {
    test('carries a size for every file, agreeing with length() on all of them', () async {
      const sizes = {'a.bin': 0, 'b.bin': 1, 'c.bin': 4096, 'd.bin': 65537};
      for (final entry in sizes.entries) {
        await writeFile(entry.key, entry.value);
      }
      await fsBackend.createDir(at('nested'));

      final entries = await fsBackend.list(root.path, withMetadata: true);
      expect(entries.length, sizes.length + 1);

      var files = 0;
      for (final entry in entries) {
        if (entry.isDirectory) {
          expect(entry.size, isNull, reason: 'a directory has no size on either backend');
          continue;
        }
        files++;
        expect(entry.size, isNotNull);
        expect(entry.size, await fsBackend.length(entry.path), reason: 'disagreed on ${entry.path}');
        expect(entry.modified, isNotNull);
      }
      expect(files, sizes.length);
    });

    test('leaves the metadata absent when it was not asked for', () async {
      await writeFile('plain.bin', 32);
      final entries = await fsBackend.list(root.path);

      expect(entries.single.size, isNull);
      expect(entries.single.modified, isNull);
    });

    test('listSync carries the same metadata as list', () async {
      await writeFile('sync.bin', 77);
      final asyncEntry = (await fsBackend.list(root.path, withMetadata: true)).single;
      final syncEntry = fsBackend.listSync(root.path, withMetadata: true).single;

      expect(syncEntry.size, asyncEntry.size);
      expect(syncEntry.isDirectory, asyncEntry.isDirectory);
      expect(syncEntry.modified, isNotNull);
    });

    test('a directory listed on the web-shaped backend carries no timestamp', () async {
      await fsBackend.createDir(at('nested'));
      await writeFile('leaf.bin', 3);
      fsBackend = WebLikeFsBackend(realBackend);

      final entries = await fsBackend.list(root.path, withMetadata: true);
      final directory = entries.singleWhere((e) => e.isDirectory);
      final file = entries.singleWhere((e) => !e.isDirectory);

      expect(directory.modified, isNull, reason: 'OPFS directory handles expose no metadata');
      expect(file.size, 3);
      expect(file.modified, isNotNull);
    });
  });

  group('DirectoryPath.listWithMetadata -- the listing the storage tree calls', () {
    test('every entry of an all-files directory carries a size', () async {
      const sizes = {'one.bin': 10, 'two.bin': 200, 'three.bin': 3000};
      for (final entry in sizes.entries) {
        await writeFile(entry.key, entry.value);
      }

      final listing = await DirectoryPath(root.path).listWithMetadata();

      expect(listing.length, sizes.length);
      expect(listing.map((e) => e.size), everyElement(isNotNull), reason: 'a size dropped on the way to the UI');
      expect(listing.map((e) => e.modified), everyElement(isNotNull));
      for (final item in listing) {
        expect(item.entity, isA<FilePath>());
        expect(item.size, sizes[item.entity.name], reason: 'wrong size for ${item.entity.name}');
        expect(item.size, await (item.entity as FilePath).length());
      }
    });

    test('keeps each entry typed, so the kind needs no second probe', () async {
      await writeFile('leaf.bin', 5);
      await fsBackend.createDir(at('branch'));

      final listing = await DirectoryPath(root.path).listWithMetadata();
      final directory = listing.singleWhere((e) => e.entity is DirectoryPath);
      final file = listing.singleWhere((e) => e.entity is FilePath);

      expect(directory.entity.isFileSync, isFalse);
      expect(file.entity.isFileSync, isTrue);
      expect(directory.size, isNull, reason: 'a recursive total is a separate aggregation, not this listing');
      expect(file.size, 5);
    });

    test('reaches nested entries with metadata intact when recursive', () async {
      await fsBackend.createDir(at('branch'));
      await fsBackend.writeBytes('${at('branch')}${Platform.pathSeparator}deep.bin', List<int>.filled(21, 0x42));

      final listing = await DirectoryPath(root.path).listWithMetadata(recursive: true);
      final deep = listing.singleWhere((e) => e.entity.name == 'deep.bin');

      expect(deep.size, 21);
      expect(deep.modified, isNotNull);
    });
  });
}
