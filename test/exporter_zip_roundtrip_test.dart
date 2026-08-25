// Round-trips the *desktop* ZIP exporter's real output through the app's own
// importer. The two are the pair a Windows user actually sees side by side in
// the record page, and until this test existed only the web exporter
// (RecordZipService.export) was ever fed to RecordZipService.import -- so a
// desktop zip that no importer accepted read as conformance.
//
// The export half runs the production `compute(_run, ...)` path, so the entry
// names asserted here are the bytes ZipFileEncoder really writes.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/exporter_zip_roundtrip_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/exporter.dart';
import 'package:umacapture/src/chara_detail/record_zip.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/utils.dart';

import 'support/records.dart';
import 'support/web_like_fs_backend.dart';

final _refProvider = Provider<RefBase>((ref) => ref.base);

void main() {
  setUpAll(initializeMappers);

  late Directory tempRoot;
  late FsBackend originalBackend;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_zip_roundtrip');
    originalBackend = fsBackend;
  });

  tearDown(() {
    fsBackend = originalBackend;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  PathInfo pathInfoFor(DirectoryPath root) => PathInfo(
    documentDir: root,
    supportDir: root,
    executableDir: root / 'exe',
    downloadDir: root / 'dl',
    dataRoot: root,
  );

  test('a desktop-exported zip imports back through the app importer', () async {
    final root = DirectoryPath(tempRoot.path);
    final info = pathInfoFor(root);
    final record = makeRecord(id: 'record-1', card: 7);
    // Seed active/record-1 the way a captured record looks on disk: a record.json
    // whose id matches the directory (the persistence layer refuses anything else)
    // plus one binary side file.
    final recordDir = Directory((info.charaDetailActiveDir / 'record-1').path)..createSync(recursive: true);
    File(
      '${recordDir.path}/record.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('    ').convert(record.toMap()));
    File('${recordDir.path}/trainee.jpg').writeAsBytesSync([9, 8, 7]);
    final labels = File((info.modulesDir.filePath('labels.json')).path)..createSync(recursive: true);
    labels.writeAsStringSync(jsonEncode({'character': <String>[]}));
    final output = File('${tempRoot.path}/export.zip');

    final container = ProviderContainer.test(
      overrides: [
        exportIsWebProvider.overrideWithValue(false),
        exportInitialDirectoryProvider.overrideWithValue(() async => tempRoot.path),
        exportSaveFileProvider.overrideWithValue(
          ({
            required String dialogTitle,
            required String fileName,
            String? initialDirectory,
            required Uint8List bytes,
            required bool lockParentWindow,
          }) async => output.path,
        ),
        pathInfoProvider.overrideWithValue(info),
        charaDetailRecordStorageProvider.overrideWithValue([record]),
        labelMapProvider.overrideWithValue(const {}),
      ],
    );
    addTearDown(container.dispose);

    final results = <ExportResult>[];
    await ZipExporter('Export records', 'records.zip', container.read(_refProvider), const {
      'record-1',
    }, RecordSource.active).export(onSuccess: results.add);

    expect(results, hasLength(1), reason: 'the desktop export itself must succeed');
    final bytes = Uint8List.fromList(output.readAsBytesSync());
    // The layout under test: per-id basenames plus a top-level labels.json.
    expect(ZipDecoder().decodeBytes(bytes).files.map((entry) => entry.name).toSet(), {
      'record-1/record.json',
      'record-1/trainee.jpg',
      'labels.json',
    });

    // Import into a fresh store through the web-faithful async surface, exactly
    // as the import button does.
    fsBackend = WebLikeFsBackend(originalBackend);
    final fresh = DirectoryPath(tempRoot.path) / 'imported';
    final imported = await RecordZipService.import(bytes, fresh);

    expect(imported.recordIds, {'record-1'});
    expect(imported.skippedEntries, 1, reason: 'labels.json is skipped, not written and not rejected');
    final restored = fresh / 'chara_detail' / 'active' / 'record-1';
    expect(await restored.filePath('trainee.jpg').readAsBytes(), [9, 8, 7]);
    expect(
      await restored.filePath('record.json').readAsString(),
      File('${recordDir.path}/record.json').readAsStringSync(),
    );
  });

  test('an unknown top-level file still rejects the whole import', () async {
    // The labels.json allowance is a named exception, not a general "ignore what
    // we do not understand" rule: without this case, widening it to every root
    // file would go unnoticed.
    fsBackend = WebLikeFsBackend(originalBackend);
    final archive = Archive()
      ..addFile(ArchiveFile('record-1/record.json', 2, Uint8List.fromList(utf8.encode('{}'))))
      ..addFile(ArchiveFile('notes.txt', 1, Uint8List.fromList([1])));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));

    await expectLater(RecordZipService.import(bytes, DirectoryPath(tempRoot.path) / 'rejected'), throwsFormatException);
  });
}
