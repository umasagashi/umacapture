// Recursive directory totals for the storage view.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_directory_totals_test.dart
//
// Three claims:
//
// * The aggregation reads sizes and timestamps *out of the enumeration*. The
//   `length()` call count is asserted to be zero, because on OPFS that call is a
//   root-to-leaf handle walk and doing it per entry is the cost `FsEntry`'s
//   metadata surface exists to avoid. A test can only observe the call, not the
//   cost, so the call is what is pinned.
// * A file whose size the enumeration could not resolve is counted as unresolved
//   rather than folded into the total as zero, and an empty directory has no
//   timestamp at all rather than the epoch -- on web there are no descendants to
//   estimate one from, so the value does not exist.
// * The cache computes once, only when asked, and drops exactly the entries an
//   invalidation can have changed -- the path, its ancestors and its subtree.
//
// The web-shaped backend is used for the call-count and null-size cases on
// purpose: it is the platform where the cost is real and where a directory
// genuinely has no timestamp. What that double does not model is stated in its
// own header; nothing here depends on anything beyond the sync prohibition and
// the directory-metadata prohibition.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/storage/directory_totals.dart';

import 'support/web_like_fs_backend.dart';

/// A web-shaped backend that also drops the size of every `*.ghost` entry,
/// standing in for the two ways a listing can come back without one: an entry
/// deleted between the enumeration and its metadata read, and a handle the
/// browser refused. Neither is reproducible by racing a real deletion against a
/// walk, because the enumeration order is not fixed.
class _GhostSizeBackend extends WebLikeFsBackend {
  _GhostSizeBackend(super.inner);

  @override
  Future<List<FsEntry>> list(
    String path, {
    bool recursive = false,
    bool followLinks = false,
    bool withMetadata = false,
  }) async {
    final entries = await super.list(path, recursive: recursive, followLinks: followLinks, withMetadata: withMetadata);
    return entries
        .map(
          (e) => e.path.endsWith('.ghost')
              ? (path: e.path, isDirectory: e.isDirectory, size: null, modified: e.modified)
              : e,
        )
        .toList();
  }
}

/// A web-shaped backend that holds its *first* enumeration open after it has
/// already read the tree.
///
/// That is the only shape that reproduces the race the cache exists to survive:
/// walk 1 must have captured the pre-delete listing before the delete lands, so
/// that a stale answer is materially different from a fresh one. Sleeping or
/// racing a real deletion against a walk cannot pin the ordering.
class _GatedListBackend extends WebLikeFsBackend {
  _GatedListBackend(super.inner);

  final entered = Completer<void>();
  final _release = Completer<void>();
  var _gated = false;

  void release() => _release.complete();

  @override
  Future<List<FsEntry>> list(
    String path, {
    bool recursive = false,
    bool followLinks = false,
    bool withMetadata = false,
  }) async {
    final entries = await super.list(path, recursive: recursive, followLinks: followLinks, withMetadata: withMetadata);
    if (!_gated) {
      _gated = true;
      entered.complete();
      await _release.future;
    }
    return entries;
  }
}

