// The web build has no auto-updater: it installs the recognition module into
// OPFS behind two commit markers and, from then on, decides on every boot
// whether the published module has moved.
//
// What is pinned here is silent when it goes wrong: the refusal of a response
// that is not a module -- a body that is not a zip decodes into an EMPTY
// archive instead of throwing, so committing the markers over it would tell
// every later boot that the recognizer set is installed and the ONNX payload
// would never be fetched again. (The refresh verdict itself is shared with the
// desktop loader and pinned in module_update_verdict_test.dart.)
//
// `kIsWeb` is false on the VM, so the `if (kIsWeb)` branch of
// `moduleVersionLoader` and the OPFS backend itself are NOT exercised. What is
// exercised is platform-neutral by construction: the install runs against the web-like FS backend, which fails on any synchronous
// filesystem call exactly as a browser would.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/web_module_refresh_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/version_check.dart';

import 'support/web_like_fs_backend.dart';

const _onnxSentinelFileName = ".onnx_ready";

Uint8List _bytes(String content) => Uint8List.fromList(utf8.encode(content));

/// What a server hands back when the module URL resolves to an error page or a
/// captive portal: a perfectly successful response that is not an archive.
final _htmlErrorPage = _bytes("<!doctype html><html><body>404 Not Found</body></html>");

Uint8List _moduleZip({required String version, String onnx = "onnx-payload"}) {
  final archive = Archive();
  void add(String name, Uint8List content) => archive.addFile(ArchiveFile(name, content.length, content));
  add("modules/version_info.json", _bytes('{"recognizer_version": "$version"}'));
  add("modules/recognizer.json", _bytes('{"module_path": "skill/prediction.onnx"}'));
  add("modules/skill/prediction.onnx", _bytes(onnx));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  group('a bootstrap boot installs the published module whole', () {
    // `_bootstrapWebModule` is a provider body: it needs a `Ref`, OPFS and the
    // network, none of which the VM suite has. What can be checked without them
    // is the shape of its call, and that is exactly where the defect sat -- the
    // two commit markers were threaded straight into the extraction, so a
    // browser holding only the JSON marker installed the *current* ONNX beside
    // the *previous* release's JSON and ran that pairing for a whole session.
    test('the marker state decides whether to fetch, never which half to write', () {
      final source = File('lib/src/core/version_check.dart').readAsStringSync();
      final start = source.indexOf('Future<ModuleVersion?> _bootstrapWebModule(');
      expect(start, greaterThan(0), reason: 'the bootstrap function was renamed; update this test');
      final end = source.indexOf('sealed class ModuleUpdateVerdict', start);
      expect(end, greaterThan(start), reason: 'the declaration after the bootstrap moved; update this test');
      final body = source.substring(start, end);

      expect(body, contains('_downloadAndExtractModuleToOpfs(ref.base, modulesDir, latest, archive)'));
      // Not "does it pass true": passing the marker state under any spelling is
      // the defect, so the arguments must not be there to pass at all.
      expect(body, isNot(contains('extractJson')));
      expect(body, isNot(contains('extractOnnx')));
      // The markers themselves are still read -- for the "is a fetch needed"
      // question, which is the only one they answer.
      expect(body, contains('if (!needJson && !needOnnx)'));
    });
  });

  group('automatic install refuses a response that is not a module', () {
    late Directory tempRoot;
    late DirectoryPath modulesDir;
    late FsBackend originalBackend;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('umacapture_web_module_refresh_test');
      modulesDir = DirectoryPath(tempRoot.path) / 'modules';
      originalBackend = fsBackend;
      fsBackend = WebLikeFsBackend(originalBackend);
    });
    tearDown(() {
      fsBackend = originalBackend;
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    test('a first boot served an error page commits neither marker', () async {
      await expectLater(
        installModuleArchiveBytes(_htmlErrorPage, modulesDir, extractJson: true, extractOnnx: true),
        throwsFormatException,
      );

      expect(await modulesDir.filePath('version_info.json').exists(), isFalse);
      expect(await modulesDir.filePath(_onnxSentinelFileName).exists(), isFalse);
    });

    test('the ONNX-only re-fetch does not commit its sentinel over an empty archive', () async {
      // The migration trap: a browser that already ran the Stage-5 bootstrap has
      // version_info.json but no ONNX. If a failed re-fetch committed the
      // sentinel anyway, that browser would never fetch the recognizer again.
      await installModuleArchiveBytes(
        _moduleZip(version: "2026-08-01T00:00:00+0900"),
        modulesDir,
        extractJson: true,
        extractOnnx: false,
      );
      expect(await modulesDir.filePath(_onnxSentinelFileName).exists(), isFalse);

      await expectLater(
        installModuleArchiveBytes(_htmlErrorPage, modulesDir, extractJson: false, extractOnnx: true),
        throwsFormatException,
      );

      expect(await modulesDir.filePath(_onnxSentinelFileName).exists(), isFalse);
      // The half that did land is untouched, so the retry stays an ONNX-only one.
      expect(await modulesDir.filePath('version_info.json').readAsString(), contains("2026-08-01T00:00:00+0900"));
    });

    test('a truncated transfer leaves the state the next boot needs to retry', () async {
      final truncated = Uint8List.fromList(_moduleZip(version: "2026-08-04T00:00:00+0900").sublist(0, 64));

      await expectLater(
        installModuleArchiveBytes(truncated, modulesDir, extractJson: true, extractOnnx: true),
        throwsFormatException,
      );
      expect(await modulesDir.filePath(_onnxSentinelFileName).exists(), isFalse);

      // Same call again, this time with a real body: the failure was not sticky.
      await installModuleArchiveBytes(
        _moduleZip(version: "2026-08-04T00:00:00+0900"),
        modulesDir,
        extractJson: true,
        extractOnnx: true,
      );

      expect(await modulesDir.filePath('version_info.json').readAsString(), contains("2026-08-04T00:00:00+0900"));
      expect(await (modulesDir / 'skill').filePath('prediction.onnx').readAsString(), "onnx-payload");
      expect(await modulesDir.filePath(_onnxSentinelFileName).exists(), isTrue);
    });
  });
}
