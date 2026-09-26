// The image caches an archive has to drop.
//
//   .fvm/flutter_sdk/bin/flutter test test/record_archive_image_cache_test.dart
//
// An archive moves `active/<id>` to `archive/<id>`. A picture decoded from the directory it left
// is cached by that path, so a tile still open on it goes on painting a file that is no longer
// there unless the archive drops it. The batch here holds two ids: `moved`, which the executor
// moves, and `stuck`, which it refuses because `archive/stuck` already exists. Only the moved id
// is in scope; `stuck` is still where it was, so its cached picture is correct and must stay.
//
// Driven through `CharaArchiveController.archive` with the declaration both archive dialogs make.
// Runs on the VM, so it reaches the desktop `FileImage` path only.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/version_check.dart';

import 'support/localization.dart';
import 'support/record_image_fixture.dart';
import 'support/record_write_effects_fixture.dart';
import 'support/records.dart';

void main() {
  setUpAll(() {
    initializeMappers();
    loadAppTranslations();
  });

  late Directory tempRoot;
  late PathInfo layout;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_record_archive_images');
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

  /// Stores a record under `active/` with a red picture and answers the picture's path.
  FilePath seedRecord(String id, {required int card}) {
    final directory = layout.charaDetailActiveDir / id;
    File('${directory.path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent('    ').convert(makeRecord(id: id, card: card).toMap()));
    return writeImage(directory.filePath('skill.png'), redPng);
  }

  testWidgets('an archive drops the cached pictures of the records it moved, and of no other', (tester) async {
    final moved = seedRecord('moved', card: 1);
    final stuck = seedRecord('stuck', card: 2);
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => layout),
        pathInfoProvider.overrideWithValue(layout),
        pathLayoutLoader.overrideWith((ref) async => layout),
        moduleVersionLoader.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      await container.read(charaDetailRecordStorageLoaderProvider.future);
      await container.read(charaDetailArchiveStorageLoaderProvider.future);
    });
    // Made after the stores loaded, so the archive store does not list it: the executor refuses a
    // move onto a destination that exists, which is the failed id of this batch.
    Directory((layout.charaDetailArchiveDir / 'stuck').path).createSync(recursive: true);
    final controller = container.read(charaArchiveControllerProvider.notifier);
    controller.debugRecoveryGate = RecordRecoveryGate(
      mutationLock: RecordMutationLock((name, mode, action) => action()),
    );

    await tester.pumpWidget(recordImageScreen([recordImageTile('moved', moved), recordImageTile('stuck', stuck)]));
    await settleUntilPainted(tester, ['moved', 'stuck']);
    expect(cachedFileImage(moved), isTrue, reason: 'the premise: the red PNG of moved was decoded into the cache');
    expect(cachedFileImage(stuck), isTrue, reason: 'the premise: the red PNG of stuck was decoded into the cache');

    await tester.runAsync(
      () => controller.archive(['moved', 'stuck'], ArchiveImageOption.none, effects: archiveEffects(container)),
    );

    expect(Directory((layout.charaDetailActiveDir / 'moved').path).existsSync(), isFalse, reason: 'moved did not move');
    expect(File(stuck.path).existsSync(), isTrue, reason: 'the premise: stuck failed and stayed in active/');
    expect(cachedFileImage(moved), isFalse, reason: 'the moved record\'s picture is still cached');
    expect(cachedFileImage(stuck), isTrue, reason: 'a picture whose archive failed was dropped anyway');

    await settleUntilUnavailable(tester, id: 'moved');
    expect(find.text(recordImageUnavailable), findsOneWidget, reason: 'the tile on the moved record did not re-read');
    expect(await paintedPixelOf(tester, 'stuck'), '#ff0000');
  });
}
