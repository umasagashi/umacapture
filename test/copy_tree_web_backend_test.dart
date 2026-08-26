// Reproduces the web (OPFS) FsBackend restriction on the VM to guard the tree /
// move / archive / quarantine paths against touching the synchronous FS surface
// the web backend rejects.
//
// The other unit suites run on the io backend, whose sync surface works, so a
// path that branches on `isFileSync` (as `DirectoryPath.copyTreeInto` used to)
// passed there yet failed on web with `UnsupportedError`. Here the process-wide
// backend is swapped for `WebLikeFsBackend` — async delegated to io, every sync
// method throws — so the *synchronous* prohibition OPFS imposes is reproduced
// here without a browser host. Only that prohibition: the async surface is the
// io backend's, so nothing below establishes how OPFS itself answers (error
// types, a missing path, rename, write atomicity, quota). A change that turns
// on one of those still needs a browser run. Assertions read the real on-disk
// result through `dart:io` directly, bypassing the installed (sync-hostile)
// backend.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/copy_tree_web_backend_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/web_like_fs_backend.dart';

void main() {
  setUpAll(initializeMappers);

  late Directory tempRoot;
  late FsBackend original;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_web_fs_test');
    // Swap in the web-like backend so the code under test hits the same
    // sync-hostile surface it would on OPFS.
    original = fsBackend;
    fsBackend = WebLikeFsBackend(original);
  });

  tearDown(() {
    // Restore the real backend before the dart:io cleanup below.
    fsBackend = original;
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  Uint8List png(int w, int h) => img.encodePng(img.Image(width: w, height: h));

  Uint8List jpg(int w, int h) => img.encodeJpg(img.Image(width: w, height: h));

  String intersectionJson(int w, int h) => jsonEncode({
    "intersection": {
      "top_left": {
        "x": 0,
        "y": 0,
        "anchor": {"h": "ScreenStart", "v": "ScreenStart"},
      },
      "bottom_right": {
        "x": w,
        "y": h,
        "anchor": {"h": "ScreenStart", "v": "ScreenStart"},
      },
    },
  });

  test('copyTreeInto copies a nested tree without touching the sync FS', () async {
    final src = DirectoryPath('${tempRoot.path}/src');
    await src.filePath('a.txt').writeAsString('alpha');
    await (src / 'sub').filePath('b.txt').writeAsString('beta');

    final ok = await src.copyTreeInto(DirectoryPath('${tempRoot.path}/dst'));

    expect(ok, isTrue);
    // The whole tree landed, and the source is left intact (this is a copy).
    expect(File('${tempRoot.path}/dst/a.txt').readAsStringSync(), 'alpha');
    expect(File('${tempRoot.path}/dst/sub/b.txt').readAsStringSync(), 'beta');
    expect(File('${tempRoot.path}/src/a.txt').existsSync(), isTrue);
  });

  test('moveAsyncSafe moves a tree and removes the source', () async {
    final src = DirectoryPath('${tempRoot.path}/src');
    await src.filePath('a.txt').writeAsString('alpha');
    await (src / 'sub').filePath('b.txt').writeAsString('beta');

    final destination = await src.moveAsyncSafe(DirectoryPath('${tempRoot.path}/dst'));

    expect(destination, isNotNull);
    expect(Directory('${tempRoot.path}/src').existsSync(), isFalse);
    expect(File('${tempRoot.path}/dst/a.txt').readAsStringSync(), 'alpha');
    expect(File('${tempRoot.path}/dst/sub/b.txt').readAsStringSync(), 'beta');
  });

  test('archiveRecordAsync archives a record (resizedJpeg) on the web-like backend', () async {
    final active = Directory('${tempRoot.path}/active/rec')..createSync(recursive: true);
    File('${active.path}/record.json').writeAsStringSync('{"id":"rec"}');
    File('${active.path}/trainee.jpg').writeAsBytesSync(jpg(60, 60));
    File('${active.path}/prediction.json').writeAsStringSync('{"status_header":[]}');
    File('${active.path}/skill.png').writeAsBytesSync(png(1000, 1500));
    File('${active.path}/skill.json').writeAsStringSync(intersectionJson(1000, 1500));

    final ok = await archiveRecordAsync(
      ArchiveRecordArgs('${tempRoot.path}/active/rec', '${tempRoot.path}/archive/rec', ArchiveImageOption.resizedJpeg),
    );

    expect(ok, isTrue);
    // The record moved out of active/ and into archive/, retaining its metadata.
    expect(Directory('${tempRoot.path}/active/rec').existsSync(), isFalse);
    expect(File('${tempRoot.path}/archive/rec/record.json').readAsStringSync(), '{"id":"rec"}');
    expect(File('${tempRoot.path}/archive/rec/trainee.jpg').existsSync(), isTrue);
    // Overlay data dropped, PNG converted to JPEG.
    expect(File('${tempRoot.path}/archive/rec/prediction.json').existsSync(), isFalse);
    expect(File('${tempRoot.path}/archive/rec/skill.jpg').existsSync(), isTrue);
    expect(File('${tempRoot.path}/archive/rec/skill.png').existsSync(), isFalse);
  });

  test('loadAsync quarantines an undecodable record on the web-like backend', () async {
    final dir = Directory('${tempRoot.path}/active/id-x')..createSync(recursive: true);
    File('${dir.path}/record.json').writeAsStringSync('{}'); // Missing every required field.
    File('${dir.path}/trainee.jpg').writeAsStringSync('image-bytes');

    final result = await CharaDetailRecord.loadAsync(DirectoryPath(dir.path));

    expect(result, isA<RecordQuarantined>());
    // The record was moved aside (contents preserved), not deleted, and left active/.
    expect(Directory('${tempRoot.path}/quarantine/id-x').existsSync(), isTrue);
    expect(File('${tempRoot.path}/quarantine/id-x/trainee.jpg').readAsStringSync(), 'image-bytes');
    expect(Directory('${tempRoot.path}/active/id-x').existsSync(), isFalse);
    expect((result as RecordQuarantined).destination!.name, 'id-x');
  });

  test('a mid-copy failure removes the destination it created (no orphan)', () async {
    final src = DirectoryPath('${tempRoot.path}/src');
    await src.filePath('a.txt').writeAsString('alpha');
    await src.filePath('b.txt').writeAsString('beta');

    // Fail copying the second file so the copy aborts part-way.
    fsBackend = _FailOnCopyBackend(original, (source) => source.endsWith('b.txt'));

    final ok = await src.copyTreeInto(DirectoryPath('${tempRoot.path}/dst'));

    expect(ok, isFalse);
    // The destination this call created is cleaned up rather than left as an
    // orphan that a caller's "destination already exists" guard would refuse.
    expect(Directory('${tempRoot.path}/dst').existsSync(), isFalse);
    expect(File('${tempRoot.path}/src/a.txt').existsSync(), isTrue);
  });

  test('a mid-copy failure removes the ancestors it created too', () async {
    final src = DirectoryPath('${tempRoot.path}/src');
    await src.filePath('a.txt').writeAsString('alpha');
    await src.filePath('b.txt').writeAsString('beta');
    // A destination several levels below the deepest existing directory: the
    // recursive create materialises `outer/` and `middle/` as well, so cleaning up
    // only the leaf would leave two empty orphans behind.
    final existing = DirectoryPath('${tempRoot.path}/existing');
    await existing.create(recursive: true);

    fsBackend = _FailOnCopyBackend(original, (source) => source.endsWith('b.txt'));

    final ok = await src.copyTreeInto(existing / 'outer' / 'middle' / 'dst');

    expect(ok, isFalse);
    expect(Directory('${tempRoot.path}/existing/outer').existsSync(), isFalse);
    // The deepest directory that predated the copy is not this call's to remove.
    expect(Directory('${tempRoot.path}/existing').existsSync(), isTrue);
  });

  test('a mid-copy failure keeps a destination that already existed', () async {
    final src = DirectoryPath('${tempRoot.path}/src');
    await src.filePath('a.txt').writeAsString('alpha');
    await src.filePath('b.txt').writeAsString('beta');
    // The destination predates the copy and carries a sentinel that must survive.
    final dst = DirectoryPath('${tempRoot.path}/dst');
    await dst.filePath('keep.txt').writeAsString('keep');

    fsBackend = _FailOnCopyBackend(original, (source) => source.endsWith('b.txt'));

    final ok = await src.copyTreeInto(dst);

    expect(ok, isFalse);
    // Cleanup only removes a destination this call created, so the pre-existing
    // one (and its sentinel) is left untouched.
    expect(File('${tempRoot.path}/dst/keep.txt').readAsStringSync(), 'keep');
  });
}

/// A web-like backend whose [copyFile] throws for sources matching [failWhen],
/// used to drive a mid-copy failure in [DirectoryPath.copyTreeInto].
class _FailOnCopyBackend extends WebLikeFsBackend {
  _FailOnCopyBackend(super.inner, this.failWhen);

  final bool Function(String source) failWhen;

  @override
  Future<void> copyFile(String source, String destination) async {
    if (failWhen(source)) {
      throw Exception('injected copy failure for $source');
    }
    return super.copyFile(source, destination);
  }
}
