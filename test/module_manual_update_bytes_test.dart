// The manual module update on web has no filesystem path to hand over: a picked
// file reports `path == null` and a dropped one carries a blob URL, so the whole
// install has to run from the archive's bytes into the OPFS-backed store.
//
// These tests drive that byte route on the VM with the web-like FS backend
// installed, so a synchronous FS call added to the extraction fails here exactly
// as it would in a browser. `kIsWeb` is false on the VM, so the platform branch
// inside the dialog itself is not covered — only the shared extraction is.
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

Uint8List _zip(Map<String, Uint8List> entries) {
  final archive = Archive();
  entries.forEach((name, content) => archive.addFile(ArchiveFile(name, content.length, content)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _moduleZip({required String version, String onnx = "onnx-payload"}) {
  return _zip({
    "modules/version_info.json": _bytes('{"recognizer_version": "$version"}'),
    "modules/recognizer.json": _bytes('{"module_path": "skill/prediction.onnx"}'),
    "modules/skill/prediction.onnx": _bytes(onnx),
  });
}

void main() {
  late Directory tempRoot;
  late DirectoryPath modulesDir;
  late FsBackend originalBackend;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_module_update_test');
    modulesDir = DirectoryPath(tempRoot.path) / 'modules';
    originalBackend = fsBackend;
    fsBackend = WebLikeFsBackend(originalBackend);
  });
  tearDown(() {
    fsBackend = originalBackend;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  test('extracts both payloads of a manually supplied zip, stripping the modules/ wrapper', () async {
    await extractModuleZipBytes(_moduleZip(version: "2026-08-04T00:00:00+0900"), modulesDir);

    expect(await modulesDir.filePath('version_info.json').readAsString(), contains("2026-08-04T00:00:00+0900"));
    expect(await modulesDir.filePath('recognizer.json').exists(), isTrue);
    expect(await (modulesDir / 'skill').filePath('prediction.onnx').readAsString(), "onnx-payload");
    // Both commit markers must be present, or the next boot re-bootstraps over a
    // module the user just installed by hand.
    expect(await modulesDir.filePath(_onnxSentinelFileName).exists(), isTrue);
  });

  test('replaces an already installed module wholesale', () async {
    await extractModuleZipBytes(_moduleZip(version: "2026-01-01T00:00:00+0900"), modulesDir);
    await extractModuleZipBytes(_moduleZip(version: "2026-08-04T00:00:00+0900", onnx: "newer"), modulesDir);

    expect(await modulesDir.filePath('version_info.json').readAsString(), contains("2026-08-04T00:00:00+0900"));
    expect(await (modulesDir / 'skill').filePath('prediction.onnx').readAsString(), "newer");
  });

  test('creates the module directory when nothing has been installed yet', () async {
    expect(await modulesDir.exists(), isFalse);

    await extractModuleZipBytes(_moduleZip(version: "2026-08-04T00:00:00+0900"), modulesDir);

    expect(await modulesDir.filePath('version_info.json').exists(), isTrue);
  });

  test('rejects bytes that are not a zip instead of reporting an empty install', () async {
    // A non-zip decodes into an empty archive rather than throwing, so without
    // the payload check this would "succeed" and commit the markers.
    await expectLater(extractModuleZipBytes(_bytes("not a zip"), modulesDir), throwsFormatException);
    expect(await modulesDir.filePath(_onnxSentinelFileName).exists(), isFalse);
  });

  test('rejects an archive with no recognizer payload rather than committing its marker', () async {
    final jsonOnly = _zip({"modules/version_info.json": _bytes('{"recognizer_version": "2026-08-04T00:00:00+0900"}')});

    await expectLater(extractModuleZipBytes(jsonOnly, modulesDir), throwsFormatException);
    // The sentinel would otherwise tell every later boot that the ONNX set is
    // present, and it would never be fetched again.
    expect(await modulesDir.filePath(_onnxSentinelFileName).exists(), isFalse);
  });
}
