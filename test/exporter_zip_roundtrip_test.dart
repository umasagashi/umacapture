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
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/exporter.dart';
import 'package:umacapture/src/chara_detail/record_body.dart';
import 'package:umacapture/src/chara_detail/record_zip.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/chara_detail/value_write_time.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/utils.dart';

import 'support/long_read_declarations.dart';
import 'support/record_binding_seed.dart';
import 'support/records.dart';
import 'support/web_like_fs_backend.dart';

final _refProvider = Provider<RefBase>((ref) => ref.base);

/// A ref over a container whose record stores are never built, for an export that has no stores to update.
RefBase _refWithoutStores() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container.read(containerRefProvider);
}

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
    valueWriteClock = () => 1700000000000;
    addTearDown(() => valueWriteClock = () => DateTime.now().millisecondsSinceEpoch);
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
    // The record the export carried, with the binding it placed (there was no image to bind) and, in the same write,
    // the geometry (none either) and the name of the icon it holds, written at the time of the import into a store that
    // held none.
    expect(
      CharaDetailRecord.fromRecordJson(await restored.filePath('record.json').readAsString()),
      placeOnRecord(
        composeBodyWrite(null, record, icon: null)!,
        images: (
          binding: const RecordBinding(),
          geometry: const RecordGeometry(),
          icon: sha256.convert([9, 8, 7]).toString(),
        ),
      ),
    );
  });

  /// The desktop export of [kind]'s record, seeded under `active/`: its decoded entries, and the names its central
  /// directory lists. A decoded [Archive] keeps one entry per name, so only the second counts two entries of one
  /// name as two.
  Future<({List<ArchiveFile> files, List<String> names})> exportDesktop(PathInfo info, UnboundRecord kind) async {
    final record = CharaDetailRecord.fromRecordJson(File(kind.fixture).readAsStringSync());
    File(info.modulesDir.filePath('labels.json').path)
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'character': <String>[]}));
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
    await ZipExporter('Export records', 'records.zip', container.read(_refProvider), {
      kind.id,
    }, RecordSource.active).export(onSuccess: results.add);
    expect(results, hasLength(1), reason: 'the desktop export itself must succeed');
    final bytes = output.readAsBytesSync();
    final directory = ZipDirectory()..read(InputMemoryStream(bytes));
    return (
      files: ZipDecoder().decodeBytes(bytes).files,
      names: [for (final header in directory.fileHeaders) header.filename],
    );
  }

  group('a record without a binding goes out with one worked out from its PNGs', () {
    List<int> contentOf(List<ArchiveFile> entries, String name) =>
        entries.where((entry) => entry.name == name).firstOrNull?.content ?? const [];

    test('the desktop export places it and carries it', () async {
      final info = pathInfoFor(DirectoryPath(tempRoot.path));
      final pngs = bindingImagePngs();
      final dir = seedUnboundRecord(info.charaDetailActiveDir.path, UnboundRecord.legacy, pngs);

      final entries = await exportDesktop(info, UnboundRecord.legacy);

      final id = UnboundRecord.legacy.id;
      expect(bindingIn(contentOf(entries.files, '$id/record.json')), expectedBinding(pngs));
      expect(bindingIn(File('$dir/record.json').readAsBytesSync()), expectedBinding(pngs), reason: 'placed');
      expect(entries.names.where((name) => name == '$id/record.json'), hasLength(1));
    });

    test('the web export places it and carries it', () async {
      final info = pathInfoFor(DirectoryPath(tempRoot.path));
      final pngs = bindingImagePngs();
      final dir = seedUnboundRecord(info.charaDetailActiveDir.path, UnboundRecord.captured, pngs);

      final bytes = await RecordZipService.export(
        [DirectoryPath(dir)],
        ref: _refWithoutStores(),
        declaration: undeclaredInTest,
      );

      final id = UnboundRecord.captured.id;
      final recordJson = ZipDecoder().decodeBytes(bytes).findFile('chara_detail/active/$id/record.json');
      expect(bindingIn(recordJson?.content ?? const []), expectedBinding(pngs));
      expect(bindingIn(File('$dir/record.json').readAsBytesSync()), expectedBinding(pngs), reason: 'placed');
    });

    test(
      'a record.json that cannot be rewritten still goes out with the binding',
      () async {
        final info = pathInfoFor(DirectoryPath(tempRoot.path));
        final pngs = bindingImagePngs();
        final dir = seedUnboundRecord(info.charaDetailActiveDir.path, UnboundRecord.captured, pngs);
        await setReadOnly('$dir/record.json', readOnly: true);
        addTearDown(() => setReadOnly('$dir/record.json', readOnly: false));

        final entries = await exportDesktop(info, UnboundRecord.captured);

        final id = UnboundRecord.captured.id;
        expect(bindingIn(contentOf(entries.files, '$id/record.json')), expectedBinding(pngs));
        expect(bindingIn(File('$dir/record.json').readAsBytesSync()), isNull, reason: 'the file stayed as it was');
        expect(entries.names, isNot(contains('$id/record.json.part')));
      },
      skip: Platform.isWindows ? false : windowsOnlyReadOnly,
    );
  });

  group('a record leaves without what only this device holds, and keeps it', () {
    Future<void> expectImports(Uint8List bytes, String id) async {
      fsBackend = WebLikeFsBackend(originalBackend);
      final imported = await RecordZipService.import(bytes, DirectoryPath(tempRoot.path) / 'imported');
      expect(imported.recordIds, {id});
      expect(imported.refusals, isEmpty);
    }

    test('the desktop export packs the export table and imports', () async {
      final info = pathInfoFor(DirectoryPath(tempRoot.path));
      final dir = seedUnboundRecord(info.charaDetailActiveDir.path, UnboundRecord.legacy, bindingImagePngs());
      seedRecordLocalFields(dir);
      final before = recordDirectoryNames(dir);

      final entries = await exportDesktop(info, UnboundRecord.legacy);

      final id = UnboundRecord.legacy.id;
      final contents = {for (final file in entries.files) file.name: file.content};
      expectRecordLeftWithoutLocalFields(entries.names, id, (name) => contents[name] ?? const []);
      expect(recordDirectoryNames(dir), namesAfterPlacing(before), reason: 'nothing else is removed');
      final local = jsonDecode(File('$dir/record.json').readAsStringSync()) as Map<String, Object?>;
      expect((local['metadata'] as Map<String, Object?>)['body_written_at'], seededBodyWrittenAt);
      await expectImports(Uint8List.fromList(File('${tempRoot.path}/export.zip').readAsBytesSync()), id);
    });

    test('the web export packs the export table and imports', () async {
      final info = pathInfoFor(DirectoryPath(tempRoot.path));
      final dir = seedUnboundRecord(info.charaDetailActiveDir.path, UnboundRecord.captured, bindingImagePngs());
      seedRecordLocalFields(dir);
      final before = recordDirectoryNames(dir);

      final bytes = await RecordZipService.export(
        [DirectoryPath(dir)],
        ref: _refWithoutStores(),
        declaration: undeclaredInTest,
      );

      final id = UnboundRecord.captured.id;
      final archive = ZipDecoder().decodeBytes(bytes);
      expectRecordLeftWithoutLocalFields(
        zipEntryNames(bytes),
        'chara_detail/active/$id',
        (name) => archive.findFile(name)?.content ?? const [],
      );
      expect(recordDirectoryNames(dir), namesAfterPlacing(before), reason: 'nothing else is removed');
      await expectImports(bytes, id);
    });
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
