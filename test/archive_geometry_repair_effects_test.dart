// What the one-time archive geometry repair declares about the reads it made stale.
//
//   .fvm/flutter_sdk/bin/flutter test test/archive_geometry_repair_effects_test.dart
//
// The repair rewrites every archived geometry json to the pixel size of the image
// beside it, under paths that stay the same, so a preview provider or a decoded
// picture read before it keeps answering with the old contents unless the pass
// drops them. The material states its sizes up front and asserts them before the
// pass, because the repair reads the image's real header: a json with no image
// beside it is deleted rather than rescaled, and an image of the json's own width
// leaves it unchanged, and either would make a missing drop look like a pass.
//
// WHAT THIS SUITE CANNOT REACH.
//  * Web. The repair returns before doing anything under `kIsWeb`.
//  * The storage view's totals. The declaration re-measures the record root; the
//    re-measure itself is covered where the effect type is.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:umacapture/src/chara_detail/image_converter.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/gui/chara_detail/preview_dialog.dart';

import 'support/hive.dart';
import 'support/record_image_fixture.dart';
import 'support/record_write_effects_fixture.dart';

/// The width every geometry json is written at, as the capture resolution was.
const _jsonWidth = 100;

/// The width of every archived image, which the repair rescales the json to.
const _imageWidth = 200;

const _tabs = ['skill', 'factor', 'campaign'];

late Directory _tempRoot;
late PathInfo _layout;

DirectoryPath get _record => _layout.charaDetailArchiveDir / 'rec';

FilePath _imageOf(String tab) => _record.filePath('$tab.png');

String _intersectionJson(int width) => jsonEncode({
  'intersection': {
    'top_left': {
      'x': 0,
      'y': 0,
      'anchor': {'h': 'ScreenStart', 'v': 'ScreenStart'},
    },
    'bottom_right': {
      'x': width,
      'y': 40,
      'anchor': {'h': 'ScreenStart', 'v': 'ScreenStart'},
    },
  },
});

/// One archived record: a geometry json at [_jsonWidth] and a real red PNG
/// [_imageWidth] wide for each tab, plus the `prediction.json` the pass deletes.
void _seedRecord() {
  final png = img.encodePng(img.fill(img.Image(width: _imageWidth, height: 80), color: img.ColorRgb8(255, 0, 0)));
  for (final tab in _tabs) {
    writeImage(_imageOf(tab), png);
    File(_record.filePath('$tab.json').path).writeAsStringSync(_intersectionJson(_jsonWidth));
  }
  File(_record.filePath('prediction.json').path).writeAsStringSync('{}');
}

bool _repaired() => !_record.filePath('prediction.json').existsSync();

List<num?> _widths(ImageSizeContainer? sizes) => [
  sizes?.skill.intersection.width,
  sizes?.factor.intersection.width,
  sizes?.campaign.intersection.width,
];

ProviderContainer _container() {
  final container = ProviderContainer.test();
  addTearDown(container.dispose);
  return container;
}

Future<void> _repair(ProviderContainer container, {RecordRecoveryGate? gate}) {
  return runArchiveGeometryMigrationIfNeeded(
    _layout,
    declaration: geometryRepairLongReadDeclaration(container, _layout),
    effects: geometryRepairEffects(container),
    recoveryGate: gate,
  );
}

/// A gate that refuses the root scope, as a bulk scan holding it would.
final _busyGate = RecordRecoveryGate(
  mutationLock: RecordMutationLock((name, mode, action) async {
    throw const RecordMutationLockBusy('record-root', Duration(seconds: 1));
  }),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeMappers);

  // Per test: the pass records completion in this box and skips itself after.
  useHiveForEachTest(['data_migration']);

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_archive_repair_effects');
    final root = DirectoryPath(_tempRoot);
    _layout = PathInfo(documentDir: root, supportDir: root, executableDir: root, downloadDir: root);
    _seedRecord();
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  tearDown(() {
    imageCache.clear();
    imageCache.clearLiveImages();
    if (_tempRoot.existsSync()) _tempRoot.deleteSync(recursive: true);
  });

  test('the material: each image is wider than the json beside it', () async {
    for (final tab in _tabs) {
      expect(readImageSize(_imageOf(tab))?.width, _imageWidth, reason: tab);
    }
    expect(_widths(await ImageSizeContainer.load(_record)), [_jsonWidth, _jsonWidth, _jsonWidth]);
  });

  test('a preview held open across the repair reads the rescaled geometry', () async {
    final container = _container();
    final provider = imageSizeContainerProvider(_record.path);
    container.listen(provider, (_, _) {});
    expect(_widths(await container.read(provider.future)), [
      _jsonWidth,
      _jsonWidth,
      _jsonWidth,
    ], reason: 'the premise: the provider read the json as written');

    await _repair(container);

    expect(_widths(await ImageSizeContainer.load(_record)), [
      _imageWidth,
      _imageWidth,
      _imageWidth,
    ], reason: 'the control: the pass rescaled the files');
    expect(_widths(await container.read(provider.future)), [_imageWidth, _imageWidth, _imageWidth]);
  });

  testWidgets('an archived picture decoded before the repair is dropped by it', (tester) async {
    final container = _container();
    await tester.pumpWidget(recordImageScreen([recordImageTile('rec', _imageOf('skill'))]));
    await settleUntilPainted(tester, ['rec']);
    expect(cachedFileImage(_imageOf('skill')), isTrue, reason: 'the premise: the picture was decoded into the cache');

    await tester.runAsync(() => _repair(container));

    expect(_repaired(), isTrue, reason: 'the control: the pass ran');
    expect(cachedFileImage(_imageOf('skill')), isFalse);
  });

  testWidgets('a repair refused the root scope drops nothing', (tester) async {
    final container = _container();
    await tester.pumpWidget(recordImageScreen([recordImageTile('rec', _imageOf('skill'))]));
    await settleUntilPainted(tester, ['rec']);
    expect(cachedFileImage(_imageOf('skill')), isTrue, reason: 'the premise: the picture was decoded into the cache');

    await tester.runAsync(() => _repair(container, gate: _busyGate));

    expect(_repaired(), isFalse, reason: 'the control: the pass was refused, so it wrote nothing');
    expect(cachedFileImage(_imageOf('skill')), isTrue, reason: 'a pass that wrote nothing has nothing to drop');
  });
}
