// The image caches an enhancement merge has to drop.
//
//   .fvm/flutter_sdk/bin/flutter test test/enhancement_merge_image_cache_test.dart
//
// A merge replaces trees under paths that do not change: the survivor is published over the older
// record's directory, a cross-store merge removes the older record's own directory, and the
// retired record's tree is stripped last. A picture decoded from any of them is cached by its
// path, so a tile still open on it goes on painting the old pixels unless the merge drops them.
//
// Driven through `EnhancementMerge.merge` with the declaration the app's merge action makes, on
// the pre/post pair the on-disk merge suites share: the enhanced side is the retired record, so
// its tree is the survivor's content. Runs on the VM, so it reaches the desktop `FileImage` path
// only.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/enhancement_merge.dart';
import 'package:umacapture/src/core/fs/web_record_write_transaction.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';

import 'support/enhancement_merge_scratch.dart';
import 'support/localization.dart';
import 'support/record_image_fixture.dart';

void main() {
  setUpAll(() {
    initializeMappers();
    loadAppTranslations();
  });

  late Directory tempRoot;
  late PathInfo info;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_merge_images');
    info = mergeScratchPathInfo(DirectoryPath(tempRoot.path));
    imageCache.clear();
  });

  tearDown(() {
    imageCache.clear();
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  /// Seeds the pair: `older` (pre-enhancement, red picture) and `retired` (enhanced, blue picture).
  ({FilePath older, FilePath retired}) seedPair({
    required DirectoryPath olderStore,
    required DirectoryPath retiredStore,
  }) {
    writeRecord(olderStore, preRecord('older'));
    writeRecord(retiredStore, postRecord('retired'));
    return (
      older: writeImage((olderStore / 'older').filePath('skill.png'), redPng),
      retired: writeImage((retiredStore / 'retired').filePath('skill.png'), bluePng),
    );
  }

  Future<ProviderContainer> load(WidgetTester tester, {Future<void> Function(PathEntity entry)? deleteEntry}) async {
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await loadedMergeContainer(
        info: info,
        overrides: [
          if (deleteEntry != null)
            enhancementMergeSeamsProvider.overrideWithValue((
              transaction: WebRecordWriteTransaction(),
              deleteEntry: deleteEntry,
              writeMetadata: (file, contents) => file.writeAsString(contents),
            )),
        ],
      );
    });
    return container;
  }

  testWidgets('a tile open on the older record paints the survivor after a merge', (tester) async {
    final paths = seedPair(olderStore: info.charaDetailActiveDir, retiredStore: info.charaDetailActiveDir);
    final container = await load(tester);
    await tester.pumpWidget(recordImageScreen([recordImageTile('older', paths.older)]));
    await settleUntilPainted(tester, ['older']);
    final red = paintedImageOf(tester, 'older');
    expect(await paintedPixelOf(tester, 'older'), '#ff0000', reason: 'the premise: the older red picture is shown');

    final result = await tester.runAsync(() => mergeOne(container));

    expect(result?.outcome, EnhancementMergeOutcome.merged);
    expect(File(paths.older.path).readAsBytesSync(), bluePng, reason: 'the premise: the survivor carries blue');
    await settleUntilRepainted(tester, 'older', red);
    expect(await paintedPixelOf(tester, 'older'), '#0000ff', reason: 'the open tile still paints the replaced picture');
  });

  testWidgets('a cross-store merge drops the older record\'s old place', (tester) async {
    // The enhanced side is archived, so the survivor is published into `archive/` and the older
    // record's directory under `active/` is removed.
    final paths = seedPair(olderStore: info.charaDetailActiveDir, retiredStore: info.charaDetailArchiveDir);
    final container = await load(tester);
    await tester.pumpWidget(recordImageScreen([recordImageTile('older', paths.older)]));
    await settleUntilPainted(tester, ['older']);
    expect(cachedFileImage(paths.older), isTrue, reason: 'the premise: the red PNG of older was decoded');

    final result = await tester.runAsync(() => mergeOne(container));

    expect(result?.outcome, EnhancementMergeOutcome.merged);
    expect(File(paths.older.path).existsSync(), isFalse, reason: 'the premise: active/older was removed');
    expect(cachedFileImage(paths.older), isFalse, reason: 'the older record\'s old place is still cached');
    await settleUntilUnavailable(tester, id: 'older');
    expect(find.text(recordImageUnavailable), findsOneWidget, reason: 'the tile on the old place did not re-read');
  });

  testWidgets('the retired record is dropped after its tree is stripped, not before', (tester) async {
    // The merge is parked at the strip's first delete, before it removes anything, and the tiles are
    // left to settle there: a drop of the retired record made that early is refilled from the files
    // the strip has not yet deleted.
    final paths = seedPair(olderStore: info.charaDetailActiveDir, retiredStore: info.charaDetailActiveDir);
    // Made on the real event loop, which the merge runs on: a future made in the test body's fake
    // zone delivers its completion only when the fake clock is pumped.
    late Completer<void> parked;
    late Completer<void> release;
    await tester.runAsync(() async {
      parked = Completer<void>();
      release = Completer<void>();
    });
    final container = await load(
      tester,
      deleteEntry: (entry) async {
        if (!parked.isCompleted) {
          parked.complete();
          await release.future;
        }
        await entry.delete(recursive: true, emptyOk: true);
      },
    );
    await tester.pumpWidget(recordImageScreen([recordImageTile('retired', paths.retired)]));
    await settleUntilPainted(tester, ['retired']);
    expect(cachedFileImage(paths.retired), isTrue, reason: 'the premise: the PNG of retired was decoded');

    late Future<EnhancementMergeResult> merging;
    await tester.runAsync(() async {
      merging = mergeOne(container);
      await parked.future;
    });
    await pumpRecordImageWindow(tester);
    expect(File(paths.retired.path).existsSync(), isTrue, reason: 'the premise: parked before the strip');
    expect(cachedFileImage(paths.retired), isTrue, reason: 'the premise: the retired picture is cached while parked');

    release.complete();
    final result = await tester.runAsync(() => merging);

    expect(result?.outcome, EnhancementMergeOutcome.merged);
    expect(File(paths.retired.path).existsSync(), isFalse, reason: 'the premise: the strip deleted the picture');
    expect(cachedFileImage(paths.retired), isFalse, reason: 'the stripped picture is still cached');
    await settleUntilUnavailable(tester, id: 'retired');
    expect(find.text(recordImageUnavailable), findsOneWidget, reason: 'the tile on the retired record did not re-read');
  });
}
