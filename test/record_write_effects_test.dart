// What `RecordImageDrop.apply` and `RecordTotalsRemeasure.apply` do to each
// thing the app remembers about a record's files, applied directly rather than
// through a writer's seam.
//
//   .fvm/flutter_sdk/bin/flutter test test/record_write_effects_test.dart
//
// A write that replaces the bytes under a record's directory keeps every path,
// so everything keyed by path keeps answering with the old contents unless the
// write's declaration drops it. One test per cache:
//
//   * the global `ImageCache` entry of an unbounded desktop image (`FileImage`);
//   * the byte LRU a bounded image resolves through;
//   * the picture already on screen, which no cache eviction reaches;
//   * the four preview providers memoized per record directory;
//   * the storage view's measured totals, in each of the three shapes.
//
// Cache membership is read right after `apply` and before any `pump`: a pump
// lets a mounted picture re-read its file, which would refill the entry and hide
// whether it was dropped. Pixels are read after settling, off the `RawImage`
// actually painted.
//
// MATERIAL. Every picture is a real 2x2 PNG (`solidPng`): `#ff0000` first, then
// `#0000ff` written over it under the same path. Geometry is three tab jsons
// whose intersection spans (0,0)..(width,100); predictions are
// `prediction.json` with one or two `skill_tab` entries. Totals are warmed over
// a tree holding exactly one 64-byte file.
//
// WHAT THIS SUITE DOES NOT REACH. It runs on the VM, so the unbounded image
// resolves through `FileImage` and never through a browser's OPFS read; no
// writer's seam is driven here (each seam's own suite does that); and the
// binding-free failure of the pixel stage is `record_write_effects_unbound_test.dart`.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/directory_totals.dart';
import 'package:umacapture/src/core/storage/record_write_effects.dart';
import 'package:umacapture/src/gui/chara_detail/preview_dialog.dart';
import 'package:umacapture/src/gui/record_image.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/record_image_fixture.dart';

late Directory _tempRoot;
late PathInfo _layout;

DirectoryPath _recordDir(String id) => recordDirOfId(_layout, RecordSource.active, id);

FilePath _skillOf(String id) => _recordDir(id).filePath('skill.png');

RecordImageScope _scopeOf(List<String> ids) =>
    RecordImageScope(info: _layout, changed: [for (final id in ids) _recordDir(id).path]);

ProviderContainer _container() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

String _intersectionJson(int width, int height) => jsonEncode({
  'intersection': {
    'top_left': {
      'x': 0,
      'y': 0,
      'anchor': {'h': 'ScreenStart', 'v': 'ScreenStart'},
    },
    'bottom_right': {
      'x': width,
      'y': height,
      'anchor': {'h': 'ScreenStart', 'v': 'ScreenStart'},
    },
  },
});

void _writeGeometry(DirectoryPath recordDir, int width) {
  for (final tab in ['skill', 'factor', 'campaign']) {
    File(recordDir.filePath('$tab.json').path)
      ..createSync(recursive: true)
      ..writeAsStringSync(_intersectionJson(width, 100));
  }
}

String _predictionJson(int skillEntries) {
  final entry = {
    'model': 'm',
    'rect': jsonDecode(_intersectionJson(10, 10))['intersection'],
    'prediction': {'confidence': 0.9, 'label': 'a'},
  };
  return jsonEncode({
    'status_header': [],
    'skill_tab': [for (var i = 0; i < skillEntries; i++) entry],
    'factor_tab': [],
    'campaign_tab': [],
  });
}

