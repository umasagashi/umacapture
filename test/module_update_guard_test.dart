// The refusal that decides whether a downloaded or picked archive is a module,
// and the cleanup of the temp archive the desktop updater downloads.
//
// The desktop route used to skip the refusal the web route performs: bytes that
// are not an archive decode into an *empty* zip rather than throwing, so nothing
// was written, nothing threw, and the updater reported "module updated" for a
// module that is not on disk. These tests state that both routes now apply the
// same rule, by running one corpus through both.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/module_update_guard_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/version_check.dart';

Uint8List _bytes(String content) => Uint8List.fromList(utf8.encode(content));

Uint8List _zip(Map<String, Uint8List> entries) {
  final archive = Archive();
  entries.forEach((name, content) => archive.addFile(ArchiveFile(name, content.length, content)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _moduleZip() => _zip({
  "modules/version_info.json": _bytes('{"recognizer_version": "2026-08-04T00:00:00+0900"}'),
  "modules/recognizer.json": _bytes('{"module_path": "skill/prediction.onnx"}'),
  "modules/skill/prediction.onnx": _bytes("onnx-payload"),
});

/// The archives the two install routes have to agree about.
///
/// `holdsModule` is the *expected* verdict, not a reading of the implementation:
/// a route that accepts anything, or refuses everything, fails on one half of
/// this table or the other.
const _corpus = <String, bool>{
  "a module zip": true,
  "an HTML error page served with a 200": false,
  "a zip with only the version marker": false,
  "a zip with only the recognizer payload": false,
  "an empty zip": false,
};

Uint8List _archiveNamed(String name) => switch (name) {
  "a module zip" => _moduleZip(),
  "an HTML error page served with a 200" => _bytes("<html><body>Sign in to the network</body></html>"),
  "a zip with only the version marker" => _zip({"modules/version_info.json": _bytes("{}")}),
  "a zip with only the recognizer payload" => _zip({"modules/skill/prediction.onnx": _bytes("onnx")}),
  "an empty zip" => _zip(const {}),
  _ => throw ArgumentError(name),
};

/// A backend whose async delete always refuses, the way a file still held by the
/// just-finished `compute` isolate does on Windows.
class _DeleteRefusingBackend implements FsBackend {
  _DeleteRefusingBackend(this.inner);

  final FsBackend inner;
  int attempts = 0;

  @override
  Future<bool> exists(String path) => inner.exists(path);

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    attempts++;
    throw const FileSystemException("The process cannot access the file");
  }

  // Nothing else is reachable from the code under test; a call would be a
  // NoSuchMethodError naming the member rather than a silent pass.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory tempRoot;
  late DirectoryPath outDir;
  late FsBackend originalBackend;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_module_guard_test');
    outDir = DirectoryPath(tempRoot.path) / 'out';
    originalBackend = fsBackend;
  });
  tearDown(() {
    fsBackend = originalBackend;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  FilePath writeZip(String name, Uint8List content) {
    final file = File('${tempRoot.path}/$name');
    file.writeAsBytesSync(content);
    return FilePath(file.path);
  }

  group('the file route (desktop) and the byte route (web) apply one rule', () {
    for (final entry in _corpus.entries) {
      test('${entry.key}: ${entry.value ? "accepted" : "refused"} by both routes', () async {
        final bytes = _archiveNamed(entry.key);

        // The byte route, as the web bootstrap and the manual byte install use it.
        final byteTarget = outDir / 'bytes';
        final byteRoute = installModuleArchiveBytes(bytes, byteTarget, extractJson: true, extractOnnx: true);
        // The file route, as `moduleVersionLoader` and `installModuleFromZip` use it.
        final fileTarget = outDir / 'file';
        final fileRoute = installModuleArchiveFile((writeZip('${entry.key.hashCode}.zip', bytes), fileTarget));

        if (entry.value) {
          await byteRoute;
          await fileRoute;
          // Negative control: a real module still installs by both routes.
          expect(await byteTarget.filePath('version_info.json').exists(), isTrue);
          expect(File('${fileTarget.path}/modules/version_info.json').existsSync(), isTrue);
        } else {
          await expectLater(byteRoute, throwsFormatException);
          await expectLater(fileRoute, throwsFormatException);
          // The refusal has to happen before the first write, or the commit
          // markers would be laid over nothing.
          expect(Directory(byteTarget.path).existsSync(), isFalse);
          expect(Directory(fileTarget.path).existsSync(), isFalse);
        }
      });
    }
  });

  test('a refused file archive leaves the extraction target untouched, not half-written', () async {
    // The concrete claim behind S13-04: the old route wrote nothing *and* threw
    // nothing, so its caller toasted success. Now it throws.
    final target = outDir / 'existing';
    await target.create(recursive: true);
    await target.filePath('version_info.json').writeAsString('{"recognizer_version": "old"}');

    await expectLater(
      installModuleArchiveFile((writeZip('portal.zip', _bytes("<html>portal</html>")), target)),
      throwsFormatException,
    );

    expect(await target.filePath('version_info.json').readAsString(), contains("old"));
  });

  group('the downloaded temp archive is cleaned up', () {
    test('the delete is waited for: the file is gone when the future completes', () async {
      final path = writeZip('modules.zip', _moduleZip());
      expect(File(path.path).existsSync(), isTrue);

      await deleteDownloadedArchive(path);

      expect(File(path.path).existsSync(), isFalse);
    });

    test('an already absent archive is not an error', () async {
      await deleteDownloadedArchive(FilePath('${tempRoot.path}/never-downloaded.zip'));
    });

    test('a refused delete is logged, not raised: it must not replace the update outcome', () async {
      final backend = _DeleteRefusingBackend(originalBackend);
      fsBackend = backend;
      final path = writeZip('locked.zip', _moduleZip());

      // Un-awaited, this rejection became an unhandled asynchronous error.
      await deleteDownloadedArchive(path);

      // The retry loop ran and then gave up, rather than the failure being
      // swallowed before it was ever attempted.
      expect(backend.attempts, 3);
    });
  });

  test('the desktop updater awaits its cleanup, in a finally', () {
    // The call site sits inside a provider that performs a real network download,
    // so there is no seam to drive it from a test. What can be stated is the
    // shape of the source, the way `app_root_scrub_test` pins `_sentryBeforeSend`.
    final source = File('lib/src/core/version_check.dart').readAsStringSync();

    expect(source, contains('} finally {'));
    expect(source, contains('await deleteDownloadedArchive(downloadPath);'));
    // The old defect verbatim: a fire-and-forget delete on the raw dart:io File.
    expect(source, isNot(contains('.toFile().delete()')));
    // Every mention other than the declaration itself has to be awaited, or the
    // same class of defect is back at a different call site.
    final mentions = RegExp(r'\bdeleteDownloadedArchive\(').allMatches(source).length;
    final awaited = RegExp(r'\bawait deleteDownloadedArchive\(').allMatches(source).length;
    expect(mentions - awaited, 1, reason: 'only the declaration may be unawaited');
  });
}
