// What a record's arrival, or its re-recognition, does to the pictures cached
// for its directory.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_record_arrival_image_test.dart
//
// Re-adding or re-importing a known id replaces that record's files in place
// (`duplicateCharaIdIn`), so an arrival is a write under a directory whose
// pictures may already be cached and on screen. Both arrival paths --
// `addFromFile` (the desktop capture listener) and `addFromFileAsync` (the web
// harvest and video import) -- apply the declaration they are given to
// `<store>/<id>`; one test per path. A re-recognition rewrites `active/<id>` the
// same way and announces it through the regeneration controller's `updated`.
//
// Cache membership is read right after the arrival and before any `pump`, as in
// `record_write_effects_test.dart`: a pump lets the mounted picture re-read its
// file and refill the entry. Pixels are read after settling.
//
// MATERIAL. One stored record `rec` (card 1) with a real 2x2 PNG `skill.png`,
// `#ff0000`, shown by one unbounded `RecordImage`. The arrival writes
// `#0000ff` over the same path and announces `rec` again.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/version_check.dart';

import 'support/hive.dart';
import 'support/record_image_fixture.dart';
import 'support/record_write_effects_fixture.dart';
import 'support/records.dart';

void main() {
  setUpAll(initializeMappers);
  // The capture merge reads the auto-copy setting, which is Hive-backed.
  useHiveForTest(['settings']);

  late Directory tempRoot;
  late PathInfo layout;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_arrival_image');
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
    imageCache.clear();
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  void writeRecord(CharaDetailRecord record) {
    File('${(layout.charaDetailActiveDir / record.id).path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(record.toMap()));
  }

  /// Boots the real store over a tree holding `rec` and shows its picture.
  Future<({ProviderContainer scope, CharaDetailRecordStorage store, FilePath skill})> boot(WidgetTester tester) async {
    writeRecord(makeRecord(id: 'rec', card: 1));
    final skill = writeImage((layout.charaDetailActiveDir / 'rec').filePath('skill.png'), redPng);
    // Created and loaded on the real event loop: the store's load is file io,
    // which a `testWidgets` body's fake clock never completes.
    final scope = (await tester.runAsync(() async {
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
      await scope.read(charaDetailArchiveStorageLoaderProvider.future);
      return scope;
    }))!;
    await tester.pumpWidget(recordImageScreen([recordImageTile('rec', skill)]));
    await settleUntilPainted(tester, ['rec']);
    expect(cachedFileImage(skill), isTrue, reason: 'the premise: the red PNG was decoded into the cache');
    expect(await paintedPixelOf(tester, 'rec'), '#ff0000', reason: 'the premise: the red PNG is on screen');
    return (scope: scope, store: scope.read(charaDetailRecordStorageLoaderProvider.notifier), skill: skill);
  }

  testWidgets('an arriving record under a known id drops its cached images', (tester) async {
    final (:scope, :store, :skill) = await boot(tester);
    final red = paintedImageOf(tester, 'rec');

    writeImage(skill, bluePng);
    // Synchronous, but the merge it runs starts file io and timers, which belong
    // on the real event loop rather than the fake clock.
    await tester.runAsync(() async => store.addFromFile('rec', effects: arrivalEffects(scope)));

    expect(cachedFileImage(skill), isFalse);
    await settleUntilRepainted(tester, 'rec', red);
    expect(await paintedPixelOf(tester, 'rec'), '#0000ff');
  });

  testWidgets('an arriving record under a known id drops its cached images, asynchronously', (tester) async {
    final (:scope, :store, :skill) = await boot(tester);
    final red = paintedImageOf(tester, 'rec');

    writeImage(skill, bluePng);
    await tester.runAsync(() => store.addFromFileAsync('rec', effects: arrivalEffects(scope)));

    expect(cachedFileImage(skill), isFalse);
    await settleUntilRepainted(tester, 'rec', red);
    expect(await paintedPixelOf(tester, 'rec'), '#0000ff');
  });

  testWidgets('a regenerated record drops its cached images', (tester) async {
    final (:scope, store: _, :skill) = await boot(tester);
    final red = paintedImageOf(tester, 'rec');
    final controller = scope.read(charaDetailRecordRegenerationControllerProvider.notifier);

    writeImage(skill, bluePng);
    // The reload after the drop is file io on another isolate.
    await tester.runAsync(() => controller.updated('rec', effects: regenerationEffects(scope)));

    expect(cachedFileImage(skill), isFalse);
    await settleUntilRepainted(tester, 'rec', red);
    expect(await paintedPixelOf(tester, 'rec'), '#0000ff');
  });
}