/// Keeps `provider` alive the way a watching preview does, and answers its first value.
Future<T> _hold<T>(ProviderContainer container, FutureProvider<T> provider) async {
  container.listen(provider, (_, _) {});
  return container.read(provider.future);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeMappers);

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_record_write_effects');
    final root = DirectoryPath(_tempRoot.path);
    _layout = PathInfo(
      documentDir: root,
      supportDir: root,
      executableDir: root / 'exe',
      downloadDir: root / 'dl',
      dataRoot: root,
    );
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  tearDown(() {
    imageCache.clear();
    imageCache.clearLiveImages();
    for (final path in RecordImageByteCache.instance.paths.toList()) {
      RecordImageByteCache.instance.remove(path);
    }
    if (_tempRoot.existsSync()) {
      _tempRoot.deleteSync(recursive: true);
    }
  });

  group('the pixel caches and the picture on screen', () {
    testWidgets('an unbounded image drops its FileImage entry', (tester) async {
      final path = writeImage(_skillOf('rec-1'), redPng);
      final ref = _container().read(containerRefProvider);
      await tester.pumpWidget(recordImageScreen([recordImageTile('rec-1', path)]));
      await settleUntilPainted(tester, ['rec-1']);
      expect(cachedFileImage(path), isTrue, reason: 'the premise: the red PNG was decoded into the cache');

      writeImage(path, bluePng);
      RecordImageEffect.drop(ref).apply(_scopeOf(['rec-1']));

      expect(cachedFileImage(path), isFalse);
    });

    testWidgets('a bounded image drops its bytes', (tester) async {
      final path = writeImage(_skillOf('rec-1'), redPng);
      final ref = _container().read(containerRefProvider);
      await tester.pumpWidget(recordImageScreen([recordImageTile('rec-1', path, maxDecodePixels: const Size(64, 64))]));
      await settleUntilPainted(tester, ['rec-1']);
      expect(RecordImageByteCache.instance.paths.contains(path.path), isTrue, reason: 'the premise: bytes held');

      writeImage(path, bluePng);
      RecordImageEffect.drop(ref).apply(_scopeOf(['rec-1']));

      expect(RecordImageByteCache.instance.paths.contains(path.path), isFalse);
    });

    testWidgets('an image on screen draws the rewritten pixels', (tester) async {
      final path = writeImage(_skillOf('rec-1'), redPng);
      final ref = _container().read(containerRefProvider);
      await tester.pumpWidget(recordImageScreen([recordImageTile('rec-1', path)]));
      await settleUntilPainted(tester, ['rec-1']);
      final red = paintedImageOf(tester, 'rec-1');
      expect(await paintedPixelOf(tester, 'rec-1'), '#ff0000', reason: 'the premise: red is on screen');

      writeImage(path, bluePng);
      RecordImageEffect.drop(ref).apply(_scopeOf(['rec-1']));
      // The cache side, measured before the refresh can re-read the file.
      expect(cachedFileImage(path), isFalse);
      await settleUntilRepainted(tester, 'rec-1', red);

      expect(await paintedPixelOf(tester, 'rec-1'), '#0000ff');
    });

    testWidgets('an image the byte cache already let go of is still refreshed', (tester) async {
      final path = writeImage(_skillOf('rec-1'), redPng);
      final ref = _container().read(containerRefProvider);
      await tester.pumpWidget(recordImageScreen([recordImageTile('rec-1', path, maxDecodePixels: const Size(64, 64))]));
      await settleUntilPainted(tester, ['rec-1']);
      final red = paintedImageOf(tester, 'rec-1');
      expect(await paintedPixelOf(tester, 'rec-1'), '#ff0000', reason: 'the premise: red is on screen');
      // 49 one-byte fillers push the picture's entry past the LRU's 48-entry cap.
      for (var i = 0; i < 49; i++) {
        RecordImageByteCache.instance.put('${_tempRoot.path}/filler/$i.png', Uint8List(1));
      }
      expect(RecordImageByteCache.instance.paths.contains(path.path), isFalse, reason: 'the premise: pushed out');

      writeImage(path, bluePng);
      RecordImageEffect.drop(ref).apply(_scopeOf(['rec-1']));
      await settleUntilRepainted(tester, 'rec-1', red);

      expect(await paintedPixelOf(tester, 'rec-1'), '#0000ff');
    });

    testWidgets('a record outside the scope keeps its cache and its image state', (tester) async {
      final inside = writeImage(_skillOf('rec-1'), redPng);
      // `rec-10` starts with `rec-1` as text and is another record as a path.
      final outside = writeImage(_skillOf('rec-10'), redPng);
      final ref = _container().read(containerRefProvider);
      await tester.pumpWidget(
        recordImageScreen([recordImageTile('rec-1', inside), recordImageTile('rec-10', outside)]),
      );
      await settleUntilPainted(tester, ['rec-1', 'rec-10']);
      expect(cachedFileImage(outside), isTrue, reason: 'the premise: the control was decoded');
      final before = imageStateOf(tester, 'rec-10');

      RecordImageEffect.drop(ref).apply(_scopeOf(['rec-1']));
      expect(cachedFileImage(outside), isTrue, reason: 'a record the write did not touch lost its cached picture');
      await pumpRecordImageWindow(tester);

      expect(
        identical(before, imageStateOf(tester, 'rec-10')),
        isTrue,
        reason: 'a record the write did not touch was rebuilt',
      );
    });

    testWidgets('a disposed container still gets its images dropped', (tester) async {
      final path = writeImage(_skillOf('rec-1'), redPng);
      final dead = ProviderContainer();
      final ref = dead.read(containerRefProvider);
      dead.dispose();
      await tester.pumpWidget(recordImageScreen([recordImageTile('rec-1', path)]));
      await settleUntilPainted(tester, ['rec-1']);
      expect(cachedFileImage(path), isTrue, reason: 'the premise: the red PNG was decoded into the cache');

      expect(() => RecordImageEffect.drop(ref).apply(_scopeOf(['rec-1'])), returnsNormally);
      expect(cachedFileImage(path), isFalse);
    });
  });

  group('the preview readers re-read what the write changed', () {
    test('the geometry', () async {
      final container = _container();
      final ref = container.read(containerRefProvider);
      _writeGeometry(_recordDir('rec'), 100);
      final provider = imageSizeContainerProvider(_recordDir('rec').path);
      expect((await _hold(container, provider))?.skill.intersection.width, 100, reason: 'the premise');

      _writeGeometry(_recordDir('rec'), 200);
      RecordImageEffect.drop(ref).apply(_scopeOf(['rec']));

      expect((await container.read(provider.future))?.skill.intersection.width, 200);
    });

    test('the prediction', () async {
      final container = _container();
      final ref = container.read(containerRefProvider);
      final file = File(_recordDir('rec').filePath('prediction.json').path)..createSync(recursive: true);
      file.writeAsStringSync(_predictionJson(1));
      final provider = predictionContainerProvider(_recordDir('rec').path);
      expect((await _hold(container, provider))?.skillTab.length, 1, reason: 'the premise');

      file.writeAsStringSync(_predictionJson(2));
      RecordImageEffect.drop(ref).apply(_scopeOf(['rec']));

      expect((await container.read(provider.future))?.skillTab.length, 2);
    });

    test('whether a prediction exists', () async {
      final container = _container();
      final ref = container.read(containerRefProvider);
      final file = File(_recordDir('rec').filePath('prediction.json').path)..createSync(recursive: true);
      file.writeAsStringSync(_predictionJson(1));
      final provider = predictionAvailableProvider(_recordDir('rec').path);
      expect(await _hold(container, provider), isTrue, reason: 'the premise');

      file.deleteSync();
      RecordImageEffect.drop(ref).apply(_scopeOf(['rec']));

      expect(await container.read(provider.future), isFalse);
    });

    test('the image paths', () async {
      final container = _container();
      final ref = container.read(containerRefProvider);
      final png = writeImage(_skillOf('rec'), redPng);
      final provider = previewImagePathsProvider(_recordDir('rec').path);
      expect((await _hold(container, provider)).skill?.name, 'skill.png', reason: 'the premise');

      File(png.path).deleteSync();
      writeImage(_recordDir('rec').filePath('skill.jpg'), redPng);
      RecordImageEffect.drop(ref).apply(_scopeOf(['rec']));

      expect((await container.read(provider.future)).skill?.name, 'skill.jpg');
    });

    test('every record-keyed preview reader is listed', () {
      // Nothing in Dart can enumerate a library's top-level declarations at run
      // time, so the declarations are read off the source, as
      // `storage_tab_refresh_test.dart` reads the storage view's.
      final declaration = RegExp(r'final (\w+) = FutureProvider[\w.]*\.family<[^>]*,\s*String>');
      final names = <String>{
        for (final file in Directory('lib/src/gui/chara_detail').listSync(recursive: true).whereType<File>())
          if (file.path.endsWith('.dart'))
            for (final match in declaration.allMatches(file.readAsStringSync())) match.group(1)!,
      };
      expect(names, isNotEmpty, reason: 'the scan found no declaration at all, so it proves nothing');
      final source = File('lib/src/gui/chara_detail/preview_dialog.dart').readAsStringSync();
      final roster = source.substring(source.indexOf('recordPreviewReaders = ['));
      final listed = roster.substring(0, roster.indexOf('];'));
      for (final name in names) {
        expect(listed.contains('family: $name,'), isTrue, reason: '$name reads a record and is not listed');
      }
      expect(recordPreviewReaders, hasLength(names.length), reason: 'the list names something the scan did not');
    });
  });

  group('the storage totals are re-measured in each shape', () {
    Future<(ProviderContainer, DirectoryTotalsCache)> warmed() async {
      final container = _container();
      File(_recordDir('rec').filePath('record.json').path)
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(64, 0x20));
      final cache = container.read(directoryTotalsCacheProvider);
      expect((await cache.totalsOf(_layout.charaDetailDir)).knownBytes, 64, reason: 'the premise');
      return (container, cache);
    }

    test('the record root is re-measured', () async {
      final (container, cache) = await warmed();
      RecordTotalsEffect.remeasure(container.read(containerRefProvider)).apply(TotalsScope.recordRoot(_layout));
      expect(cache.peek(_layout.charaDetailDir)?.knownBytes, isNull);
    });

    test('the named paths are re-measured', () async {
      final (container, cache) = await warmed();
      RecordTotalsEffect.remeasure(container.read(containerRefProvider)).apply(TotalsScope.paths([_recordDir('rec')]));
      expect(cache.peek(_layout.charaDetailDir)?.knownBytes, isNull);
    });

    test('everything is re-measured', () async {
      final (container, cache) = await warmed();
      RecordTotalsEffect.remeasure(container.read(containerRefProvider)).apply(const TotalsScope.everything());
      expect(cache.peek(_layout.charaDetailDir)?.knownBytes, isNull);
    });
  });
}
