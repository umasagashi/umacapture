// The published `version_info.json` (the pointer) names the module archive by
// `module_archive {path, sha256, size}`; the copy inside the zip does not. These
// tests pin how that reference is read, where it may point, and how a download
// is checked against it.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/module_archive_ref_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/version_check.dart';

const _pointerUrl = "https://data.umacapture.com/umacapture/version_info.json";
const _version = "2026-09-18T11:00:00+0900";

Uint8List _bytes(String content) => Uint8List.fromList(utf8.encode(content));

Uint8List _moduleZip({required String version, String payload = "onnx-payload"}) {
  final archive = Archive();
  void add(String name, Uint8List content) => archive.addFile(ArchiveFile(name, content.length, content));
  add("modules/version_info.json", _bytes('{"format_version": "1.0.0", "recognizer_version": "$version"}'));
  add("modules/skill/prediction.onnx", _bytes(payload));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

ModuleArchiveRef _refFor(List<int> bytes) =>
    ModuleArchiveRef("modules/${sha256.convert(bytes)}.zip", sha256.convert(bytes).toString(), bytes.length);

Matcher _mismatch(String reason) =>
    isA<ModuleArchiveMismatchException>().having((e) => e.message, 'message', startsWith(reason));

ModuleArchiveRef _pathRef(String path) => ModuleArchiveRef(path, "a" * 64, 1);

void main() {
  setUpAll(initializeMappers);

  group('parsing', () {
    test('ModuleVersionRawData parses a pointer carrying module_archive', () {
      // The shape tool/cloudflare/publish_modules.sh writes.
      final data = ModuleVersionRawDataMapper.fromJson('''{
        "format_version": "1.0.0",
        "region": "JPN",
        "application_version": "0.0.10",
        "minimum_version": "2025-08-24T11:00:00+0900",
        "recognizer_version": "$_version",
        "module_archive": {
          "path": "modules/${"b" * 64}.zip",
          "sha256": "${"b" * 64}",
          "size": 10386424
        }
      }''');

      expect(data.recognizerVersion, _version);
      expect(data.moduleArchive?.path, "modules/${"b" * 64}.zip");
      expect(data.moduleArchive?.sha256, "b" * 64);
      expect(data.moduleArchive?.size, 10386424);
      expect(data.moduleArchive?.isWellFormed, isTrue);
    });

    test('ModuleVersionRawData parses a local version_info without module_archive', () {
      final data = ModuleVersionRawDataMapper.fromJson(
        '{"format_version": "1.0.0", "region": "JPN", "recognizer_version": "$_version"}',
      );

      expect(data.recognizerVersion, _version);
      expect(data.moduleArchive, isNull);
    });

    test('a pointer with an unknown key still decodes', () {
      // Builds that predate module_archive read the pointer with a mapper that
      // has no such field; they keep working only because unknown keys are
      // ignored. This states that directly for the current mapper.
      final data = ModuleVersionRawDataMapper.fromJson(
        '{"format_version": "1.0.0", "region": "JPN", "recognizer_version": "$_version",'
        ' "some_future_key": {"nested": [1, 2]}}',
      );

      expect(data.recognizerVersion, _version);
    });
  });

  group('resolveArchiveUrl', () {
    test('resolveArchiveUrl resolves relative to the pointer url', () {
      expect(
        resolveArchiveUrl(_pointerUrl, _pathRef("modules/x.zip")).toString(),
        "https://data.umacapture.com/umacapture/modules/x.zip",
      );
    });

    test('resolveArchiveUrl rejects absolute, scheme-bearing, and dot-dot paths', () {
      for (final path in [
        "",
        "https://evil.example/modules/x.zip",
        "//evil.example/modules/x.zip",
        "/umacapture/modules/x.zip",
        "../modules/x.zip",
        "modules/../../x.zip",
        "modules/%2E%2E/%2E%2E/x.zip",
        "./modules/x.zip",
        "modules//x.zip",
        "modules\\x.zip",
        "modules/x.zip?a=1",
        "modules/x.zip#f",
        "data:application/zip,xx",
      ]) {
        expect(() => resolveArchiveUrl(_pointerUrl, _pathRef(path)), throwsFormatException, reason: path);
      }
    });
  });

  group('verifyModuleArchiveBytes', () {
    final zip = _moduleZip(version: _version);

    test('verifyModuleArchive accepts the matching archive', () {
      expect(() => verifyModuleArchiveBytes(zip, _refFor(zip), _version), returnsNormally);
    });

    test('verifyModuleArchive rejects bytes whose sha256 alone differs', () {
      // The stale-edge-cache case: same size and same inner version, other bytes, so only the digest
      // can refuse it.
      final other = _moduleZip(version: _version, payload: "onnx-payloaX");
      expect(other.length, zip.length);
      expect(other, isNot(equals(zip)));
      final expected = ModuleArchiveRef("modules/x.zip", sha256.convert(zip).toString(), other.length);

      expect(() => verifyModuleArchiveBytes(other, expected, _version), throwsA(_mismatch("sha256 ")));
    });

    test('verifyModuleArchive rejects a size that alone differs', () {
      // Digest and inner version match the bytes, so only the size comparison can refuse it.
      final expected = ModuleArchiveRef("modules/x.zip", sha256.convert(zip).toString(), zip.length + 1);

      expect(() => verifyModuleArchiveBytes(zip, expected, _version), throwsA(_mismatch("size ")));
    });

    test('verifyModuleArchive rejects a size mismatch', () {
      final truncated = zip.sublist(0, zip.length - 1);

      expect(
        () => verifyModuleArchiveBytes(truncated, _refFor(zip), _version),
        throwsA(isA<ModuleArchiveMismatchException>()),
      );
    });

    test('verifyModuleArchive rejects an archive whose inner recognizer_version differs from the pointer', () {
      expect(
        () => verifyModuleArchiveBytes(zip, _refFor(zip), "2026-07-21T11:00:00+0900"),
        throwsA(isA<ModuleArchiveMismatchException>()),
      );
    });
  });

  group('verifyModuleArchiveFile applies the same rule to a file', () {
    late Directory tempRoot;
    late FilePath file;
    final zip = _moduleZip(version: _version);

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('umacapture_module_archive_ref_test');
      file = FilePath('${tempRoot.path}/modules.zip');
      File(file.path).writeAsBytesSync(zip);
    });
    tearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    test('accepts the matching archive', () async {
      await expectLater(verifyModuleArchiveFile((file, _refFor(zip), _version)), completes);
    });

    test('rejects a sha256, size, or inner version mismatch', () async {
      final wrongDigest = ModuleArchiveRef("modules/x.zip", "0" * 64, zip.length);
      final wrongSize = ModuleArchiveRef("modules/x.zip", sha256.convert(zip).toString(), zip.length + 1);
      for (final (expected, version) in [
        (wrongDigest, _version),
        (wrongSize, _version),
        (_refFor(zip), "2026-07-21T11:00:00+0900"),
      ]) {
        await expectLater(
          verifyModuleArchiveFile((file, expected, version)),
          throwsA(isA<ModuleArchiveMismatchException>()),
        );
      }
    });
  });
}
