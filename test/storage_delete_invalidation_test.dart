// What forgets a storage-view delete -- the table mapping a deleted path to the
// providers that must be invalidated -- and the exclusion metadata gets
// instead of a lock (stage 6c). Metadata files are keyed by column-spec key, not
// by record id, so the record gate cannot name a lock for them; the delete is
// serialised through the owning controller instead.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_delete_invalidation_test.dart
//
// Three claims are pinned here, and each is written so that removing the thing it
// names turns it red.
//
//  1. **The invalidate table is the table the code applies.** Asserted
//     against `storageDeleteInvalidationTargets`, which answers as data, so a row
//     can be compared to the provider it names rather than inferred from whether
//     some widget happened to rebuild.
//
//  2. **One metadata file is one controller and many records.** This
//     one is deliberately *not* asserted against the table: it seeds a rating
//     file holding three records' ratings, deletes the file through the real
//     runner, and reads the ratings back. That is the granularity the hint text
//     promises ("このセット全部が消えます"), and it is the granularity a table
//     assertion alone cannot demonstrate. It is asserted twice, once with the
//     serialiser in place and once with it overridden away, because the
//     serialiser can satisfy the first on its own -- measured, not supposed; see
//     the comment on the second.
//
//  3. **A metadata delete is serialised through the owning controller.**
//     The controller is dropped *before* the file goes, which is the whole of
//     the exclusion available against the memo and rating controllers: they
//     take no lock, so the root lock the scope also holds does not exclude them.
//
//  4. **A delete that forces the journal drain forgets what the drain
//     published.** Asserted over every shipped group that answers
//     `destroysTransactionJournal`, not over the one group that does today, so
//     the claim is about the predicate that puts the drain in front of a delete
//     rather than about a group id.
//
// WHAT THIS SUITE DOES NOT REACH. It does not build a record store, so
// "invalidating the active loader makes the row leave the table" is asserted at
// the provider and not on screen -- the store's `build()` needs a module set and
// a scan, and a fake in its place would assert the fake. It says nothing about
// web: `ref.invalidate` is platform-agnostic, but OPFS's listing behind
// `_loadRatings` is not exercised. The image cache and the settings boxes are
// other stages' and appear nowhere here.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/enhancement_merge.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/storage_delete.dart';
import 'package:umacapture/src/core/storage/storage_delete_invalidation.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/storage_delete_action.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';
import 'support/record_write_effects_fixture.dart';

