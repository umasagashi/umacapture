// Extension -> kind -> icon for the storage tree.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_file_kind_test.dart
//
// Two claims, kept apart because the split between them is the point:
//
// * The classifier answers from the name alone, defaults to `binary` for
//   anything it does not know, and takes a directory's kind from its type rather
//   than its name.
// * The icon table covers every kind. That check is written so it fails when a
//   kind is added, instead of enumerating the kinds a second time by hand.
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/storage/file_kind.dart';
import 'package:umacapture/src/core/storage/file_kind_entity.dart';
import 'package:umacapture/src/gui/storage_file_icon.dart';

void main() {
  group('storageFileKindOfName', () {
    test('names the kinds the tree has to tell apart', () {
      expect(storageFileKindOfName('campaign.png'), StorageFileKind.image);
      expect(storageFileKindOfName('record.json'), StorageFileKind.json);
      expect(storageFileKindOfName('export.csv'), StorageFileKind.text);
      expect(storageFileKindOfName('modules.onnx'), StorageFileKind.binary);
    });

    test("the app's own binary files are binary, not text", () {
      // Every one of these lives in a group the tab shows, and reading any of
      // them as a string is what the preview stage must not do.
      for (final name in ['module.onnx', 'MPLUS1Code_700_x.ttf', 'settings.hive', 'settings.lock', 'modules.zip']) {
        expect(storageFileKindOf(FilePath(name)), StorageFileKind.binary, reason: name);
      }
    });

    test('an unknown extension falls to binary rather than to text', () {
      expect(storageFileKindOfName('mystery.qqq'), StorageFileKind.binary);
      expect(storageFileKindOfName('LICENSE'), StorageFileKind.binary);
      // A leading dot is the whole basename to `p`, not a suffix.
      expect(storageFileKindOfName('.gitignore'), StorageFileKind.binary);
    });

    test('the extension match ignores case', () {
      expect(storageFileKindOfName('SHOT.PNG'), StorageFileKind.image);
      expect(storageFileKindOfName('Record.Json'), StorageFileKind.json);
    });

    test('only the last extension decides', () {
      expect(storageFileKindOfName('record.json.bak'), StorageFileKind.binary);
      expect(storageFileKindOfName('archive.tar.json'), StorageFileKind.json);
    });
  });

  group('storageFileKindOf', () {
    test('a directory is a directory whatever it is called', () {
      expect(storageFileKindOf(DirectoryPath('records')), StorageFileKind.directory);
      // The trap: a directory whose name ends in an extension the table knows.
      expect(storageFileKindOf(DirectoryPath('backup.json')), StorageFileKind.directory);
      expect(storageFileKindOf(DirectoryPath('thumbs.png')), StorageFileKind.directory);
    });

    test('a file is classified by its last segment, not by its parents', () {
      expect(storageFileKindOf(FilePath(['a.png', 'b', 'c.json'])), StorageFileKind.json);
    });
  });

  group('isTextual -- what the preview stage may read as a string', () {
    test('text and JSON are readable, the rest is not', () {
      expect(StorageFileKind.text.isTextual, isTrue);
      expect(StorageFileKind.json.isTextual, isTrue);
      expect(StorageFileKind.image.isTextual, isFalse);
      expect(StorageFileKind.binary.isTextual, isFalse);
      expect(StorageFileKind.directory.isTextual, isFalse);
    });
  });

  group('storageFileKindIcon', () {
    test('every kind has an icon, and no two kinds share one', () {
      // Driven off `values`, so adding a kind fails this without anyone
      // remembering to extend a list here.
      final icons = {for (final kind in StorageFileKind.values) kind: storageFileKindIcon(kind)};
      expect(icons.length, StorageFileKind.values.length);
      expect(icons.values.toSet().length, StorageFileKind.values.length, reason: 'two kinds render identically');
    });
  });
}
