// The storage view's own rows, after a delete on it.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_tab_refresh_test.dart
//
// The provider-invalidate table names what the *rest of the app* remembers about a
// deleted path. It has no row for this view, and the list the completion condition
// is about — "削除後、一覧から消える" — is the tree the user is looking at when the
// delete happens. Before `refreshStorageTabAfterDelete` there was no invalidate of
// `storageTreeChildrenProvider`, `storageGroupTotalsProvider` or
// `storageSettingsBoxesProvider` anywhere in the repository, so every one of the
// twelve groups deleted into a screen that kept showing the old rows and the old
// size.
//
// The group used here is **temp**, and that choice is the isolation: the table
// answers it with the empty list and its lock scope is `unlocked`, so neither the table
// nor the metadata serialiser can produce the refresh these tests observe. What
// they observe can only come from the code under test.
//
// Two separately-falsifiable claims, because the refresh has two halves and each
// alone leaves the screen wrong:
//
//  1. **The tree re-lists.** Pinned by `storageTreeChildrenProvider`, which does
//     not go through the totals cache at all.
//  2. **The size is recomputed from the tree and not from the cache.** Pinned by
//     `storageGroupTotalsProvider`, which reads `DirectoryTotalsCache`. Dropping
//     the provider without dropping the cache rebuilds and redraws the same
//     number, so this claim is red for a defect the first one cannot see.
//
// Every provider is held open with a listener for the whole test. A
// non-`autoDispose` provider that nobody listens to would be recomputed on the
// next read regardless of whether anything invalidated it, and the assertions
// would then pass with the wiring deleted.
//
// WHAT THIS SUITE DOES NOT REACH. It builds no widgets: "the row left the table"
// is asserted at the provider the row watches, not at the pixels. It is
// VM/`dart:io` only — OPFS listing and `navigator.storage.estimate()` (which
// `originStorageUsageProvider` calls) are unreachable from here. And it says nothing about *which* rows a
// partial delete leaves; that is `storage_delete_action_test.dart`'s.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/settings_store_delete.dart';
import 'package:umacapture/src/core/storage/storage_delete.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/gui/storage_delete_action.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/localization.dart';
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
    tempRoot = Directory.systemTemp.createTempSync('uma_storage_tab_refresh');
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

  ProviderContainer container({StorageDeleteReport? storeOutcome}) {
    final result = ProviderContainer(
      overrides: [
        pathInfoProvider.overrideWithValue(layout),
        pathLayoutLoader.overrideWith((ref) async => layout),
        if (storeOutcome case final outcome?) settingsStoreDeleteProvider.overrideWithValue((_) async => outcome),
      ],
    );
    addTearDown(result.dispose);
    return result;
  }

  /// Writes [bytes] bytes into [path], creating its parents.
  FilePath seed(DirectoryPath directory, String name, int bytes) {
    final path = directory.filePath(name);
    final file = File(path.path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('x' * bytes);
    return path;
  }

  /// Subscribes to [provider] for the rest of the test and returns [scope].
  ///
  /// The subscription, not the read, is what makes the later read meaningful; see
  /// the file header.
  void hold(ProviderContainer scope, ProviderListenable<Object?> provider) {
    final subscription = scope.listen(provider, (_, _) {});
    addTearDown(subscription.close);
  }

  group('the view re-reads what a delete changed', () {
    test('the deleted file leaves the tree listing', () async {
      final file = seed(layout.tempDir, 'scratch.bin', 64);
      final scope = container();
      final node = (group: StorageGroupId.temp, path: null);
      hold(scope, storageTreeChildrenProvider(node));

      final before = await scope.read(storageTreeChildrenProvider(node).future);
      expect(before.map((listing) => listing.entity.path), [file.path]);

      await runStorageDelete(
        scope.read(containerRefProvider),
        effects: storageDeleteEffects(scope),
        group: groupOf(StorageGroupId.temp),
        request: StorageDeletePathsRequest([file]),
        silent: true,
      );

      expect(File(file.path).existsSync(), isFalse);
      final after = await scope.read(storageTreeChildrenProvider(node).future);
      expect(after.map((listing) => listing.entity.path), isEmpty);
    });

    test('the group total stops counting the deleted bytes', () async {
      final file = seed(layout.tempDir, 'scratch.bin', 64);
      final scope = container();
      hold(scope, storageGroupTotalsProvider(StorageGroupId.temp));

      final before = await scope.read(storageGroupTotalsProvider(StorageGroupId.temp).future);
      expect(before.knownBytes, 64);

      await runStorageDelete(
        scope.read(containerRefProvider),
        effects: storageDeleteEffects(scope),
        group: groupOf(StorageGroupId.temp),
        request: StorageDeletePathsRequest([file]),
        silent: true,
      );

      final after = await scope.read(storageGroupTotalsProvider(StorageGroupId.temp).future);
      expect(after.knownBytes, 0);
    });

    // The totals cache is what actually answers a directory's size, and it is
    // keyed by path rather than by group. Asserting it directly separates "the
    // provider was dropped" from "the number it would recompute changed".
    test('the totals cache no longer holds the directory the delete emptied', () async {
      final file = seed(layout.tempDir, 'scratch.bin', 64);
      final scope = container();
      hold(scope, storageGroupTotalsProvider(StorageGroupId.temp));
      await scope.read(storageGroupTotalsProvider(StorageGroupId.temp).future);
      expect(scope.read(directoryTotalsCacheProvider).peek(layout.tempDir)?.knownBytes, 64);

      await runStorageDelete(
        scope.read(containerRefProvider),
        effects: storageDeleteEffects(scope),
        group: groupOf(StorageGroupId.temp),
        request: StorageDeletePathsRequest([file]),
        silent: true,
      );

      // Dropped, not recomputed to zero: the cache is not asked again until a
      // provider asks it, and the point is that the stale entry is gone.
      final cached = scope.read(directoryTotalsCacheProvider).peek(layout.tempDir);
      expect(cached == null || cached.knownBytes == 0, isTrue);
    });

    // A delete of one group must not be reported as a change to another. An
    // implementation that cleared the whole cache for every delete would satisfy
    // the tests above and would throw away totals nothing had falsified -- and, in
    // the shape this suite is guarding, would hide a refresh that fired for the
    // wrong reason.
    test('a sibling group that the delete did not touch keeps its cached total', () async {
      final file = seed(layout.tempDir, 'scratch.bin', 64);
      seed(layout.charaDetailQuarantineDir, 'kept.bin', 32);
      final scope = container();
      hold(scope, storageGroupTotalsProvider(StorageGroupId.temp));
      hold(scope, storageGroupTotalsProvider(StorageGroupId.quarantine));
      await scope.read(storageGroupTotalsProvider(StorageGroupId.temp).future);
      await scope.read(storageGroupTotalsProvider(StorageGroupId.quarantine).future);

      await runStorageDelete(
        scope.read(containerRefProvider),
        effects: storageDeleteEffects(scope),
        group: groupOf(StorageGroupId.temp),
        request: StorageDeletePathsRequest([file]),
        silent: true,
      );

      expect(
        scope.read(directoryTotalsCacheProvider).peek(layout.charaDetailQuarantineDir)?.knownBytes,
        32,
        reason: 'the quarantine total was not falsified by a delete under temp',
      );
    });

    // The one delete whose reach is wider than its request. A group holding a
    // transaction journal takes its exclusion with a drain in front of it, and the
    // drain can finish a publication into `active/`, an archive move, or file a
    // slot it cannot read into `quarantine/` -- none of which the request names.
    // The cache drops a path, its ancestors and its descendants only, so those
    // three trees keep the size they had before the drain unless the delete says
    // otherwise. Asserted over every shipped group that answers the predicate, so
    // it is about the predicate and not about the group that answers it today.
    test('a delete that drains the journals drops the totals of what the drain publishes', () async {
      final draining = storageGroups.where((group) => group.destroysTransactionJournal(layout)).toList();
      expect(draining, isNotEmpty, reason: 'no group holds a journal, so this claim would assert nothing');
      for (final group in draining) {
        seed(layout.charaDetailActiveDir, 'published.bin', 16);
        seed(layout.charaDetailArchiveDir, 'moved.bin', 8);
        seed(layout.charaDetailQuarantineDir, 'unreadable.bin', 32);
        final scope = container();
        for (final id in [StorageGroupId.activeRecords, StorageGroupId.archivedRecords, StorageGroupId.quarantine]) {
          hold(scope, storageGroupTotalsProvider(id));
          await scope.read(storageGroupTotalsProvider(id).future);
        }
        final cache = scope.read(directoryTotalsCacheProvider);
        expect(cache.peek(layout.charaDetailActiveDir)?.knownBytes, 16);

        await runStorageDelete(
          scope.read(containerRefProvider),
          effects: storageDeleteEffects(scope),
          group: group,
          request: StorageDeletePathsRequest(group.resolve(layout)),
          silent: true,
        );

        for (final directory in [
          layout.charaDetailActiveDir,
          layout.charaDetailArchiveDir,
          layout.charaDetailQuarantineDir,
        ]) {
          expect(
            cache.peek(directory),
            isNull,
            reason: '${group.id.name} drains into ${directory.path} and its cached total survived the delete',
          );
        }
      }
    });

    // The same delete asked for one entry instead of the group. The drain is
    // decided by the group (`_rootMaintenanceReasonFor`), so it runs either way,
    // but now the request names one directory and the places the drain emptied --
    // both journals -- and the one it retires into are reached by nothing the
    // request carries. The group aggregate sums its roots, so a surviving journal
    // total counts a slot whose bytes the recovered record is also counting.
    test('a row delete that drains the journals drops the totals it emptied', () async {
      final draining = storageGroups.where((group) => group.destroysTransactionJournal(layout)).toList();
      expect(draining, isNotEmpty, reason: 'no group holds a journal, so this claim would assert nothing');
      for (final group in draining) {
        final row = seed(layout.charaDetailRetiredDir, 'old-entry.bin', 24);
        final emptied = [...layout.charaDetailTransactionJournalDirs, layout.charaDetailRetiredDir];
        for (final journal in layout.charaDetailTransactionJournalDirs) {
          seed(journal, 'slot.bin', 12);
        }
        final scope = container();
        hold(scope, storageGroupTotalsProvider(StorageGroupId.retired));
        await scope.read(storageGroupTotalsProvider(StorageGroupId.retired).future);
        final cache = scope.read(directoryTotalsCacheProvider);
        for (final directory in emptied) {
          expect(cache.peek(directory), isNotNull, reason: '${directory.path} was not cached to begin with');
        }

        await runStorageDelete(
          scope.read(containerRefProvider),
          effects: storageDeleteEffects(scope),
          group: group,
          request: StorageDeletePathsRequest([row]),
          silent: true,
        );

        for (final directory in emptied) {
          expect(
            cache.peek(directory),
            isNull,
            reason: '${group.id.name}: a row delete drained ${directory.path} and its cached total survived',
          );
        }
      }
    });
  });

  group('the settings delete refreshes the view as well', () {
    // Its request names no file it removes -- only the directory the stores live
    // in, for the claim -- so there is no per-path invalidate to make and the cache
    // is cleared instead. Windows sizes this group by the
    // directory the stores' files live in, so without the clear the group keeps
    // reporting the bytes of files that are gone.
    test('the settings total stops counting the removed store files', () async {
      final box = seed(layout.settingsDir, 'main.hive', 48);
      final scope = container(
        storeOutcome: const StorageDeleteReport(
          deleted: [StorageDeleteStoreSubject(name: 'main', labelKey: 'x')],
        ),
      );
      hold(scope, storageGroupTotalsProvider(StorageGroupId.settings));
      expect((await scope.read(storageGroupTotalsProvider(StorageGroupId.settings).future)).knownBytes, 48);

      // What the real removal does to the filesystem, without driving Hive: the
      // outcome is substituted above for the reason `storage_delete_action_test`
      // substitutes it, and this suite is about what the view does afterwards.
      File(box.path).deleteSync();

      await runStorageDelete(
        scope.read(containerRefProvider),
        effects: storageDeleteEffects(scope),
        group: groupOf(StorageGroupId.settings),
        request: StorageDeleteSettingsRequest(storeDirectories: [layout.settingsDir]),
        silent: true,
      );

      expect((await scope.read(storageGroupTotalsProvider(StorageGroupId.settings).future)).knownBytes, 0);
    });
  });
}
