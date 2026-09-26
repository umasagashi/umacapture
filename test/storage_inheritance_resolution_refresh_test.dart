// The storage view's totals, after a whole-store inheritance resolution rewrote
// records while the view was open.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_inheritance_resolution_refresh_test.dart
//
// WHY THIS WRITER AND NOT THE OTHER RECORD MUTATIONS. The storage view is a
// modal card over the settings page, and opening a dialog replaces it -- which
// unmounts the tree and makes the next open re-read everything. So a record
// mutation the user drives from a dialog cannot leave a stale number. This one
// can: `ResolveInheritanceTile` starts the resolution with `unawaited` and no
// dialog in front of it when there are no pending merge candidates, so the run
// is still rewriting `active/` and `archive/` while the user is free to open
// Settings -> storage manager on the very page the tile lives on.
//
// Asserted at `DirectoryTotalsCache` for the reason
// `storage_archive_refresh_test.dart` gives: the cache is where a directory's
// recursive size comes from, and it is keyed by path, so "the stale number is
// gone" is a question about it rather than about which provider was rebuilt.
//
// WHAT THIS SUITE DOES NOT REACH. It builds no widgets, so it says nothing about
// what is painted and does not press the settings tile -- it calls the method
// the tile calls. The pending-candidate review list in front of the second call
// site is therefore out of reach as well; both arms of that tile end at the same
// method this drives.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/localization.dart';
import 'support/record_write_effects_fixture.dart';
import 'support/records.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    initializeMappers();
    // The resolution reports its outcome, and a toast is a translated sentence.
    loadAppTranslations();
  });

  late Directory tempRoot;
  late PathInfo layout;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_inh_refresh');
    final root = DirectoryPath(tempRoot.path);
    layout = PathInfo(
      documentDir: root,
      supportDir: root,
      executableDir: root / 'exe',
      downloadDir: root / 'dl',
      dataRoot: root,
    );
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  void writeRecord(DirectoryPath storeDir, CharaDetailRecord record) {
    File('${(storeDir / record.id).path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(record.toMap()));
  }

  void seed(DirectoryPath directory, String name, int bytes) {
    final file = File(directory.filePath(name).path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('x' * bytes);
  }

  /// Boots both record stores over the temp tree and hands back the active one,
  /// which owns `resolveAllInheritance`.
  Future<({ProviderContainer scope, CharaDetailRecordStorage storage})> boot() async {
    final scope = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => layout),
        pathInfoProvider.overrideWithValue(layout),
        pathLayoutLoader.overrideWith((ref) async => layout),
        moduleVersionLoader.overrideWith((ref) async => null),
      ],
    );
    addTearDown(scope.dispose);
    await scope.read(charaDetailRecordStorageLoaderProvider.future);
    await scope.read(charaDetailArchiveStorageLoaderProvider.future);
    return (scope: scope, storage: scope.read(charaDetailRecordStorageLoaderProvider.notifier));
  }

  /// A child in `active/` whose parent sits in `archive/`, so the resolution has
  /// a link to write and touches both stores doing it.
  void seedLinkablePair() {
    writeRecord(
      layout.charaDetailActiveDir,
      makeRecord(id: 'child-active', card: 20, parent1Card: 10, parent1: const [Factor(1, 1)]),
    );
    writeRecord(layout.charaDetailArchiveDir, makeRecord(id: 'parent-archive', card: 10, self: const [Factor(1, 1)]));
  }

  test('the record root loses its cached total when the whole store is resolved', () async {
    seedLinkablePair();
    final (:scope, :storage) = await boot();
    final cache = scope.read(directoryTotalsCacheProvider);
    expect((await cache.totalsOf(layout.charaDetailDir)).fileCount, 2);

    await storage.resolveAllInheritance(effects: inheritanceResolutionEffects(scope));

    expect(cache.peek(layout.charaDetailDir), isNull);
    // The resolution really did something: the child now names its parent by
    // record id, which is the write that falsified the numbers.
    expect(storage.getBy(id: 'child-active')?.metadata.recordId.parent1, 'parent-archive');
  });

  // Both stores are written and both are under the record root, which
  // `invalidate` drops together with its descendants. Asserted separately: a fix
  // that dropped only the exact path handed in would pass the case above and
  // leave the two store rows showing what the resolution rewrote.
  test('both store directories lose their cached totals too', () async {
    seedLinkablePair();
    final (:scope, :storage) = await boot();
    final cache = scope.read(directoryTotalsCacheProvider);
    expect((await cache.totalsOf(layout.charaDetailActiveDir)).fileCount, 1);
    expect((await cache.totalsOf(layout.charaDetailArchiveDir)).fileCount, 1);

    await storage.resolveAllInheritance(effects: inheritanceResolutionEffects(scope));

    expect(cache.peek(layout.charaDetailActiveDir), isNull);
    expect(cache.peek(layout.charaDetailArchiveDir), isNull);
  });

  // A resolution must not be reported as a change to everything: a fix that
  // cleared the whole cache would satisfy the cases above and throw away totals
  // nothing falsified, which is a re-walk of every other group on the next visit.
  test('a tree the resolution cannot have touched keeps its cached total', () async {
    seedLinkablePair();
    seed(layout.tempDir, 'scratch.bin', 32);
    final (:scope, :storage) = await boot();
    final cache = scope.read(directoryTotalsCacheProvider);
    expect((await cache.totalsOf(layout.charaDetailDir)).fileCount, 2);
    expect((await cache.totalsOf(layout.tempDir)).knownBytes, 32);

    await storage.resolveAllInheritance(effects: inheritanceResolutionEffects(scope));

    expect(cache.peek(layout.tempDir)?.knownBytes, 32);
  });

  // A run that found no new link is not a run that wrote nothing worth
  // re-measuring: the pass republishes whatever it considered changed, and
  // "changed" is a question about the resolver's result rather than about the
  // tree. Conditioning the announcement on it is the fix this case refuses.
  test('a resolution that finds no link re-measures as well', () async {
    writeRecord(layout.charaDetailActiveDir, makeRecord(id: 'lonely', card: 20));
    final (:scope, :storage) = await boot();
    final cache = scope.read(directoryTotalsCacheProvider);
    expect((await cache.totalsOf(layout.charaDetailDir)).fileCount, 1);

    await storage.resolveAllInheritance(effects: inheritanceResolutionEffects(scope));

    expect(cache.peek(layout.charaDetailDir), isNull);
  });

  // The tap the double-tap guard refuses is the one case where nothing on disk
  // moved: it returns before the run starts, so it never reaches the
  // announcement. This is what tells the cases above apart from a method that
  // announces unconditionally on entry.
  test('a refused second run announces nothing', () async {
    seedLinkablePair();
    final (:scope, :storage) = await boot();
    final cache = scope.read(directoryTotalsCacheProvider);
    expect((await cache.totalsOf(layout.charaDetailDir)).fileCount, 2);
    scope.read(inheritanceResolutionRunningProvider.notifier).set(true);

    await storage.resolveAllInheritance(effects: inheritanceResolutionEffects(scope));

    expect(cache.peek(layout.charaDetailDir)?.fileCount, 2);
  });
}
