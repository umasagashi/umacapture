// Basic round-trip coverage for the desktop (dart:io) FsBackend and the
// PathEntity async surface that delegates to it. Confirms write/read/exists/
// list/delete/rename/copy/createDir behave as they did before the backend was
// extracted, so the async-first refactor keeps desktop behavior identical.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/fs_backend_io_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/path_entity.dart';

void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_fs_backend_test');
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  String at(String relative) => '${tempRoot.path}/$relative';

  group('FsBackend (io) async surface', () {
    test('write/read string round-trips and reports existence', () async {
      final path = at('note.txt');
      expect(await fsBackend.exists(path), isFalse);

      await fsBackend.writeString(path, 'hello');

      expect(await fsBackend.exists(path), isTrue);
      expect(await fsBackend.readString(path), 'hello');
    });

    test('write/read bytes round-trips', () async {
      final path = at('blob.bin');
      final bytes = Uint8List.fromList([0, 1, 2, 253, 254, 255]);

      await fsBackend.writeBytes(path, bytes);

      expect(await fsBackend.readBytes(path), bytes);
    });

    test('createDir + list enumerates entries (recursive and shallow)', () async {
      await fsBackend.createDir(at('tree/sub'), recursive: true);
      await fsBackend.writeString(at('tree/a.txt'), 'a');
      await fsBackend.writeString(at('tree/sub/b.txt'), 'b');

      final shallow = await fsBackend.list(at('tree'));
      expect(shallow.map((e) => e.path.split(RegExp(r'[/\\]')).last), containsAll(['a.txt', 'sub']));

      final deep = await fsBackend.list(at('tree'), recursive: true);
      expect(deep.map((e) => e.path.split(RegExp(r'[/\\]')).last), containsAll(['a.txt', 'sub', 'b.txt']));

      // The listing carries each entry's kind, so tree walks never have to
      // re-resolve a listed path just to learn whether it is a file.
      expect(
        {for (final e in deep) e.path.split(RegExp(r'[/\\]')).last: e.isDirectory},
        {'a.txt': false, 'sub': true, 'b.txt': false},
      );
    });

    test('list rejects a missing path and a file, instead of reporting an empty directory', () async {
      await fsBackend.writeString(at('not-a-dir.txt'), 'x');

      await expectLater(fsBackend.list(at('absent')), throwsA(isA<Exception>()));
      await expectLater(fsBackend.list(at('not-a-dir.txt')), throwsA(isA<Exception>()));
    });

    test('rename moves a file', () async {
      await fsBackend.writeString(at('src.txt'), 'x');

      await fsBackend.rename(at('src.txt'), at('dst.txt'));

      expect(await fsBackend.exists(at('src.txt')), isFalse);
      expect(await fsBackend.readString(at('dst.txt')), 'x');
    });

    test('copyFile duplicates content without removing the source', () async {
      await fsBackend.writeString(at('orig.txt'), 'y');

      await fsBackend.copyFile(at('orig.txt'), at('copy.txt'));

      expect(await fsBackend.readString(at('orig.txt')), 'y');
      expect(await fsBackend.readString(at('copy.txt')), 'y');
    });

    test('delete removes a file and, recursively, a tree', () async {
      await fsBackend.writeString(at('gone.txt'), 'z');
      await fsBackend.delete(at('gone.txt'));
      expect(await fsBackend.exists(at('gone.txt')), isFalse);

      await fsBackend.createDir(at('dir/inner'), recursive: true);
      await fsBackend.writeString(at('dir/inner/f.txt'), 'f');
      await fsBackend.delete(at('dir'), recursive: true);
      expect(await fsBackend.exists(at('dir')), isFalse);
    });
  });

  group('FsBackend (io) length and sameFileBytes', () {
    Future<void> write(String relative, List<int> bytes) => fsBackend.writeBytes(at(relative), bytes);

    test('length reports the size and throws for a missing file', () async {
      await write('sized.bin', List<int>.filled(7, 9));

      expect(await fsBackend.length(at('sized.bin')), 7);
      await expectLater(fsBackend.length(at('absent.bin')), throwsA(isA<FileSystemException>()));
    });

    test('equality holds for every trailing-byte remainder', () async {
      // Sizes 1..8 cover all four word remainders. 3 and 6 are the sizes the
      // record fixtures produce, so the byte tail after the 32-bit word loop is
      // exercised by real data too.
      for (var size = 0; size <= 8; size++) {
        final bytes = List<int>.generate(size, (i) => i + 1);
        await write('same_a_$size.bin', bytes);
        await write('same_b_$size.bin', bytes);
        expect(
          await fsBackend.sameFileBytes(at('same_a_$size.bin'), at('same_b_$size.bin')),
          isTrue,
          reason: 'identical $size-byte files',
        );

        if (size == 0) continue;
        // Flip the last byte: for a size that is not a multiple of four this
        // difference lies past the word loop and only the byte tail sees it.
        final tailChanged = List<int>.from(bytes);
        tailChanged[size - 1] = tailChanged[size - 1] ^ 0xff;
        await write('tail_$size.bin', tailChanged);
        expect(
          await fsBackend.sameFileBytes(at('same_a_$size.bin'), at('tail_$size.bin')),
          isFalse,
          reason: 'last byte differs in a $size-byte file',
        );
      }
    });

    test('a length difference alone is inequality', () async {
      await write('short.bin', [1, 2, 3]);
      await write('long.bin', [1, 2, 3, 4]);

      expect(await fsBackend.sameFileBytes(at('short.bin'), at('long.bin')), isFalse);
    });

    test('multi-chunk files compare across chunk boundaries with a ragged tail', () async {
      // One full chunk plus three bytes, so the final chunk is neither full nor
      // word-aligned in length.
      const size = 256 * 1024 + 3;
      final bytes = Uint8List.fromList(List<int>.generate(size, (i) => i & 0xff));
      await write('big_a.bin', bytes);
      await write('big_b.bin', bytes);
      expect(await fsBackend.sameFileBytes(at('big_a.bin'), at('big_b.bin')), isTrue);

      final tailChanged = Uint8List.fromList(bytes);
      tailChanged[size - 1] = tailChanged[size - 1] ^ 0xff;
      await write('big_tail.bin', tailChanged);
      expect(await fsBackend.sameFileBytes(at('big_a.bin'), at('big_tail.bin')), isFalse);

      // A difference in the first chunk must be caught without reading the rest.
      final headChanged = Uint8List.fromList(bytes);
      headChanged[1] = headChanged[1] ^ 0xff;
      await write('big_head.bin', headChanged);
      expect(await fsBackend.sameFileBytes(at('big_a.bin'), at('big_head.bin')), isFalse);
    });
  });

  group('FsBackend (io) sync surface', () {
    test('sync write/read/exists/list/delete round-trip', () {
      final path = at('sync.txt');
      expect(fsBackend.existsSync(path), isFalse);

      fsBackend.writeStringSync(path, 'sync-content');

      expect(fsBackend.existsSync(path), isTrue);
      expect(fsBackend.isFileSync(path), isTrue);
      expect(fsBackend.readStringSync(path), 'sync-content');
      expect(fsBackend.listSync(tempRoot.path).map((e) => e.path.split(RegExp(r'[/\\]')).last), contains('sync.txt'));

      fsBackend.deleteSync(path);
      expect(fsBackend.existsSync(path), isFalse);
    });
  });

  group('PathEntity delegates to the backend', () {
    test('FilePath async write/read and DirectoryPath list', () async {
      final dir = DirectoryPath(tempRoot.path) / 'records';
      final file = dir.filePath('record.json');

      await file.writeAsString('{"ok":true}');

      expect(await file.exists(), isTrue);
      expect(await file.readAsString(), '{"ok":true}');
      final entries = await dir.list().map((e) => e.name).toList();
      expect(entries, contains('record.json'));
    });

    test('listings yield entities already typed by kind, so isFile costs no probe', () async {
      final dir = DirectoryPath(tempRoot.path) / 'typed';
      await dir.filePath('leaf.json').writeAsString('{}');
      await (dir / 'child').create(recursive: true);

      final async = {for (final e in await dir.list().toList()) e.name: e};
      expect(async['leaf.json'], isA<FilePath>());
      expect(async['child'], isA<DirectoryPath>());
      expect(await (async['leaf.json'] as PathEntity).isFile(), isTrue);
      expect(await (async['child'] as PathEntity).isFile(), isFalse);

      final sync = {for (final e in dir.listSync()) e.name: e};
      expect(sync['leaf.json'], isA<FilePath>());
      expect(sync['child'], isA<DirectoryPath>());
    });

    test('copyTreeInto refuses a non-directory source instead of reporting success', () async {
      final file = FilePath([tempRoot.path, 'not-a-tree.txt']);
      await file.writeAsString('payload');

      expect(await DirectoryPath(file.path).copyTreeInto(DirectoryPath(tempRoot.path) / 'copy'), isFalse);
      expect(await file.readAsString(), 'payload');
    });

    test('writes require the parent directory to exist on every backend', () async {
      final missingParent = at('absent-dir/leaf.txt');

      await expectLater(fsBackend.writeString(missingParent, 'x'), throwsA(isA<Exception>()));
      await expectLater(fsBackend.writeBytes(missingParent, const [1]), throwsA(isA<Exception>()));
      await fsBackend.writeString(at('present.txt'), 'x');
      await expectLater(fsBackend.copyFile(at('present.txt'), missingParent), throwsA(isA<Exception>()));
      await expectLater(fsBackend.rename(at('present.txt'), missingParent), throwsA(isA<Exception>()));
    });

    test('sync escape hatch still works on desktop', () {
      final file = FilePath([tempRoot.path, 'sync_entity.txt']);

      file.writeAsStringSync('desktop');

      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), 'desktop');
    });
  });
}
