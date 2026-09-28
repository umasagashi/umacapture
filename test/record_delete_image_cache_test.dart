// The image caches an ordinary record delete has to drop.
//
//   .fvm/flutter_sdk/bin/flutter test test/record_delete_image_cache_test.dart
//
// The record dialogs (`delete_record_dialog.dart`) delete through
// `CharaDetailRecordMutator.deleteAsync` (one record) and `deleteAllAsync` (a
// selection), on the active or the archive store. Those are four entries and not
// one: the single delete goes through `runForRecord` and the bulk one through
// `runPerRecord`, in two separate stores, so each applies the declaration on its
// own and each is driven here from its own entry. A test of the bulk path alone
// stays green when only the single path forgets.
//
// Each case shows the record's picture, deletes the record, and asserts before
// the next frame that the decoded picture has left the cache, and after it that
// the tile left open re-read its path and now shows it cannot be displayed. A
// picture in another record stays cached: dropping everything would pass the
// first half.
//
// The last case is the scope's other edge: an id whose delete failed keeps its
// directory on disk, so its cached picture is still correct and must stay.
//
// Runs on the VM, so it reaches the desktop `FileImage` path only; the web byte
// cache is the same `evictRecordImagesWithin` call and is not driven here.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/version_check.dart';

import 'support/record_image_fixture.dart';
import 'support/record_write_effects_fixture.dart';
import 'support/records.dart';

enum _Store { active, archive }

enum _Entry { single, bulk }

void main() {
  setUpAll(initializeMappers);

  late Directory tempRoot;
  late PathInfo layout;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_record_delete_images');
    final root = DirectoryPath(tempRoot.path);
    layout = PathInfo(
      documentDir: root,
      supportDir: root,
      executableDir: root / 'exe',
      downloadDir: root / 'dl',
      dataRoot: root,
    );
    imageCache.clear();
  });

  tearDown(() {
    imageCache.clear();
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  DirectoryPath storeDir(_Store store) =>
      store == _Store.active ? layout.charaDetailActiveDir : layout.charaDetailArchiveDir;

  /// Writes a record with a picture under [store] and answers the picture's path.
  FilePath seedRecord(_Store store, String id, {required int card}) {
    final directory = storeDir(store) / id;
    File('${directory.path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent('    ').convert(makeRecord(id: id, card: card).toMap()));
    return writeImage(directory.filePath('skill.png'), redPng);
  }

  /// A container whose stores have both finished loading what is on disk now.
  Future<ProviderContainer> loadedContainer(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => layout),
        moduleVersionLoader.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      await container.read(charaDetailRecordStorageLoaderProvider.future);
      await container.read(charaDetailArchiveStorageLoaderProvider.future);
    });
    return container;
  }

  CharaDetailRecordMutator storeOf(ProviderContainer container, _Store store) => store == _Store.active
      ? container.read(charaDetailRecordStorageLoaderProvider.notifier)
      : container.read(charaDetailArchiveStorageLoaderProvider.notifier);

  Future<RecordDeleteResult> delete(ProviderContainer container, _Store store, _Entry entry, List<String> ids) {
    final mutator = storeOf(container, store);
    final effects = recordDeleteEffects(container);
    return switch (entry) {
      _Entry.single => mutator.deleteAsync(ids.single, effects: effects),
      _Entry.bulk => mutator.deleteAllAsync(ids, effects: effects),
    };
  }

  for (final store in _Store.values) {
    for (final entry in _Entry.values) {
      testWidgets('a ${entry.name} delete of a ${store.name} record drops its cached images', (tester) async {
        final shown = seedRecord(store, 'rec', card: 1);
        final untouched = seedRecord(store, 'rec-2', card: 2);
        final container = await loadedContainer(tester);

        await tester.pumpWidget(
          recordImageScreen([recordImageTile('shown', shown), recordImageTile('other', untouched)]),
        );
        await settleUntilPainted(tester, ['shown', 'other']);
        expect(find.text(recordImageUnavailable), findsNothing, reason: 'the seeded PNG never decoded');
        expect(cachedFileImage(shown), isTrue, reason: 'the premise of this test — nothing was cached to drop');
        expect(cachedFileImage(untouched), isTrue);

        final result = await tester.runAsync(() => delete(container, store, entry, ['rec']));
        expect(result?.succeeded, {'rec'}, reason: 'the delete itself did not run');
        expect(Directory(shown.parent.path).existsSync(), isFalse);

        // Before any frame: the drop is the delete's own doing, not a rebuild's.
        expect(cachedFileImage(shown), isFalse, reason: 'the deleted record\'s picture is still cached');
        expect(cachedFileImage(untouched), isTrue, reason: 'a picture the delete did not touch was dropped');

        await settleUntilUnavailable(tester, id: 'shown');
        expect(
          find.text(recordImageUnavailable),
          findsOneWidget,
          reason: 'the tile left open went on showing the deleted picture',
        );
      });
    }
  }

  testWidgets('a bulk delete keeps the cached image of an id it failed to delete', (tester) async {
    final deleted = seedRecord(_Store.active, 'rec', card: 1);
    final container = await loadedContainer(tester);
    // On disk but not in the loaded list: the store cannot delete it, and its
    // directory, picture included, stays where it was.
    final kept = seedRecord(_Store.active, 'stranger', card: 2);

    await tester.pumpWidget(recordImageScreen([recordImageTile('deleted', deleted), recordImageTile('kept', kept)]));
    await settleUntilPainted(tester, ['deleted', 'kept']);
    expect(cachedFileImage(deleted), isTrue, reason: 'the premise of this test — nothing was cached to drop');
    expect(cachedFileImage(kept), isTrue);

    final result = await tester.runAsync(() => delete(container, _Store.active, _Entry.bulk, ['rec', 'stranger']));
    expect(result?.succeeded, {'rec'});
    expect(result?.failed, {'stranger'});
    expect(File(kept.path).existsSync(), isTrue);

    expect(cachedFileImage(deleted), isFalse, reason: 'the deleted record\'s picture is still cached');
    expect(cachedFileImage(kept), isTrue, reason: 'a picture whose delete failed was dropped anyway');
  });
}
