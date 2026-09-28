// The storage view's totals, after the hall-of-fame archive moved records while
// the view was open.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_archive_refresh_test.dart
//
// WHY THIS WRITER AND NOT THE OTHER RECORD MUTATIONS. The storage view is a modal
// card over the settings page, and opening another dialog replaces it -- which
// unmounts the tree and makes the next open re-read everything. So a record
// mutation driven from a dialog the user is standing in front of cannot leave a
// stale number. The archive is the one that can: `archive_record_dialog.dart`
// starts the batch without awaiting it and dismisses on the next line, leaving an
// isolate moving up to a hundred record directories -- megabytes each -- out of
// `active/` and into `archive/` while the user is free to walk to
// Settings -> storage manager.
//
// Asserted at `DirectoryTotalsCache` for the reason
// `storage_record_write_refresh_test.dart` gives: the cache is where a
// directory's recursive size comes from, and it is keyed by path, so "the stale
// number is gone" is a question about it rather than about which provider was
// rebuilt.
//
// WHAT THIS SUITE DOES NOT REACH. It builds no widgets, so it says nothing about
// what is painted, and it does not press the dialog's confirm button -- it calls
// the controller that button calls. It always links the desktop executor
// (`archive_executor.dart` selects the web one with a conditional import), so the
// per-record web leg is out of reach; what is asserted here sits above that
// selection, at the end of the controller both legs return to.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/localization.dart';
import 'support/record_write_effects_fixture.dart';
import 'support/records.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    initializeMappers();
    // The batch toasts its outcome, and a toast is a translated sentence.
    loadAppTranslations();
  });

  late Directory tempRoot;
  late PathInfo layout;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_archive_refresh');
    final root = DirectoryPath(tempRoot.path);
    layout = PathInfo(
      documentDir: root,
      supportDir: root,
      executableDir: root / 'exe',
      downloadDir: root / 'dl',
      dataRoot: root,
    );
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  void writeRecord(DirectoryPath storeDir, CharaDetailRecord record) {
    File('${(storeDir / record.id).path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(record.toMap()));
  }

  void seed(DirectoryPath directory, String name, int bytes) {
    final file = File(directory.filePath(name).path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('x' * bytes);
  }

  /// Boots both record stores over the temp tree and hands back the archive
  /// controller with [gate] installed.
  Future<({ProviderContainer scope, CharaArchiveController controller})> boot(RecordRecoveryGate gate) async {
    final scope = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => layout),
        pathInfoProvider.overrideWithValue(layout),
        pathLayoutLoader.overrideWith((ref) async => layout),
        moduleVersionLoader.overrideWith((ref) async => null),
      ],
    );
    addTearDown(scope.dispose);
    await scope.read(charaDetailRecordStorageLoaderProvider.future);
    await scope.read(charaDetailArchiveStorageLoaderProvider.future);
    final controller = scope.read(charaArchiveControllerProvider.notifier);
    controller.debugRecoveryGate = gate;
    return (scope: scope, controller: controller);
  }

  /// The gate that grants everything, so the real executor moves the directory.
  RecordRecoveryGate passThrough() =>
      RecordRecoveryGate(mutationLock: RecordMutationLock((name, mode, action) => action()));

  test('the record root loses its cached total when a batch is archived', () async {
    writeRecord(layout.charaDetailActiveDir, makeRecord(id: 'moved', card: 1));
    final (:scope, :controller) = await boot(passThrough());
    final cache = scope.read(directoryTotalsCacheProvider);
    expect((await cache.totalsOf(layout.charaDetailDir)).fileCount, 1);

    await controller.archive(['moved'], ArchiveImageOption.none, effects: archiveEffects(scope));

    expect(cache.peek(layout.charaDetailDir), isNull);
    // The record really moved: it is measured under `archive/` now, and the
    // active store no longer holds it.
    expect((await cache.totalsOf(layout.charaDetailArchiveDir)).fileCount, greaterThan(0));
    expect(Directory((layout.charaDetailActiveDir / 'moved').path).existsSync(), isFalse);
  });

  // Both ends of the move are under the record root, and `invalidate` takes a
  // path's descendants with it. Asserted separately: a fix that dropped only the
  // exact path handed in would pass the case above and leave the two store rows
  // showing what the batch moved.
  test('both store directories lose their cached totals too', () async {
    writeRecord(layout.charaDetailActiveDir, makeRecord(id: 'moved', card: 1));
    final (:scope, :controller) = await boot(passThrough());
    final cache = scope.read(directoryTotalsCacheProvider);
    await cache.totalsOf(layout.charaDetailActiveDir);
    await cache.totalsOf(layout.charaDetailArchiveDir);

    await controller.archive(['moved'], ArchiveImageOption.none, effects: archiveEffects(scope));

    expect(cache.peek(layout.charaDetailActiveDir), isNull);
    expect(cache.peek(layout.charaDetailArchiveDir), isNull);
  });

  // An archive must not be reported as a change to everything: a fix that cleared
  // the whole cache would satisfy the cases above and throw away totals nothing
  // falsified, which is a re-walk of every other group on the next visit.
  test('a tree the archive cannot have touched keeps its cached total', () async {
    writeRecord(layout.charaDetailActiveDir, makeRecord(id: 'moved', card: 1));
    seed(layout.tempDir, 'scratch.bin', 32);
    final (:scope, :controller) = await boot(passThrough());
    final cache = scope.read(directoryTotalsCacheProvider);
    await cache.totalsOf(layout.charaDetailDir);
    await cache.totalsOf(layout.tempDir);

    await controller.archive(['moved'], ArchiveImageOption.none, effects: archiveEffects(scope));

    expect(cache.peek(layout.tempDir)?.knownBytes, 32);
  });

  // A batch that threw is not a batch that changed nothing: the executor can fail
  // after moving some of the records, and the batch whose lock timed out left
  // every one of them where it was. Re-measuring is the only answer that is right
  // in both cases, so the announcement is not conditioned on the outcome.
  test('a batch that fails inside the lock re-measures as well', () async {
    writeRecord(layout.charaDetailActiveDir, makeRecord(id: 'busy', card: 1));
    final gate = RecordRecoveryGate(
      mutationLock: RecordMutationLock((name, mode, action) async {
        throw RecordMutationLockBusy(name, const Duration(seconds: 150));
      }),
    );
    final (:scope, :controller) = await boot(gate);
    final cache = scope.read(directoryTotalsCacheProvider);
    await cache.totalsOf(layout.charaDetailDir);

    await controller.archive(['busy'], ArchiveImageOption.none, effects: archiveEffects(scope));

    expect(cache.peek(layout.charaDetailDir), isNull);
  });

  // The batch that never starts is the one case where nothing on disk moved, and
  // the controller returns before it claims anything at all.
  test('an empty batch announces nothing', () async {
    seed(layout.charaDetailActiveDir, 'existing.bin', 64);
    final (:scope, :controller) = await boot(passThrough());
    final cache = scope.read(directoryTotalsCacheProvider);
    await cache.totalsOf(layout.charaDetailDir);

    await controller.archive(const [], ArchiveImageOption.none, effects: archiveEffects(scope));

    expect(cache.peek(layout.charaDetailDir)?.knownBytes, 64);
  });
}