void main() {
  late Directory root;
  late DirectoryPath rootPath;
  late FsBackend realBackend;

  setUp(() {
    realBackend = fsBackend;
    root = Directory.systemTemp.createTempSync('storage_totals_test');
    rootPath = DirectoryPath(root.path);
  });

  tearDown(() {
    fsBackend = realBackend;
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  String at(String relative) => '${root.path}${Platform.pathSeparator}$relative';

  Future<void> writeFile(String relative, int bytes) async {
    await fsBackend.writeBytes(at(relative), List<int>.filled(bytes, 0x41));
  }

  group('aggregateDirectoryTotals -- one enumeration, no per-entry probe', () {
    test('totalling a directory of 20 files never calls length()', () async {
      for (var i = 0; i < 20; i++) {
        await writeFile('file$i.bin', 10 + i);
      }
      final backend = WebLikeFsBackend(realBackend);
      fsBackend = backend;
      backend.resetCallCounts();

      final totals = await aggregateDirectoryTotals(rootPath);

      expect(totals.fileCount, 20);
      expect(totals.knownBytes, 20 * 10 + (19 * 20) ~/ 2);
      expect(backend.lengthCalls, 0, reason: 'a per-entry length() is a full OPFS handle walk each time');
      expect(backend.listCalls, 1, reason: 'one recursive enumeration, not one per level or per entry');
    });
  });

  group('aggregateDirectoryTotals -- shape of the tree', () {
    test('an empty directory totals zero and has no timestamp', () async {
      final totals = await aggregateDirectoryTotals(rootPath);

      expect(totals.knownBytes, 0);
      expect(totals.fileCount, 0);
      expect(totals.unknownSizeFiles, 0);
      expect(totals.latestModified, isNull, reason: 'no descendant to take a timestamp from');
    });

    test('a directory that does not exist is an empty total, not a throw', () async {
      final missing = rootPath / 'never_created';

      final totals = await aggregateDirectoryTotals(missing);

      expect(totals.fileCount, 0);
      expect(totals.knownBytes, 0);
      expect(totals.latestModified, isNull);
    });

    test('nested files are summed and the directories themselves add nothing', () async {
      await fsBackend.createDir(at('branch'), recursive: true);
      await fsBackend.createDir(at('branch${Platform.pathSeparator}twig'), recursive: true);
      await fsBackend.createDir(at('empty'), recursive: true);
      await writeFile('top.bin', 100);
      await writeFile('branch${Platform.pathSeparator}mid.bin', 20);
      await writeFile('branch${Platform.pathSeparator}twig${Platform.pathSeparator}deep.bin', 3);

      final totals = await aggregateDirectoryTotals(rootPath);

      expect(totals.fileCount, 3, reason: 'the three directories are not files');
      expect(totals.knownBytes, 123);
      expect(totals.unknownSizeFiles, 0, reason: 'a directory has no size by contract; it is not an unresolved one');
      expect(totals.latestModified, isNotNull);
    });

    test('a subtree totals only itself', () async {
      await fsBackend.createDir(at('branch'), recursive: true);
      await writeFile('top.bin', 100);
      await writeFile('branch${Platform.pathSeparator}mid.bin', 20);

      final totals = await aggregateDirectoryTotals(rootPath / 'branch');

      expect(totals.knownBytes, 20);
      expect(totals.fileCount, 1);
    });

    test('the newest descendant file wins, and it is a file that supplies it', () async {
      await fsBackend.createDir(at('branch'), recursive: true);
      await writeFile('old.bin', 1);
      final old = DateTime.now().subtract(const Duration(days: 30));
      File(at('old.bin')).setLastModifiedSync(old);
      await writeFile('branch${Platform.pathSeparator}new.bin', 1);
      final recent = DateTime.now().subtract(const Duration(days: 1));
      File(at('branch${Platform.pathSeparator}new.bin')).setLastModifiedSync(recent);

      final totals = await aggregateDirectoryTotals(rootPath);

      final latest = totals.latestModified;
      expect(latest, isNotNull);
      expect(latest?.difference(recent).abs(), lessThan(const Duration(seconds: 2)));
    });
  });

  group('aggregateDirectoryTotals -- an unresolved size is not a zero', () {
    test('known sizes still total, and the unresolved ones are counted apart', () async {
      await writeFile('real.bin', 40);
      await writeFile('also.bin', 2);
      await writeFile('vanished.ghost', 1000);
      fsBackend = _GhostSizeBackend(realBackend);

      final totals = await aggregateDirectoryTotals(rootPath);

      expect(totals.fileCount, 3);
      expect(totals.knownBytes, 42, reason: 'the unresolved file must not be added as its real size');
      expect(totals.knownBytes, isNot(1042));
      expect(totals.unknownSizeFiles, 1, reason: 'folding it in as 0 would claim an exact total that is a lower bound');
    });

    test('a directory with only unresolved files reports a lower bound of zero, flagged', () async {
      await writeFile('a.ghost', 5);
      fsBackend = _GhostSizeBackend(realBackend);

      final totals = await aggregateDirectoryTotals(rootPath);

      expect(totals.knownBytes, 0);
      expect(totals.unknownSizeFiles, 1, reason: '0 B and "0 B, one file unaccounted" must not look the same');
    });
  });

  group('DirectoryTotalsCache', () {
    test('computes nothing until asked', () async {
      await writeFile('a.bin', 7);
      final backend = WebLikeFsBackend(realBackend);
      fsBackend = backend;
      backend.resetCallCounts();

      final cache = DirectoryTotalsCache();

      expect(cache.peek(rootPath), isNull);
      expect(cache.isComputing(rootPath), isFalse);
      expect(backend.listCalls, 0, reason: 'constructing the cache must not walk anything');
    });

    test('a second call is served from the cache without walking again', () async {
      await writeFile('a.bin', 7);
      final backend = WebLikeFsBackend(realBackend);
      fsBackend = backend;
      final cache = DirectoryTotalsCache();
      await cache.totalsOf(rootPath);
      backend.resetCallCounts();

      final again = await cache.totalsOf(rootPath);

      expect(again.knownBytes, 7);
      expect(backend.listCalls, 0);
      expect(cache.peek(rootPath)?.knownBytes, 7);
    });

    test('two concurrent asks for the same directory share one walk', () async {
      await writeFile('a.bin', 7);
      final backend = WebLikeFsBackend(realBackend);
      fsBackend = backend;
      backend.resetCallCounts();
      final cache = DirectoryTotalsCache();

      final results = await Future.wait([cache.totalsOf(rootPath), cache.totalsOf(rootPath)]);

      expect(results.first.knownBytes, 7);
      expect(results.last.knownBytes, 7);
      expect(backend.listCalls, 1, reason: 'a duplicate OPFS walk blocks the same thread the UI runs on');
    });

    test('invalidating a child drops the child, its ancestors and its subtree', () async {
      await fsBackend.createDir(at('branch${Platform.pathSeparator}twig'), recursive: true);
      await fsBackend.createDir(at('other'), recursive: true);
      await writeFile('branch${Platform.pathSeparator}twig${Platform.pathSeparator}deep.bin', 3);
      await writeFile('other${Platform.pathSeparator}kept.bin', 5);
      final cache = DirectoryTotalsCache();
      final branch = rootPath / 'branch';
      final twig = branch / 'twig';
      final other = rootPath / 'other';
      for (final directory in [rootPath, branch, twig, other]) {
        await cache.totalsOf(directory);
      }

      cache.invalidate(branch);

      expect(cache.peek(branch), isNull, reason: 'the changed path itself');
      expect(cache.peek(rootPath), isNull, reason: 'an ancestor total contains the change');
      expect(cache.peek(twig), isNull, reason: 'a directory delete takes its subtree with it');
      expect(cache.peek(other), isNotNull, reason: 'a sibling is untouched, and re-walking it is not free');
    });

    test('clear drops everything', () async {
      await writeFile('a.bin', 7);
      final cache = DirectoryTotalsCache();
      await cache.totalsOf(rootPath);

      cache.clear();

      expect(cache.peek(rootPath), isNull);
    });

    test('a walk overtaken by an invalidation returns its result but does not cache it', () async {
      await writeFile('a.bin', 7);
      final cache = DirectoryTotalsCache();

      final pending = cache.totalsOf(rootPath);
      cache.invalidate(rootPath);
      final totals = await pending;

      expect(totals.knownBytes, 7, reason: 'the caller still gets an answer');
      expect(cache.peek(rootPath), isNull, reason: 'the answer straddles the change, so it must not be remembered');
    });

    test('an ask that starts after an invalidation does not join the walk it overtook', () async {
      await writeFile('a.bin', 7);
      final gate = _GatedListBackend(realBackend);
      fsBackend = gate;
      final cache = DirectoryTotalsCache();

      final first = cache.totalsOf(rootPath);
      await gate.entered.future;
      File(at('a.bin')).deleteSync();
      cache.invalidate(rootPath);
      final second = cache.totalsOf(rootPath);
      gate.release();

      expect(await first.then((t) => t.knownBytes), 7, reason: 'the caller that started the walk still gets an answer');
      expect(
        await second.then((t) => t.knownBytes),
        0,
        reason: 'a count asked for after the delete must not be served the walk that straddled it',
      );
    });

    test('a total taken after an invalidation is the one that gets cached', () async {
      await writeFile('a.bin', 7);
      final gate = _GatedListBackend(realBackend);
      fsBackend = gate;
      final cache = DirectoryTotalsCache();

      final first = cache.totalsOf(rootPath);
      await gate.entered.future;
      File(at('a.bin')).deleteSync();
      cache.invalidate(rootPath);
      final second = cache.totalsOf(rootPath);
      gate.release();
      await first;
      await second;

      expect(
        cache.peek(rootPath)?.knownBytes,
        0,
        reason: 'the walk that straddled the delete must not win the cache slot back',
      );
    });

    test('an overtaken walk finishing does not evict the walk that replaced it', () async {
      await writeFile('a.bin', 7);
      final gate = _GatedListBackend(realBackend);
      fsBackend = gate;
      final cache = DirectoryTotalsCache();

      final first = cache.totalsOf(rootPath);
      await gate.entered.future;
      cache.invalidate(rootPath);
      final second = cache.totalsOf(rootPath);
      gate.release();
      await first;

      expect(cache.isComputing(rootPath), isTrue, reason: 'the replacement walk is still running');
      final third = cache.totalsOf(rootPath);
      await Future.wait([second, third]);

      expect(
        gate.listCalls,
        2,
        reason: 'the overtaken walk and its replacement -- a third caller joins, it does not re-traverse OPFS',
      );
    });
  });
}
