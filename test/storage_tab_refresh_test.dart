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
// `originStorageUsageProvider` calls, and which this suite can only assert is in
// the list) are unreachable from here. And it says nothing about *which* rows a
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
import 'support/riverpod.dart';
import 'support/storage_view_sources.dart';

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
        if (storeOutcome case final outcome?) settingsStoreDeleteProvider.overrideWithValue(() async => outcome),
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
        scope.read(refBaseProvider),
        group: groupOf(StorageGroupId.temp),
        request: StorageDeletePathsRequest([file]),
        silent: true,
      );

      expect(File(file.path).existsSync(), isFalse);
      expect(await scope.read(storageTreeChildrenProvider(node).future), isEmpty);
    });

    test('the group total stops counting the deleted bytes', () async {
      final file = seed(layout.tempDir, 'scratch.bin', 64);
      final scope = container();
      hold(scope, storageGroupTotalsProvider(StorageGroupId.temp));

      final before = await scope.read(storageGroupTotalsProvider(StorageGroupId.temp).future);
      expect(before.knownBytes, 64);

      await runStorageDelete(
        scope.read(refBaseProvider),
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
        scope.read(refBaseProvider),
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
        scope.read(refBaseProvider),
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
  });

  group('the settings delete refreshes the view as well', () {
    // Its request names no path at all, so the per-path invalidate has nothing to
    // work with and the cache is cleared instead. Windows sizes this group by the
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
        scope.read(refBaseProvider),
        group: groupOf(StorageGroupId.settings),
        request: const StorageDeleteSettingsRequest(),
        silent: true,
      );

      expect((await scope.read(storageGroupTotalsProvider(StorageGroupId.settings).future)).knownBytes, 0);
    });
  });

  group('the list of the view\'s providers is counted, not remembered', () {
    // THE CLAIM THIS ROSTER KEEPS, IN ONE SENTENCE. *Every `FutureProvider` the
    // storage view owns that riverpod will not drop on its own has to be in
    // `storageTabContentProviders`, because nothing else drops it after a delete
    // or on re-entry.*
    //
    // `storageTabContentProviders` is a list, and a list is what goes stale when
    // the sixth provider is added next to the five it names. Nothing in Dart can
    // enumerate a library's top-level declarations at run time, so the
    // enumeration is done over the source -- but over the source of *the view*,
    // not of one file. Until this was widened it read `storage_tree.dart` alone,
    // with a line-anchored pattern, and `storage_file_preview.dart`'s two
    // providers were therefore not exempted by anything: they were never seen.
    // A guard that cannot see a declaration cannot report it missing, and moving
    // a provider one file across would have silenced it.
    //
    // Both halves of the sentence are read off the code. "The view owns it" is
    // the private import sub-library `StorageViewSources` computes; "riverpod
    // will not drop it" is `.autoDispose` on the declaration, so the exemption is
    // attached to the declaration itself rather than to a list of forgiven names
    // that the next `autoDispose` provider would have to be added to by hand.
    late StorageViewSources view;
    setUpAll(() {
      view = StorageViewSources.read();
    });

    test('every FutureProvider the view owns and riverpod will not drop is in the list', () {
      for (final provider in view.providers.where((provider) => !provider.autoDispose)) {
        expect(
          view.rosterContains(provider.name),
          isTrue,
          reason: '$provider is read from storage and nothing drops it, but it is not in the list',
        );
      }
    });

    // The other direction, so the exemption is a rule and not a hole: an
    // `autoDispose` provider must stay out. `storageTabContentProviders`' doc says
    // why the preview's two are outside (they are `autoDispose`, and a preview
    // covers the tree it opened over, so the delete button cannot be reached while
    // one is up); this is that reason made checkable.
    test('an autoDispose provider the view owns is left out of the list', () {
      for (final provider in view.providers.where((provider) => provider.autoDispose)) {
        expect(
          view.rosterContains(provider.name),
          isFalse,
          reason: '$provider is dropped by riverpod already; listing it would invalidate a live preview',
        );
      }
    });

    // NEGATIVE CONTROL 1 -- a scan that found nothing would make every assertion
    // above vacuously true, which is exactly how the file-anchored version stayed
    // green while missing two providers.
    test('the scan reaches the whole view rather than reporting nothing', () {
      expect(view.sources, isNotEmpty);
      expect(view.providers, isNotEmpty);
      expect(
        view.providers.map((provider) => provider.path).toSet().length,
        greaterThanOrEqualTo(2),
        reason: 'providers were found in one file only, so the scan has narrowed back to a single path',
      );
      expect(
        view.providers.where((provider) => provider.autoDispose),
        isNotEmpty,
        reason: 'no autoDispose provider was seen, so the exemption is being granted to nobody',
      );
    });

    // THE OWNERSHIP PREDICATE IS ITSELF GUARDED. "The view owns a file" means
    // nothing outside the view imports it, which is a property of how the code is
    // written: importing `storage_file_preview.dart` from one file outside the
    // view would drop it out of `sources`, and every assertion above would go on
    // passing over a smaller view. So the frontier is asserted too. It is built
    // from the import edges *leaving* the owned set -- the opposite direction to
    // the one that built the set -- so a file that lost ownership is still on it,
    // and has to be excused here by name or the suite fails.
    //
    // The excuses are keyed by path, carry their reason, and are checked for
    // staleness below, so this is not a list that can quietly outlive its
    // entries.
    const sharedWithTheRestOfTheApp = <String, String>{
      'lib/src/core/platform_controller.dart':
          'the capture backend and its config; the view reads whether a capture is running, which a '
          'delete does not change and which this view does not own',
      'lib/src/core/providers.dart':
          'the app-wide path layout; a delete cannot falsify where the directories are, '
          'and the whole app reads it, so it is not the view\'s to drop',
    };

    test('a provider-declaring file the view imports is either owned by the view or excused here', () {
      for (final path in view.providerDeclaringNeighbours) {
        expect(
          sharedWithTheRestOfTheApp,
          contains(path),
          reason:
              '$path declares providers and the view imports it, but the view does not own it. Either it is '
              'shared with the rest of the app -- say so here -- or something outside the view has started '
              'importing a file of the view, which shrinks every scan in this suite.',
        );
      }
      // A frontier that came back empty would excuse everything by having nothing
      // to excuse, which is how the scan would report a view of one file.
      expect(view.providerDeclaringNeighbours, isNotEmpty);
    });

    test('every excusal still names a file the view imports and does not own', () {
      for (final path in sharedWithTheRestOfTheApp.keys) {
        expect(
          view.providerDeclaringNeighbours,
          contains(path),
          reason: '$path is excused here but is no longer on the view\'s frontier; the excusal is stale',
        );
      }
    });

    // NEGATIVE CONTROL 2 -- deleting or renaming a provider the list names must
    // not be forgiven by the scan simply failing to match its declaration.
    test('the scan finds a declaration for every provider the list names', () {
      final declared = view.providers.map((provider) => provider.name).toSet();
      for (final name in view.rosterNames) {
        expect(declared, contains(name), reason: '$name is in the list but the scan found no declaration for it');
      }
    });
  });
}
