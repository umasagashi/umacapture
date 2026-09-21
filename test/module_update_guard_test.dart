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

Uint8List _moduleZipWith(String extraEntry) {
  final archive = ZipDecoder().decodeBytes(_moduleZip());
  archive.addFile(ArchiveFile(extraEntry, 7, _bytes("escaped")));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// [zip] with its central directory entry [name] restated as a Unix symbolic
/// link: `ZipEncoder` only writes MS-DOS entries, and the decoder reads a link
/// from the "made by Unix" byte and the file type in the external attributes.
Uint8List _asUnixSymlink(Uint8List zip, String name) {
  final data = ByteData.sublistView(zip);
  for (var offset = 0; offset + 46 <= zip.length; offset++) {
    if (data.getUint32(offset, Endian.little) != 0x02014b50) continue;
    final nameLength = data.getUint16(offset + 28, Endian.little);
    if (utf8.decode(zip.sublist(offset + 46, offset + 46 + nameLength)) != name) continue;
    zip[offset + 5] = 3;
    data.setUint32(offset + 38, 0xA1FF << 16, Endian.little);
    return zip;
  }
  throw ArgumentError(name);
}

/// The archives the two install routes have to agree about.
///
/// `holdsModule` is the *expected* verdict, not a reading of the implementation:
/// a route that accepts anything, or refuses everything, fails on one half of
/// this table or the other.
final _corpus = <String, bool>{
  "a module zip": true,
  "an HTML error page served with a 200": false,
  "a zip with only the version marker": false,
  "a zip with only the recognizer payload": false,
  "an empty zip": false,
  ..._unsafeNameCorpus,
};

/// Entry names that would extract outside the module directory, or that the
/// publish script refuses. Each is added to an otherwise valid module zip, so
/// the name is the only reason to refuse it.
const _unsafeNames = <String>[
  "modules/../escaped.txt",
  "modules/skill/../../escaped.txt",
  "modules/./skill/prediction2.onnx",
  "modules//skill/prediction2.onnx",
  "modules/skill\\..\\..\\escaped.txt",
  "modules/C:/escaped.txt",
  "modules/skill/esc\u0001aped.onnx",
  "../escaped.txt",
  "/escaped.txt",
  "C:/escaped.txt",
  "escaped.txt",
];

final _unsafeNameCorpus = <String, bool>{for (final name in _unsafeNames) "a module zip with entry '$name'": false};

Uint8List _archiveNamed(String name) => switch (name) {
  "a module zip" => _moduleZip(),
  "an HTML error page served with a 200" => _bytes("<html><body>Sign in to the network</body></html>"),
  "a zip with only the version marker" => _zip({"modules/version_info.json": _bytes("{}")}),
  "a zip with only the recognizer payload" => _zip({"modules/skill/prediction.onnx": _bytes("onnx")}),
  "an empty zip" => _zip(const {}),
  _ => _moduleZipWith(_unsafeNames.singleWhere((unsafe) => name == "a module zip with entry '$unsafe'")),
};

/// Awaits [route] and returns what it threw, or null when it completed.
///
/// Captured rather than asserted inline so a refusal test can check that nothing
/// was written *before* it checks the exception: a route that writes and then
/// fails on an I/O error has already broken the rule, whatever it threw.
Future<Object?> _thrownBy(Future<void> route) async {
  try {
    await route;
    return null;
  } catch (error) {
    return error;
  }
}

/// Every path under [dir], empty when [dir] does not exist.
List<String> _writtenUnder(DirectoryPath dir) {
  final directory = Directory(dir.path);
  if (!directory.existsSync()) return const [];
  return [for (final entity in directory.listSync(recursive: true)) entity.path];
}

/// The refusal the entry-name rule raises for [name], and nothing else.
///
/// Pinned to the message and the offending name, not only to the exception type,
/// so a refusal that comes from somewhere else -- the payload check, or the
/// platform refusing a path during extraction -- does not satisfy it.
Matcher _refusedForEntry(String name) => isA<FormatException>()
    .having((e) => e.message, 'message', 'The archive has an unsafe entry name.')
    .having((e) => e.source, 'source', name);

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
      final unsafeEntry = _unsafeNames.where((name) => entry.key == "a module zip with entry '$name'").firstOrNull;
      test('${entry.key}: ${entry.value ? "accepted" : "refused"} by both routes', () async {
        final bytes = _archiveNamed(entry.key);

        // The byte route, as the web bootstrap and the manual byte install use it.
        final byteTarget = outDir / 'bytes';
        final byteError = await _thrownBy(
          installModuleArchiveBytes(bytes, byteTarget, extractJson: true, extractOnnx: true),
        );
        // The file route, as `moduleVersionLoader` and `installModuleFromZip` use it.
        final fileTarget = outDir / 'file';
        final fileError = await _thrownBy(
          installModuleArchiveFile((writeZip('${entry.key.hashCode}.zip', bytes), fileTarget)),
        );

        if (entry.value) {
          expect(byteError, isNull);
          expect(fileError, isNull);
          // Negative control: a real module still installs by both routes.
          expect(await byteTarget.filePath('version_info.json').exists(), isTrue);
          expect(File('${fileTarget.path}/modules/version_info.json').existsSync(), isTrue);
        } else {
          // The refusal has to happen before the first write, or the commit
          // markers would be laid over nothing (and an unsafe name would already
          // have been written wherever it points).
          expect(_writtenUnder(byteTarget), isEmpty, reason: 'byte route wrote before refusing');
          expect(_writtenUnder(fileTarget), isEmpty, reason: 'file route wrote before refusing');
          final refusal = unsafeEntry == null ? isA<FormatException>() : _refusedForEntry(unsafeEntry);
          expect(byteError, refusal);
          expect(fileError, refusal);
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

  test('a name escaping modules/ is not written beside it in the data root', () async {
    // The file route extracts into the data root (`modulesDir.parent`), and the
    // archive package only keeps a name within that directory, so without the
    // name check `modules/../escaped.txt` lands at `<data root>/escaped.txt`.
    final dataRoot = outDir / 'data_root';
    await dataRoot.create(recursive: true);

    final error = await _thrownBy(
      installModuleArchiveFile((writeZip('slip.zip', _moduleZipWith("modules/../escaped.txt")), dataRoot)),
    );

    expect(File('${dataRoot.path}/escaped.txt').existsSync(), isFalse);
    expect(_writtenUnder(dataRoot), isEmpty);
    expect(error, _refusedForEntry("modules/../escaped.txt"));
  });

  test('a symbolic link entry is refused by both routes', () async {
    final bytes = _asUnixSymlink(_moduleZipWith("modules/skill/link.onnx"), "modules/skill/link.onnx");
    // Guards the fixture: the round trip has to keep the entry a link.
    expect(ZipDecoder().decodeBytes(bytes).any((file) => file.isSymbolicLink), isTrue);

    final byteError = await _thrownBy(
      installModuleArchiveBytes(bytes, outDir / 'bytes', extractJson: true, extractOnnx: true),
    );
    final fileError = await _thrownBy(installModuleArchiveFile((writeZip('link.zip', bytes), outDir / 'file')));

    // Refused before extraction, not after: the link is the last entry, so an
    // install that checks late has already written the module beside it.
    expect(_writtenUnder(outDir / 'bytes'), isEmpty);
    expect(_writtenUnder(outDir / 'file'), isEmpty);
    expect(byteError, _refusedForEntry("modules/skill/link.onnx"));
    expect(fileError, _refusedForEntry("modules/skill/link.onnx"));
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
