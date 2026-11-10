// Verifies CharaDetailRecordStorage.reload, which re-reads a single record from
// disk after a background rewrite (e.g. regeneration). The desktop path offloads
// the synchronous load to a worker isolate via `compute`; the web path uses the
// async OPFS loader (`CharaDetailRecord.loadAsync`). Both honor the same
// quarantine contract, so a decode failure moves the directory aside instead of
// deleting it.
//
// On the VM kIsWeb is false, so reload() exercises the desktop `compute` branch
// directly. The web branch cannot be entered from the VM, so its equivalent is
// verified through the shared `loadAsync` loader it delegates to.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/storage_reload_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/version_check.dart';

import 'support/records.dart';

void main() {
  setUpAll(initializeMappers);

  late Directory tempRoot;
  setUp(() => tempRoot = Directory.systemTemp.createTempSync('uma_reload'));
  tearDown(() => tempRoot.deleteSync(recursive: true));

  PathInfo pathInfoFor(DirectoryPath root) => PathInfo(
    documentDir: root,
    supportDir: root,
    executableDir: root / 'exe',
    downloadDir: root / 'dl',
    dataRoot: root,
  );

  // Writes [record] as record.json under [storeDir]/<id>, as the recognizer would.
  void writeRecord(DirectoryPath storeDir, CharaDetailRecord record) {
    File('${(storeDir / record.id).path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent('    ').convert(record.toMap()));
  }

  ProviderContainer makeContainer(DirectoryPath root) {
    return ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        // Skip the (network/version) module check so build() returns immediately.
        moduleVersionLoader.overrideWith((ref) async => null),
      ],
    );
  }

  test('reload replaces an in-memory record with the rewritten one (RecordLoaded)', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir, makeRecord(id: 'target', card: 1));

    final container = makeContainer(root);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);

    expect(active.getBy(id: 'target')!.trainee.card, 1);

    // A background rewrite of the same id, then reload from disk.
    writeRecord(activeDir, makeRecord(id: 'target', card: 2));
    await active.reload('target');

    // reload stages the new record via replaceBy into the pending buffer, which
    // getBy observes through the _records getter.
    expect(active.getBy(id: 'target')!.trainee.card, 2);
    expect(container.read(charaDetailRecordStorageLoaderProvider).hasError, isFalse);
  });

  test('reload quarantines a record broken on disk, leaving others intact (RecordQuarantined)', () async {
    final root = DirectoryPath(tempRoot.path);
    final info = pathInfoFor(root);
    final activeDir = info.charaDetailActiveDir;
    writeRecord(activeDir, makeRecord(id: 'keep', card: 1));
    writeRecord(activeDir, makeRecord(id: 'target', card: 2));

    final container = makeContainer(root);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);

    // Corrupt the target's record.json so the strict decoder throws on reload.
    File('${(activeDir / 'target').path}/record.json').writeAsStringSync('{}');
    await active.reload('target');

    // (a) The other record is untouched and the store never flips to error.
    expect(active.getBy(id: 'keep'), isNotNull);
    expect(active.getBy(id: 'target'), isNull, reason: 'a successfully quarantined record leaves active state');
    expect(container.read(charaDetailRecordStorageLoaderProvider).hasError, isFalse);
    // (b) The broken directory is moved aside into the sibling quarantine folder.
    expect(Directory((activeDir / 'target').path).existsSync(), isFalse);
    expect(File('${info.charaDetailQuarantineDir.path}/target/record.json').existsSync(), isTrue);
  });

  test('loadAsync decodes a valid record (web reload RecordLoaded branch)', () async {
    // The web reload branch delegates to CharaDetailRecord.loadAsync; on a valid
    // record it must return the decoded record, mirroring the desktop compute path.
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir, makeRecord(id: 'web-target', card: 7));

    final result = await CharaDetailRecord.loadAsync(activeDir / 'web-target');

    expect(result, isA<RecordLoaded>());
    expect((result as RecordLoaded).record.id, 'web-target');
    expect(result.record.trainee.card, 7);
  });

  // ISS-0027: a record whose recognition input is not all on this device cannot be re-recognised. The automatic
  // selection a store build runs must leave it out, or every build fails it again and toasts; the manual
  // whole-store request still sends it, so the failure answers the request the user made.
  group('the re-recognition a version check selects', () {
    test('a store build leaves out a record with no stitched images; the manual whole-store check sends it', () async {
      final root = DirectoryPath(tempRoot.path);
      final activeDir = pathInfoFor(root).charaDetailActiveDir;
      // Captured after the module's recognizer version and recognised by an older one: obsoleted and supported.
      const captured = '2026-06-01T00:00:00+0900';
      writeRecord(activeDir, makeRecord(id: 'imaged', card: 1, capturedDate: captured));
      writeRecord(activeDir, makeRecord(id: 'bare', card: 2, capturedDate: captured));
      // record.json is already there; the stitched PNGs and their geometry sidecars complete the input.
      for (final name in recognitionInputFileNames.where((name) => name != 'record.json')) {
        File('${(activeDir / 'imaged').path}/$name').writeAsBytesSync(const [0]);
      }
      // The shape a device that holds a record's images as JPEG only keeps (an archived record, one synced
      // without its originals): the geometry sidecars are there, the PNGs a re-recognition reads are not.
      for (final image in ['skill', 'factor', 'campaign']) {
        File('${(activeDir / 'bare').path}/$image.jpg').writeAsBytesSync(const [0]);
        File('${(activeDir / 'bare').path}/$image.json').writeAsBytesSync(const [0]);
      }
      final regeneration = _RecordingRegeneration();
      final container = ProviderContainer(
        overrides: [
          pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
          moduleVersionLoader.overrideWith(
            (ref) async => ModuleVersion(
              recognizerVersion: DateTime.utc(2026, 3),
              minimumVersion: DateTime.utc(2021),
              recognizerVersionText: '2026-03-01T09:00:00+0900',
            ),
          ),
          charaDetailRecordRegenerationControllerProvider.overrideWith(() => regeneration),
        ],
      );
      addTearDown(container.dispose);
      final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
      await container.read(charaDetailRecordStorageLoaderProvider.future);

      final automatic = await regeneration.next();
      expect(automatic, {'imaged'}, reason: 'the automatic selection sends only a record whose input is here');

      final manual = regeneration.next();
      await active.checkRecordVersion(includeCurrentVersion: true, automatic: false);
      expect(await manual, {'imaged', 'bare'}, reason: 'the manual whole-store check still sends every record');
    });
  });
}

/// Records each batch [start] is handed instead of running it.
class _RecordingRegeneration extends CharaDetailRecordRegenerationController {
  Completer<Set<String>> _batch = Completer();

  /// The ids of the next batch handed to [start].
  Future<Set<String>> next() =>
      _batch.future.timeout(const Duration(seconds: 10)).whenComplete(() => _batch = Completer());

  @override
  Future<void> start(List<CharaDetailRecord> records) async => _batch.complete({for (final r in records) r.id});
}
