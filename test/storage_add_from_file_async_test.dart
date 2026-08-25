// Verifies the incremental, web-safe add path (CharaDetailRecordStorage.
// addFromFileAsync) the video import uses: a freshly written record is merged
// into the active set one at a time, and a record whose record.json cannot be
// decoded is quarantined without disturbing the already-loaded records or
// tipping the store into an error state.
//
// Drives the real CharaDetailRecordStorage notifier over temp directories, the
// same ProviderContainer style as storage_archive_inheritance_test.dart.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/storage_add_from_file_async_test.dart
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
  setUp(() => tempRoot = Directory.systemTemp.createTempSync('uma_add_async'));
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

  test('adds a freshly written record incrementally, keeping the existing ones', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir, makeRecord(id: 'existing', card: 1));

    final container = makeContainer(root);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);

    // A distinct chara (different card) written to disk as the harvest would.
    writeRecord(activeDir, makeRecord(id: 'fresh', card: 2));
    await active.addFromFileAsync('fresh');

    expect(active.getBy(id: 'existing'), isNotNull);
    expect(active.getBy(id: 'fresh'), isNotNull);
    expect(active.length, 2);
    expect(container.read(charaDetailRecordStorageLoaderProvider).hasError, isFalse);
  });

  test('quarantines a broken record without dropping existing ones or erroring', () async {
    final root = DirectoryPath(tempRoot.path);
    final info = pathInfoFor(root);
    final activeDir = info.charaDetailActiveDir;
    writeRecord(activeDir, makeRecord(id: 'valid', card: 1));

    final container = makeContainer(root);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);

    // A record whose record.json cannot be decoded, written into active/<id>.
    final brokenDir = activeDir / 'broken';
    File('${brokenDir.path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    File('${brokenDir.path}/trainee.jpg').writeAsStringSync('img');

    await active.addFromFileAsync('broken');

    // (a) The already-loaded record is untouched; the broken one is not added.
    expect(active.getBy(id: 'valid'), isNotNull);
    expect(active.getBy(id: 'broken'), isNull);
    expect(active.length, 1);
    // (b) The broken directory is moved aside into the sibling quarantine folder.
    expect(Directory(brokenDir.path).existsSync(), isFalse);
    expect(File('${info.charaDetailQuarantineDir.path}/broken/record.json').existsSync(), isTrue);
    // (c) The store stays in a data state rather than flipping to AsyncError.
    expect(container.read(charaDetailRecordStorageLoaderProvider).hasError, isFalse);
  });
}