void main() {
  late Directory tempRoot;
  late PathInfo layout;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    loadAppTranslations();
    initializeMappers();
  });

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_storage_invalidate');
    layout = PathInfo(
      documentDir: DirectoryPath('${tempRoot.path}/documents'),
      supportDir: DirectoryPath('${tempRoot.path}/support'),
      executableDir: DirectoryPath('${tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${tempRoot.path}/downloads'),
    );
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  StorageGroup groupOf(StorageGroupId id) => storageGroups.firstWhere((group) => group.id == id);

  List<Object> targetsFor(StorageGroupId id, List<PathEntity> targets) {
    return storageDeleteInvalidationTargets(group: groupOf(id), info: layout, targets: targets);
  }

  ProviderContainer container({StorageDeleteSerializer? serializer}) {
    final result = ProviderContainer(
      overrides: [
        pathInfoProvider.overrideWithValue(layout),
        // The delete path resolves its own directories from the layout rather
        // than from `pathInfoProvider`, so it keeps working while the record
        // store is unavailable.
        pathLayoutLoader.overrideWith((ref) async => layout),
        if (serializer != null) storageDeleteSerializerProvider.overrideWithValue(serializer),
      ],
    );
    addTearDown(result.dispose);
    return result;
  }

  /// A serialiser that excludes nothing, for isolating the invalidate table from
  /// the controller serialisation.
  Future<void> passThrough(PathEntity target, Future<void> Function() action) => action();

  /// Writes [json] to [path] under the temp root, creating its parents.
  void write(FilePath path, String json) {
    final file = File(path.path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(json);
  }

  group('every row of the invalidation table, and only that row', () {
    test('an active record invalidates the active loader and nothing else', () {
      expect(targetsFor(StorageGroupId.activeRecords, [layout.charaDetailActiveDir / 'rec-1']), [
        charaDetailRecordStorageLoaderProvider,
      ]);
    });

    test('an archived record invalidates the archive loader', () {
      expect(targetsFor(StorageGroupId.archivedRecords, [layout.charaDetailArchiveDir / 'rec-1']), [
        charaDetailArchiveStorageLoaderProvider,
      ]);
    });

    test('quarantine invalidates the count the banner shows', () {
      expect(targetsFor(StorageGroupId.quarantine, [layout.charaDetailQuarantineDir / 'broken_1']), [
        charaDetailQuarantineCountProvider,
      ]);
    });

    test('a rating file invalidates the store list and that key\'s controller', () {
      expect(targetsFor(StorageGroupId.metadata, [layout.charaDetailRatingDir.filePath('main.json')]), [
        charaDetailRecordRatingStorageDataLoader,
        charaDetailRecordRatingProvider('main'),
      ]);
    });

    test('a memo file invalidates the memo store list and that key\'s controller', () {
      expect(targetsFor(StorageGroupId.metadata, [layout.charaDetailMemoDir.filePath('notes.json')]), [
        charaDetailRecordMemoStorageDataLoader,
        charaDetailRecordMemoProvider('notes'),
      ]);
    });

    // The key is the file's *stem*. Addressing `main.json` would invalidate a
    // controller nobody holds, and the delete would look wired while landing on
    // nothing -- the same shape of silent miss as taking a lock whose name
    // matches no counterparty: exclusion that looks wired and excludes nobody.
    test('the key is the stem and not the file name', () {
      expect(
        targetsFor(StorageGroupId.metadata, [layout.charaDetailRatingDir.filePath('main.json')]),
        isNot(contains(charaDetailRecordRatingProvider('main.json'))),
      );
    });

    // Deleting the whole store directory takes every key with it, and the names
    // are no longer readable from anywhere: the files that carried them are gone.
    test('the whole rating directory invalidates the family, not one key', () {
      final targets = targetsFor(StorageGroupId.metadata, [layout.charaDetailRatingDir]);
      expect(targets, [charaDetailRecordRatingStorageDataLoader, charaDetailRecordRatingProvider]);
    });

    test('a group-level metadata delete covers both stores and the dismissals', () {
      final targets = targetsFor(StorageGroupId.metadata, groupOf(StorageGroupId.metadata).resolve(layout));
      expect(targets, [
        charaDetailRecordRatingStorageDataLoader,
        charaDetailRecordRatingProvider,
        charaDetailRecordMemoStorageDataLoader,
        charaDetailRecordMemoProvider,
        enhancementDismissedPairsProvider,
      ]);
    });

    test('the dismissal file invalidates the dismissed pairs', () {
      expect(targetsFor(StorageGroupId.metadata, [layout.charaDetailEnhancementDismissedFile]), [
        enhancementDismissedPairsProvider,
      ]);
    });

    // Not an enumeration of the module loaders: the assertion is that whatever
    // `moduleFileLoaders` holds is what gets invalidated, so a module file added
    // to the boot batch is covered without editing this test.
    test('modules invalidates the version and every module-file loader', () {
      expect(targetsFor(StorageGroupId.modules, [layout.modulesDir]), [moduleVersionLoader, ...moduleFileLoaders]);
      expect(moduleFileLoaders, isNotEmpty);
    });

    // `retired` is not in this list: it holds the transaction journals, so its
    // delete drains them and has to forget what the drain published. Its own row
    // still answers nothing -- see the drain group below for the difference.
    test('the groups the table gives no provider invalidate nothing', () {
      for (final id in [
        StorageGroupId.settings,
        StorageGroupId.temp,
        StorageGroupId.customSound,
        StorageGroupId.fontCache,
        StorageGroupId.unclassified,
        StorageGroupId.dataRootConfig,
      ]) {
        expect(targetsFor(id, groupOf(id).resolve(layout)), isEmpty, reason: '${id.name} should invalidate nothing');
      }
    });

    // Walks the shipped group list rather than a list spelled here, so a
    // thirteenth group is covered the moment it is added -- and the `switch` in
    // `storage_delete_invalidation.dart` refuses to compile until it answers.
    test('every shipped group answers', () {
      for (final group in storageGroups) {
        expect(
          () => storageDeleteInvalidationTargets(group: group, info: layout, targets: group.resolve(layout)),
          returnsNormally,
          reason: '${group.id.name} has no answer in the invalidate table',
        );
      }
    });

    // Walks the shipped group list by the predicate that decides the drain, so a
    // group that comes to hold a journal is covered the moment it does rather
    // than the day someone remembers this test. The drain runs *inside* this
    // delete -- `beforeDestroyingJournals` is the one reason the sweep memo never
    // answers -- so what it publishes is on disk and not in memory unless this
    // table says so.
    test('a delete that drains the journals forgets what the drain publishes', () {
      final draining = storageGroups.where((group) => group.destroysTransactionJournal(layout)).toList();
      expect(draining, isNotEmpty, reason: 'no group holds a journal, so this claim would assert nothing');
      for (final group in draining) {
        expect(
          storageDeleteInvalidationTargets(group: group, info: layout, targets: group.resolve(layout)),
          containsAll([
            // The drain's three destinations: an interrupted publication lands
            // in `active/`, an interrupted archive move lands in either store,
            // and a slot this build cannot read is filed in `quarantine/`.
            charaDetailRecordStorageLoaderProvider,
            charaDetailArchiveStorageLoaderProvider,
            charaDetailQuarantineCountProvider,
          ]),
          reason: '${group.id.name} drains the journals and nothing re-reads what that published',
        );
      }
    });

    // The negative control: a group whose delete forces no drain is not handed
    // the destinations, so the row above is not simply "invalidate everything".
    // Quarantine is the case worth stating -- it takes the same exclusive root
    // scope as `retired` and holds no journal, so the scope is not what decides.
    test('a root-scoped group that holds no journal keeps its own row', () {
      final group = groupOf(StorageGroupId.quarantine);
      expect(group.lockScope, StorageLockScope.exclusiveRoot);
      expect(group.destroysTransactionJournal(layout), isFalse);
      expect(targetsFor(StorageGroupId.quarantine, group.resolve(layout)), [charaDetailQuarantineCountProvider]);
    });

    // The other half of the same row. The provider table above makes the app
    // re-read the record the drain published; this makes the screen it published
    // onto re-measure itself. Dropping either leaves the user looking at a group
    // whose rows and whose size disagree.
    test('a delete that drains the journals re-measures where the drain publishes', () {
      final draining = storageGroups.where((group) => group.destroysTransactionJournal(layout)).toList();
      expect(draining, isNotEmpty, reason: 'no group holds a journal, so this claim would assert nothing');
      final destinations = [layout.charaDetailActiveDir, layout.charaDetailArchiveDir, layout.charaDetailQuarantineDir];
      for (final group in draining) {
        final targets = group.resolve(layout);
        final totals = storageDeleteTotalsTargets(group: group, info: layout, targets: targets);
        expect(
          totals.map((entity) => entity.path),
          containsAll(destinations.map((entity) => entity.path)),
          reason: '${group.id.name} drains the journals and its destinations keep their cached totals',
        );
        // Not vacuous: `DirectoryTotalsCache.invalidate` also drops a target's
        // ancestors and descendants, so a destination inside the group's own
        // targets would already have been dropped by naming the target alone.
        for (final destination in destinations) {
          for (final target in targets) {
            expect(
              PathEntity.context.equals(destination.path, target.path) ||
                  PathEntity.context.isWithin(destination.path, target.path) ||
                  PathEntity.context.isWithin(target.path, destination.path),
              isFalse,
              reason: '${destination.path} is reachable from ${target.path} without this row',
            );
          }
        }
      }
    });

    // The row path. The drain is decided by the group, not by what the request
    // named, so deleting one entry drains exactly as deleting the group does --
    // and then the request carries none of the places the drain changed. Written
    // with a singleton target for that reason: with the group's own roots as
    // targets this claim is satisfied by the request itself.
    test('a row delete that drains the journals re-measures every place the drain changed', () {
      final draining = storageGroups.where((group) => group.destroysTransactionJournal(layout)).toList();
      expect(draining, isNotEmpty, reason: 'no group holds a journal, so this claim would assert nothing');
      final changed = [
        layout.charaDetailActiveDir,
        layout.charaDetailArchiveDir,
        layout.charaDetailQuarantineDir,
        layout.charaDetailRetiredDir,
        ...layout.charaDetailTransactionJournalDirs,
      ];
      for (final group in draining) {
        final row = layout.charaDetailRetiredDir.filePath('old-entry.bin');
        expect(
          storageDeleteTotalsTargets(group: group, info: layout, targets: [row]).map((entity) => entity.path),
          containsAll(changed.map((entity) => entity.path)),
          reason: '${group.id.name}: a row delete drains and leaves those totals stale',
        );
      }
    });

    // The negative control for the row above: a group whose delete forces no
    // drain is told to forget its own targets and nothing else.
    test('a group that drains nothing re-measures only what it deleted', () {
      final group = groupOf(StorageGroupId.quarantine);
      final targets = group.resolve(layout);
      expect(
        storageDeleteTotalsTargets(group: group, info: layout, targets: targets).map((entity) => entity.path),
        targets.map((entity) => entity.path),
      );
    });

    // The serializer's fallback covers only metadata paths, so a second group
    // choosing this scope without extending the table would be serialised
    // against nothing. That is checked here rather than left to be discovered.
    test('metadata is still the only provider-serialized group', () {
      final serialized = storageGroups
          .where((group) => group.lockScope == StorageLockScope.exclusiveRootProviderSerialized)
          .map((group) => group.id);
      expect(serialized, [StorageGroupId.metadata]);
    });
  });

  group('one metadata file is one controller and many records', () {
    test('deleting one rating file drops every record\'s rating in that set', () async {
      final path = layout.charaDetailRatingDir.filePath('main.json');
      write(path, '{"title":"評価","data":{"rec-1":5.0,"rec-2":3.0,"rec-3":1.0}}');
      final scope = container();
      // Held open on purpose: without a listener the element would be disposed
      // between reads and the second read would be fresh whether or not anything
      // invalidated it, so the test would pass with the wiring removed.
      final subscription = scope.listen(charaDetailRecordRatingProvider('main'), (_, _) {});
      addTearDown(subscription.close);

      final before = await scope.read(charaDetailRecordRatingProvider('main').future);
      expect(before.data.keys, ['rec-1', 'rec-2', 'rec-3']);

      await runStorageDelete(
        scope.read(refBaseProvider),
        effects: storageDeleteEffects(scope),
        group: groupOf(StorageGroupId.metadata),
        request: StorageDeletePathsRequest([path]),
        silent: true,
      );

      expect(File(path.path).existsSync(), isFalse);
      final after = await scope.read(charaDetailRecordRatingProvider('main').future);
      // All three, not one: the file is the set, so nothing in it survives it.
      expect(after.data, isEmpty);
    });

    // The same claim with the controller serialiser taken out of the picture, so
    // the only thing that can make the ratings disappear is the invalidate table.
    //
    // Not redundant with the test above, and this was measured rather than
    // assumed: with the invalidate call removed from `runStorageDelete`, the test
    // above stayed **green**, because the serialiser's own pre-delete invalidate
    // happened to be answered by a rebuild that landed after the file went. A
    // claim about the invalidate table that the serialiser can satisfy is not a
    // claim about the table.
    test('the table alone empties the set, with the serialiser out of the way', () async {
      final path = layout.charaDetailRatingDir.filePath('main.json');
      write(path, '{"title":"評価","data":{"rec-1":5.0,"rec-2":3.0,"rec-3":1.0}}');
      final scope = container(serializer: passThrough);
      final subscription = scope.listen(charaDetailRecordRatingProvider('main'), (_, _) {});
      addTearDown(subscription.close);
      expect((await scope.read(charaDetailRecordRatingProvider('main').future)).data, hasLength(3));

      await runStorageDelete(
        scope.read(refBaseProvider),
        effects: storageDeleteEffects(scope),
        group: groupOf(StorageGroupId.metadata),
        request: StorageDeletePathsRequest([path]),
        silent: true,
      );

      expect((await scope.read(charaDetailRecordRatingProvider('main').future)).data, isEmpty);
    });

    test('the store list loses the key as well', () async {
      final path = layout.charaDetailRatingDir.filePath('main.json');
      write(path, '{"title":"評価","data":{"rec-1":5.0}}');
      final scope = container();
      final subscription = scope.listen(charaDetailRecordRatingStorageDataLoader, (_, _) {});
      addTearDown(subscription.close);

      expect((await scope.read(charaDetailRecordRatingStorageDataLoader.future)).map((e) => e.key), ['main']);

      await runStorageDelete(
        scope.read(refBaseProvider),
        effects: storageDeleteEffects(scope),
        group: groupOf(StorageGroupId.metadata),
        request: StorageDeletePathsRequest([path]),
        silent: true,
      );

      expect(await scope.read(charaDetailRecordRatingStorageDataLoader.future), isEmpty);
    });

    // Deleting one set must not disturb another: an invalidate that fired for
    // every key would satisfy the assertions above and be wrong.
    test('a second rating set is left alone', () async {
      final gone = layout.charaDetailRatingDir.filePath('main.json');
      final kept = layout.charaDetailRatingDir.filePath('other.json');
      write(gone, '{"title":"評価","data":{"rec-1":5.0}}');
      write(kept, '{"title":"別","data":{"rec-2":4.0}}');
      final scope = container();
      final subscription = scope.listen(charaDetailRecordRatingProvider('other'), (_, _) {});
      addTearDown(subscription.close);
      await scope.read(charaDetailRecordRatingProvider('other').future);

      await runStorageDelete(
        scope.read(refBaseProvider),
        effects: storageDeleteEffects(scope),
        group: groupOf(StorageGroupId.metadata),
        request: StorageDeletePathsRequest([gone]),
        silent: true,
      );

      final other = await scope.read(charaDetailRecordRatingProvider('other').future);
      expect(other.data, {'rec-2': 4.0});
      expect(File(kept.path).existsSync(), isTrue);
    });
  });

  group('the metadata delete is serialised through its owner, not through a lock', () {
    // The order is the whole of the guarantee. Dropping the controller *after*
    // the delete leaves it holding the file's contents, and its next write --
    // the user's next rating drag -- recreates the file this delete removed.
    test('the owning controller is dropped before the file is removed', () async {
      final path = layout.charaDetailRatingDir.filePath('main.json');
      write(path, '{"title":"評価","data":{"rec-1":5.0}}');
      final scope = container();
      final events = <String>[];
      final subscription = scope.listen(charaDetailRecordRatingProvider('main'), (_, _) {
        events.add('controller-rebuilt:${File(path.path).existsSync() ? 'file-present' : 'file-gone'}');
      });
      addTearDown(subscription.close);
      await scope.read(charaDetailRecordRatingProvider('main').future);
      // The initial build is itself a state change and reaches the listener, and
      // it necessarily happens while the file is there. Leaving it in the list
      // makes the assertion below true no matter what the code does -- measured:
      // with the serialiser's invalidate moved to *after* the delete, this test
      // stayed green until this line was added.
      events.clear();

      await runStorageDelete(
        scope.read(refBaseProvider),
        effects: storageDeleteEffects(scope),
        group: groupOf(StorageGroupId.metadata),
        request: StorageDeletePathsRequest([path]),
        silent: true,
      );

      // The first rebuild is the serialiser's, and it happens while the file is
      // still there. A wiring that only invalidated afterwards produces its first
      // event with the file already gone.
      expect(events, isNotEmpty);
      expect(events.first, 'controller-rebuilt:file-present');
    });
  });
}
