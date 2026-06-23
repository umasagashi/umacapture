// Verifies the data-root migration controller: target classification, and the
// load-bearing directory swap with its rollback (the destination's existing data
// must survive a mid-flight failure, and the source is never touched).
//
// Run: .fvm/flutter_sdk/bin/flutter test test/data_root_migration_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/data_root_migration.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';

void main() {
  late Directory tempRoot;

  setUp(() => tempRoot = Directory.systemTemp.createTempSync('umacapture_migration_test'));
  tearDown(() => tempRoot.deleteSync(recursive: true));

  PathInfo sourceAt(String sub, {DirectoryPath? dataRoot}) {
    final base = DirectoryPath('${tempRoot.path}/$sub');
    return PathInfo(
      documentDir: base,
      supportDir: base,
      executableDir: DirectoryPath('${tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${tempRoot.path}/dl'),
      dataRoot: dataRoot,
    );
  }

  void writeFile(DirectoryPath dir, String name, String content) {
    File('${dir.path}/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  group('DataRootMigrationController.classify', () {
    test('sameLocation when the chosen root resolves to the current data', () {
      final root = DirectoryPath('${tempRoot.path}/data');
      final controller = DataRootMigrationController(source: sourceAt('docs', dataRoot: root));
      expect(controller.classify(root), MigrationKind.sameLocation);
    });

    test('invalid when the target is nested inside the current data', () {
      final source = sourceAt('docs');
      final controller = DataRootMigrationController(source: source);
      expect(controller.classify(source.storageDir / 'inner'), MigrationKind.invalid);
    });

    test('invalid when the target path is relative', () {
      final controller = DataRootMigrationController(source: sourceAt('docs'));
      expect(controller.classify(DirectoryPath('relative/dir')), MigrationKind.invalid);
    });

    test('empty when the destination directories do not yet exist', () {
      final controller = DataRootMigrationController(source: sourceAt('docs'));
      expect(controller.classify(DirectoryPath('${tempRoot.path}/fresh')), MigrationKind.empty);
    });

    test('hasData when a destination directory already holds files', () {
      final controller = DataRootMigrationController(source: sourceAt('docs'));
      final root = DirectoryPath('${tempRoot.path}/used');
      writeFile(root / 'storage', 'existing.txt', 'x');
      expect(controller.classify(root), MigrationKind.hasData);
    });
  });

  group('DataRootMigrationController.swapDirectories', () {
    test('copies into empty destinations and leaves no backups', () async {
      final src = DirectoryPath('${tempRoot.path}/src');
      final dst = DirectoryPath('${tempRoot.path}/dst');
      writeFile(src, 'a.txt', 'a');

      final ok = await DataRootMigrationController.swapDirectories([(src: src, dst: dst)]);

      expect(ok, isTrue);
      expect(File('${dst.path}/a.txt').readAsStringSync(), 'a');
      expect(File('${src.path}/a.txt').existsSync(), isTrue);
      expect(Directory('${dst.path}.uma-old').existsSync(), isFalse);
    });

    test('replaces existing destination data and drops the backup on success', () async {
      final src = DirectoryPath('${tempRoot.path}/src');
      final dst = DirectoryPath('${tempRoot.path}/dst');
      writeFile(src, 'new.txt', 'new');
      writeFile(dst, 'old.txt', 'old');

      final ok = await DataRootMigrationController.swapDirectories([(src: src, dst: dst)]);

      expect(ok, isTrue);
      expect(File('${dst.path}/new.txt').readAsStringSync(), 'new');
      expect(File('${dst.path}/old.txt').existsSync(), isFalse);
      expect(Directory('${dst.path}.uma-old').existsSync(), isFalse);
    });

    test('rolls back a completed fresh swap when a later pair fails', () async {
      final src1 = DirectoryPath('${tempRoot.path}/src1');
      final dst1 = DirectoryPath('${tempRoot.path}/dst1');
      writeFile(src1, 'a.txt', 'a');
      // Force the second pair to fail: its destination's parent is a file, so
      // copyTreeInto's recursive mkdir throws.
      final blocker = File('${tempRoot.path}/blocker')..writeAsStringSync('x');
      final src2 = DirectoryPath('${tempRoot.path}/src2');
      writeFile(src2, 'b.txt', 'b');
      final dst2 = DirectoryPath('${blocker.path}/dst2');

      final ok = await DataRootMigrationController.swapDirectories([(src: src1, dst: dst1), (src: src2, dst: dst2)]);

      expect(ok, isFalse);
      expect(File('${src1.path}/a.txt').existsSync(), isTrue);
      expect(File('${src2.path}/b.txt').existsSync(), isTrue);
      // dst1 had no prior data, so the rollback removes the copy entirely.
      expect(Directory(dst1.path).existsSync(), isFalse);
    });

    test('restores pre-existing destination data when a later pair fails (#5 regression)', () async {
      final src1 = DirectoryPath('${tempRoot.path}/src1');
      final dst1 = DirectoryPath('${tempRoot.path}/dst1');
      writeFile(src1, 'new.txt', 'new');
      writeFile(dst1, 'old.txt', 'old');
      final blocker = File('${tempRoot.path}/blocker')..writeAsStringSync('x');
      final src2 = DirectoryPath('${tempRoot.path}/src2');
      writeFile(src2, 'b.txt', 'b');
      final dst2 = DirectoryPath('${blocker.path}/dst2');

      final ok = await DataRootMigrationController.swapDirectories([(src: src1, dst: dst1), (src: src2, dst: dst2)]);

      expect(ok, isFalse);
      // dst1's ORIGINAL data is restored; neither the migrated copy nor the
      // backup is left behind.
      expect(File('${dst1.path}/old.txt').readAsStringSync(), 'old');
      expect(File('${dst1.path}/new.txt').existsSync(), isFalse);
      expect(Directory('${dst1.path}.uma-old').existsSync(), isFalse);
    });

    test('skips a pair whose source and destination resolve to the same directory', () async {
      final dir = DirectoryPath('${tempRoot.path}/same');
      writeFile(dir, 'a.txt', 'a');

      final ok = await DataRootMigrationController.swapDirectories([(src: dir, dst: dir)]);

      expect(ok, isTrue);
      expect(File('${dir.path}/a.txt').readAsStringSync(), 'a');
    });
  });
}
