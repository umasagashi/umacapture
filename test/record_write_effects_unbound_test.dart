// `RecordImageDrop.apply` with no Flutter binding, where its first stage cannot
// run at all.
//
//   .fvm/flutter_sdk/bin/flutter test test/record_write_effects_unbound_test.dart
//
// The pixel stage reaches `PaintingBinding.instance`, which throws when no
// binding was initialized. That is the one failure of a stage this suite can
// produce without injecting anything, so it is how "each stage fails on its
// own" is measured: the preview stage after it has to run anyway.
//
// No `testWidgets` here and no `ensureInitialized`: either would install the
// binding whose absence is the premise.
//
// MATERIAL. Three tab jsons whose intersection spans (0,0)..(width,100), width
// 100 before the write and 200 after.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/record_write_effects.dart';
import 'package:umacapture/src/gui/chara_detail/preview_dialog.dart';

void _writeGeometry(DirectoryPath recordDir, int width) {
  final corner = {'h': 'ScreenStart', 'v': 'ScreenStart'};
  final json = jsonEncode({
    'intersection': {
      'top_left': {'x': 0, 'y': 0, 'anchor': corner},
      'bottom_right': {'x': width, 'y': 100, 'anchor': corner},
    },
  });
  for (final tab in ['skill', 'factor', 'campaign']) {
    File(recordDir.filePath('$tab.json').path)
      ..createSync(recursive: true)
      ..writeAsStringSync(json);
  }
}

void main() {
  setUpAll(initializeMappers);

  test('a failing pixel-cache stage leaves the preview stage running', () async {
    final tempRoot = Directory.systemTemp.createTempSync('uma_record_write_effects_unbound');
    addTearDown(() => tempRoot.deleteSync(recursive: true));
    final root = DirectoryPath(tempRoot.path);
    final layout = PathInfo(
      documentDir: root,
      supportDir: root,
      executableDir: root / 'exe',
      downloadDir: root / 'dl',
      dataRoot: root,
    );
    final recordDir = recordDirOfId(layout, RecordSource.active, 'rec');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final provider = imageSizeContainerProvider(recordDir.path);

    expect(() => PaintingBinding.instance, throwsFlutterError, reason: 'the premise: no binding');
    _writeGeometry(recordDir, 100);
    container.listen(provider, (_, _) {});
    expect((await container.read(provider.future))?.skill.intersection.width, 100, reason: 'the premise');

    _writeGeometry(recordDir, 200);
    expect(
      () => RecordImageEffect.drop(
        container.read(containerRefProvider),
      ).apply(RecordImageScope(info: layout, changed: [recordDir.path])),
      returnsNormally,
    );

    expect((await container.read(provider.future))?.skill.intersection.width, 200);
  });
}
