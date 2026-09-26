// The storage view's totals, after a record was written while the view was open.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_record_write_refresh_test.dart
//
// `DirectoryTotalsCache` can see exactly one class of change: the one this app
// made itself, announced by the code that made it. A delete announces through
// `storage_delete_invalidation.dart`; entering the view drops everything, which
// covers a write that happened while it was closed. A record that arrives while
// the view is *open* -- nothing unmounts a view the user is looking at -- is
// announced by the write itself (`record_write_invalidation.dart`): an import
// finishing behind the settings dialog, or a capture publishing into `active/`,
// drops the record tree's cached totals, so the bytes and the file count on screen
// are measured again rather than describing the tree as it was.
//
// Asserted at `DirectoryTotalsCache` itself rather than at the view's providers:
// the cache is where a directory's recursive size actually comes from, and it is
// keyed by path, so "the stale number is gone" is a question about it and not
// about which provider happened to be rebuilt. `storage_tab_refresh_test.dart`
// covers the provider half for the delete seam, and the wiring here goes through
// the same `reloadStorageTab`.
//
// WHAT THIS SUITE DOES NOT REACH. It builds no widgets, so it says nothing about
// what is painted. It does not drive the import button (that needs a file
// picker) -- it calls the function the button's completion block is, which is why
// that block is one call. `addFromFileAsync` is driven over `dart:io`, not the
// OPFS it runs on in a browser. And a re-recognition is announced by calling
// `updated` directly, not through the platform channel.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/chara_detail/import_button.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/hive.dart';
import 'support/record_write_effects_fixture.dart';
import 'support/records.dart';
import 'support/settling.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    initializeMappers();
  });
  // The capture merge reads the auto-copy setting, which is Hive-backed.
  useHiveForTest(['settings']);

  late Directory tempRoot;
  late PathInfo layout;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_record_write_refresh');
    capturedRecordRetention.clear();
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
    capturedRecordRetention.clear();
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

  group('a finished import re-measures the tree it wrote into', () {
    ProviderContainer container() {
      final result = ProviderContainer(
        overrides: [pathInfoProvider.overrideWithValue(layout), pathLayoutLoader.overrideWith((ref) async => layout)],
      );
      addTearDown(result.dispose);
      return result;
    }

    test('the record root loses its cached total', () async {
      seed(layout.charaDetailActiveDir, 'existing.bin', 64);
      final scope = container();
      final cache = scope.read(directoryTotalsCacheProvider);
      expect((await cache.totalsOf(layout.charaDetailDir)).knownBytes, 64);

      // What the import did: more bytes under the root, with nothing telling the
      // cache. The cached 64 is what the open view would keep showing.
      seed(layout.charaDetailActiveDir, 'imported.bin', 32);
      applyRecordImportCompletion(
        scope.read(refBaseProvider),
        layout,
        writtenIds: const <String>[],
        effects: recordImportEffects(scope.read(refBaseProvider)),
      );

      expect(cache.peek(layout.charaDetailDir), isNull);
      expect((await cache.totalsOf(layout.charaDetailDir)).knownBytes, 96);
    });

    // The store directories are the ones an import writes, and they are dropped
    // because `invalidate` takes the named path's descendants with it. Asserted
    // separately from the root: a fix that dropped only the exact path handed in
    // would pass the test above and leave the group's own rows stale.
    test('the store directory under it loses its cached total too', () async {
      seed(layout.charaDetailActiveDir, 'existing.bin', 64);
      final scope = container();
      final cache = scope.read(directoryTotalsCacheProvider);
      expect((await cache.totalsOf(layout.charaDetailActiveDir)).knownBytes, 64);

      applyRecordImportCompletion(
        scope.read(refBaseProvider),
        layout,
        writtenIds: const <String>[],
        effects: recordImportEffects(scope.read(refBaseProvider)),
      );

      expect(cache.peek(layout.charaDetailActiveDir), isNull);
    });

    // An import must not be reported as a change to everything. A fix that
    // cleared the whole cache would satisfy the two tests above and would throw
    // away totals nothing falsified -- which is a re-walk of every other group on
    // the next visit.
    test('a tree the import cannot have touched keeps its cached total', () async {
      seed(layout.charaDetailActiveDir, 'existing.bin', 64);
      seed(layout.tempDir, 'scratch.bin', 32);
      final scope = container();
      final cache = scope.read(directoryTotalsCacheProvider);
      await cache.totalsOf(layout.charaDetailDir);
      await cache.totalsOf(layout.tempDir);

      applyRecordImportCompletion(
        scope.read(refBaseProvider),
        layout,
        writtenIds: const <String>[],
        effects: recordImportEffects(scope.read(refBaseProvider)),
      );

      expect(cache.peek(layout.tempDir)?.knownBytes, 32);
    });
  });

  group('a published capture re-measures the tree it landed in', () {
    /// Boots the real store over a temp tree holding one record.
    Future<({ProviderContainer scope, CharaDetailRecordStorage store})> boot() async {
      writeRecord(layout.charaDetailActiveDir, makeRecord(id: 'stored', card: 1));
      final scope = ProviderContainer(
        overrides: [
          pathInfoLoader.overrideWith((ref) async => layout),
          pathInfoProvider.overrideWithValue(layout),
          pathLayoutLoader.overrideWith((ref) async => layout),
          moduleVersionLoader.overrideWith((ref) async => null),
        ],
      );
      addTearDown(scope.dispose);
      // A real subscription: the store's capture listener lives inside its build,
      // and riverpod disposes a provider nothing listens to.
      addTearDown(scope.listen(charaDetailRecordStorageLoaderProvider, (_, _) {}).close);
      await scope.read(charaDetailRecordStorageLoaderProvider.future);
      await scope.read(charaDetailArchiveStorageLoaderProvider.future);
      return (scope: scope, store: scope.read(charaDetailRecordStorageLoaderProvider.notifier));
    }

    test('the record root loses its cached total when a capture is merged', () async {
      final (:scope, :store) = await boot();
      final cache = scope.read(directoryTotalsCacheProvider);
      final before = await cache.totalsOf(layout.charaDetailDir);
      expect(before.fileCount, 1);

      // What the producer did before announcing the id: the directory is on disk
      // and the cached total predates it.
      writeRecord(layout.charaDetailActiveDir, makeRecord(id: 'captured', card: 2));
      expect(cache.peek(layout.charaDetailDir)?.fileCount, 1);

      store.addFromFile('captured', effects: arrivalEffects(scope));

      expect(cache.peek(layout.charaDetailDir), isNull);
      expect((await cache.totalsOf(layout.charaDetailDir)).fileCount, 2);
    });

    // A capture the store refuses still changed the tree: the producer wrote the
    // directory before announcing it, and the refusal deletes it again. Both ends
    // of that leave the cached total describing neither.
    test('a capture refused as a duplicate re-measures as well', () async {
      final (:scope, :store) = await boot();
      final cache = scope.read(directoryTotalsCacheProvider);
      expect((await cache.totalsOf(layout.charaDetailDir)).fileCount, 1);

      // Same chara card as the stored record, so the merge rejects it.
      writeRecord(layout.charaDetailActiveDir, makeRecord(id: 'duplicate', card: 1));
      store.addFromFile('duplicate', effects: arrivalEffects(scope));

      expect(cache.peek(layout.charaDetailDir), isNull);
    });

    // The web harvest and the video import arrive through the asynchronous
    // path, which applies its declaration once the merge has settled.
    test('the record root loses its cached total when a capture arrives asynchronously', () async {
      final (:scope, :store) = await boot();
      final cache = scope.read(directoryTotalsCacheProvider);
      expect((await cache.totalsOf(layout.charaDetailDir)).fileCount, 1);

      writeRecord(layout.charaDetailActiveDir, makeRecord(id: 'captured', card: 2));
      expect(cache.peek(layout.charaDetailDir)?.fileCount, 1);

      await store.addFromFileAsync('captured', effects: arrivalEffects(scope));

      expect(cache.peek(layout.charaDetailDir), isNull);
      expect((await cache.totalsOf(layout.charaDetailDir)).fileCount, 2);
    });

    // An arrival whose record will not decode is moved into `quarantine/`, a sibling of the
    // store and a group row of its own in the storage view. Dropping only the record's own
    // directory takes its ancestors with it but not that sibling, so the quarantine row would
    // keep the size it had before the record landed in it. The scope is the record root for
    // exactly this reason.
    test('a capture moved into quarantine re-measures the quarantine directory', () async {
      final (:scope, :store) = await boot();
      final cache = scope.read(directoryTotalsCacheProvider);
      seed(layout.charaDetailQuarantineDir, 'earlier.bin', 16);
      expect((await cache.totalsOf(layout.charaDetailQuarantineDir)).fileCount, 1);

      File('${(layout.charaDetailActiveDir / 'broken').path}/record.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{}');
      store.addFromFile('broken', effects: arrivalEffects(scope));

      expect(File('${layout.charaDetailQuarantineDir.path}/broken/record.json').existsSync(), isTrue);
      expect(cache.peek(layout.charaDetailQuarantineDir), isNull);
      expect((await cache.totalsOf(layout.charaDetailQuarantineDir)).fileCount, 2);
    });
  });

  // A re-recognition rewrites files under `active/<id>` -- `prediction.json`,
  // the geometry files -- and can add ones the record did not have. The cached
  // total is warmed over the record files alone, the regeneration's output is
  // written, and only then is the record announced.
  group('a re-recognition re-measures the tree it rewrote', () {
    /// Boots the real store over a temp tree holding [ids], one `record.json` each.
    Future<ProviderContainer> boot(List<String> ids) async {
      for (final (index, id) in ids.indexed) {
        writeRecord(layout.charaDetailActiveDir, makeRecord(id: id, card: index + 1));
      }
      final scope = ProviderContainer(
        overrides: [
          pathInfoLoader.overrideWith((ref) async => layout),
          pathInfoProvider.overrideWithValue(layout),
          pathLayoutLoader.overrideWith((ref) async => layout),
          moduleVersionLoader.overrideWith((ref) async => null),
        ],
      );
      addTearDown(scope.dispose);
      addTearDown(scope.listen(charaDetailRecordStorageLoaderProvider, (_, _) {}).close);
      await scope.read(charaDetailRecordStorageLoaderProvider.future);
      return scope;
    }

    /// Waits for the batch's delayed publish, so it does not run into teardown.
    Future<void> settleBatch(ProviderContainer scope) => waitUntil(
      () => scope.read(charaDetailRecordRegenerationControllerProvider).isEmpty,
      describe: 'the regeneration batch to publish',
    );

    test('a batch re-measures once, when it finishes', () async {
      final scope = await boot(['r1', 'r2']);
      final cache = scope.read(directoryTotalsCacheProvider);
      final controller = scope.read(charaDetailRecordRegenerationControllerProvider.notifier);
      expect((await cache.totalsOf(layout.charaDetailDir)).fileCount, 2);

      controller.beginBatch(2);
      seed(layout.charaDetailActiveDir / 'r1', 'prediction.json', 64);
      await controller.updated('r1', effects: regenerationEffects(scope));
      // Mid-batch: the total is left for the batch's end to re-measure once.
      expect(cache.peek(layout.charaDetailDir)?.fileCount, 2);

      seed(layout.charaDetailActiveDir / 'r2', 'prediction.json', 64);
      await controller.updated('r2', effects: regenerationEffects(scope));

      expect(cache.peek(layout.charaDetailDir), isNull);
      expect((await cache.totalsOf(layout.charaDetailDir)).fileCount, 4);
      await settleBatch(scope);
    });

    // The reload that follows a regeneration quarantines a record that no longer decodes, so a
    // batch can write into `quarantine/` as well as `active/`. The batch's re-measure has to
    // reach that sibling row; dropping `active/` alone would leave it stale.
    test('a batch whose record was quarantined re-measures the quarantine directory', () async {
      final scope = await boot(['r1']);
      final cache = scope.read(directoryTotalsCacheProvider);
      final controller = scope.read(charaDetailRecordRegenerationControllerProvider.notifier);
      seed(layout.charaDetailQuarantineDir, 'earlier.bin', 16);
      expect((await cache.totalsOf(layout.charaDetailQuarantineDir)).fileCount, 1);

      controller.beginBatch(1);
      File('${(layout.charaDetailActiveDir / 'r1').path}/record.json').writeAsStringSync('{}');
      await controller.updated('r1', effects: regenerationEffects(scope));

      expect(File('${layout.charaDetailQuarantineDir.path}/r1/record.json').existsSync(), isTrue);
      expect(cache.peek(layout.charaDetailQuarantineDir), isNull);
      expect((await cache.totalsOf(layout.charaDetailQuarantineDir)).fileCount, 2);
      await settleBatch(scope);
    });

    // A late announcement, after its batch was closed (or with no batch at all),
    // has no batch end to wait for.
    test('a regeneration outside a batch re-measures at once', () async {
      final scope = await boot(['r1']);
      final cache = scope.read(directoryTotalsCacheProvider);
      final controller = scope.read(charaDetailRecordRegenerationControllerProvider.notifier);
      expect((await cache.totalsOf(layout.charaDetailDir)).fileCount, 1);

      seed(layout.charaDetailActiveDir / 'r1', 'prediction.json', 64);
      await controller.updated('r1', effects: regenerationEffects(scope));

      expect(cache.peek(layout.charaDetailDir), isNull);
      expect((await cache.totalsOf(layout.charaDetailDir)).fileCount, 2);
    });
  });
}
