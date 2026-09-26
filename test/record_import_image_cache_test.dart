// The image caches a record import has to drop, driven through the import button.
//
//   .fvm/flutter_sdk/bin/flutter test test/record_import_image_cache_test.dart
//
// An import publishes over a record id that is already stored, under the same path, so a picture
// of that record decoded before the import goes on being shown unless the import drops it. Which
// ids it drops is decided by the button's own loop: it gathers the ids each zip committed and
// hands them to `applyRecordImportCompletion`. That gathering is what this suite drives. Calling
// the completion with a set the test wrote would stay green if the button handed over nothing, or
// every id the zip carried.
//
// The zip carries two records. `rec` is written over the stored `rec` with a blue picture. The
// other, `refused`, is refused as a duplicate: its contents are the stored `other`'s, so the store
// keeps `active/refused` as it was. To make "dropped" observable on `refused` too, its picture is
// rewritten on disk behind the cache before the import, as nothing in the app would do: the tile
// keeps painting the red it decoded unless something drops it, and then it repaints blue.
//
// Runs on the VM, so it reaches the desktop `FileImage` path only; the web byte cache is the same
// `evictRecordImagesWithin` call and is not driven here. The picker is `FakeFilePicker`.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/chara_detail/import_button.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/file_picker.dart';
import 'support/localization.dart';
import 'support/record_image_fixture.dart';
import 'support/records.dart';
import 'support/riverpod.dart';
import 'support/settling.dart';

void main() {
  setUpAll(() {
    initializeMappers();
    loadAppTranslations();
  });

  late Directory tempRoot;
  late PathInfo layout;
  late FakeFilePicker picker;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_record_import_images');
    final root = DirectoryPath(tempRoot.path);
    layout = PathInfo(
      documentDir: root,
      supportDir: root,
      executableDir: root / 'exe',
      downloadDir: root / 'dl',
      dataRoot: root,
    );
    picker = installFakeFilePicker();
    imageCache.clear();
  });

  tearDown(() {
    imageCache.clear();
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  List<int> recordJson(CharaDetailRecord record) =>
      utf8.encode(const JsonEncoder.withIndent('    ').convert(record.toMap()));

  /// Stores [record] under `active/` with a red picture and answers the picture's path.
  FilePath store(CharaDetailRecord record) {
    final directory = layout.charaDetailActiveDir / record.id;
    File('${directory.path}/record.json')
      ..createSync(recursive: true)
      ..writeAsBytesSync(recordJson(record));
    return writeImage(directory.filePath('skill.png'), redPng);
  }

  /// A zip holding [records], each with a blue picture, as an export lays it out.
  String writeZip(List<CharaDetailRecord> records) {
    final archive = Archive();
    for (final record in records) {
      final json = recordJson(record);
      archive.addFile(ArchiveFile('chara_detail/active/${record.id}/record.json', json.length, json));
      archive.addFile(ArchiveFile('chara_detail/active/${record.id}/skill.png', bluePng.length, bluePng));
    }
    final path = '${tempRoot.path}${Platform.pathSeparator}import.zip';
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
    return path;
  }

  testWidgets('an import drops the pictures of the records it wrote, and none of the ones it refused', (tester) async {
    final rec = store(makeRecord(id: 'rec', card: 1));
    final refused = store(makeRecord(id: 'refused', card: 2));
    store(makeRecord(id: 'other', card: 3));
    picker.answerWithPaths([
      writeZip([makeRecord(id: 'rec', card: 1), makeRecord(id: 'refused', card: 3)]),
    ]);

    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => layout),
        moduleVersionLoader.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    final toasts = <ToastData>[];
    final subscription = container.listen<AsyncValue<ToastData>>(
      plainToastEventProvider,
      (_, current) => current.whenData(toasts.add),
    );
    addTearDown(subscription.close);
    // Loaded, so the import asks the store the duplicate question that refuses `refused`.
    await tester.runAsync(() => container.read(charaDetailRecordStorageLoaderProvider.future));

    await pumpWithContainer(
      tester,
      container,
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const CharaDetailImportButton(),
              recordImageTile('rec', rec),
              recordImageTile('refused', refused),
            ],
          ),
        ),
      ),
    );
    await settleUntilPainted(tester, ['rec', 'refused']);
    final red = paintedImageOf(tester, 'rec');
    expect(cachedFileImage(rec), isTrue, reason: 'the premise: the red PNG of rec was decoded into the cache');
    expect(cachedFileImage(refused), isTrue, reason: 'the premise: the red PNG of refused was decoded into the cache');
    expect(await paintedPixelOf(tester, 'rec'), '#ff0000');
    expect(await paintedPixelOf(tester, 'refused'), '#ff0000');
    writeImage(refused, bluePng);

    await tester.runAsync(() async {
      await tester.tap(find.byType(IconButton));
    });
    var started = false;
    await settleUntil(tester, () {
      final spinning = find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      // A toast that has landed stays landed; the spinner is a transient a slow poll can step over.
      started |= spinning || toasts.isNotEmpty;
      return started && !spinning;
    }, describe: 'the import to start and then to finish');
    await settleUntilRepainted(tester, 'rec', red);
    await pumpRecordImageWindow(tester);

    expect(
      File(layout.charaDetailActiveDir.filePath('rec/skill.png').path).readAsBytesSync(),
      bluePng,
      reason: 'the premise: the import wrote over rec',
    );
    expect(
      File('${(layout.charaDetailActiveDir / 'refused').path}/record.json').readAsBytesSync(),
      recordJson(makeRecord(id: 'refused', card: 2)),
      reason: 'the premise: the refused record was left as stored',
    );
    expect(await paintedPixelOf(tester, 'rec'), '#0000ff', reason: 'the written record still shows its old picture');
    expect(
      await paintedPixelOf(tester, 'refused'),
      '#ff0000',
      reason: 'a record the import refused had its cached picture dropped',
    );
  });
}
