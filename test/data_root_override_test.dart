// Verifies the user-configurable data root: PathInfo resolves its relocatable
// directories under an override when present (and under the native defaults
// otherwise), and DirectoryPath.copyTreeInto reproduces a tree across volumes.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/data_root_override_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';

void main() {
  group('PathInfo data root override', () {
    final documentDir = DirectoryPath('/docs/app');
    final supportDir = DirectoryPath('/support');
    final executableDir = DirectoryPath('/exe');
    final downloadDir = DirectoryPath('/downloads');

    PathInfo base({DirectoryPath? dataRoot}) => PathInfo(
      documentDir: documentDir,
      supportDir: supportDir,
      executableDir: executableDir,
      downloadDir: downloadDir,
      dataRoot: dataRoot,
    );

    test('falls back to native defaults when no override is set', () {
      final info = base();
      expect(info.storageDir.path, (documentDir / 'storage').path);
      expect(info.tempDir.path, (documentDir / 'temp').path);
      expect(info.modulesDir.path, (supportDir / 'modules').path);
      // Mirrors Hive.initFlutter, which resolves against the documents dir.
      expect(info.settingsDir.path, (documentDir / 'settings').path);
    });

    test('resolves every relocatable directory under the override', () {
      final root = DirectoryPath('/data/uma');
      final info = base(dataRoot: root);
      expect(info.storageDir.path, (root / 'storage').path);
      expect(info.tempDir.path, (root / 'temp').path);
      expect(info.modulesDir.path, (root / 'modules').path);
      expect(info.settingsDir.path, (root / 'settings').path);
      // chara_detail dirs chain off storageDir, so they follow automatically.
      expect(info.charaDetailActiveDir.path, (root / 'storage' / 'chara_detail' / 'active').path);
    });

    test('never relocates the executable or download directories', () {
      final info = base(dataRoot: DirectoryPath('/data/uma'));
      expect(info.executableDir.path, executableDir.path);
      expect(info.downloadDir.path, downloadDir.path);
    });

    test('withDataRoot toggles between override and default layouts', () {
      final info = base(dataRoot: DirectoryPath('/data/uma'));
      final reset = info.withDataRoot(null);
      expect(reset.storageDir.path, (documentDir / 'storage').path);
      expect(reset.dataRoot, isNull);
    });
  });

  group('DirectoryPath.copyTreeInto', () {
    late Directory tempRoot;

    setUp(() => tempRoot = Directory.systemTemp.createTempSync('umacapture_copytree_test'));
    tearDown(() => tempRoot.deleteSync(recursive: true));

    test('reproduces nested files and directories at the destination', () async {
      final source = DirectoryPath('${tempRoot.path}/source');
      File('${source.path}/a.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('a');
      File('${source.path}/nested/b.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('b');
      Directory('${source.path}/empty').createSync(recursive: true);

      final dest = DirectoryPath('${tempRoot.path}/dest');
      final ok = await source.copyTreeInto(dest);

      expect(ok, isTrue);
      expect(File('${dest.path}/a.txt').readAsStringSync(), 'a');
      expect(File('${dest.path}/nested/b.txt').readAsStringSync(), 'b');
      expect(Directory('${dest.path}/empty').existsSync(), isTrue);
    });

    test('returns false when the source does not exist', () async {
      final source = DirectoryPath('${tempRoot.path}/missing');
      final dest = DirectoryPath('${tempRoot.path}/dest');
      expect(await source.copyTreeInto(dest), isFalse);
    });
  });
}
