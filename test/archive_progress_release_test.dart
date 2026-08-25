// The bulk archive has to release its progress state however it ends.
//
// `CharaArchiveController.archive` publishes a non-empty `Progress` before
// awaiting the executor, and the record table renders that progress *instead of*
// the table for as long as it is non-empty. The provider is a plain
// `NotifierProvider` (not auto-disposed) that nothing ever invalidates or
// refreshes, so a `Progress` left published outlives every navigation and record
// source switch: the only recovery is an app restart. The awaited call has at
// least three ways to throw that never reach the executor's own try/catch --
//
//  1. the mutation lock's acquisition budget expiring (`RecordMutationLockBusy`),
//  2. web's per-record recovery (`_ensureRecordReady`) raising a bare
//     `StateError` from inside the lock and *before* the archive action runs,
//  3. desktop failing to spawn or feed the `compute` isolate,
//
// -- and each of them used to leave the table behind a spinner with nothing said
// to the user. The two tests below drive (1) and (2) at their real positions in
// the gate, and require both the release and a user-facing failure. Two further
// tests are negative controls: the ordinary success must stay a plain success
// with no error toast, so "always report failed" is not a way to pass, and an
// empty batch must not publish a progress at all.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/archive_progress_release_test.dart
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
import 'package:umacapture/src/gui/toast.dart';

import 'support/localization.dart';
import 'support/records.dart';

void main() {
  setUpAll(() {
    initializeMappers();
    loadAppTranslations();
  });

  late Directory tempRoot;

  setUp(() {
    // Everything this suite touches lives under this temp directory: the
    // container's `pathInfoLoader` is overridden to it, so no test here can reach
    // the real data root.
    tempRoot = Directory.systemTemp.createTempSync('uma_archive_progress');
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  PathInfo pathInfoFor(DirectoryPath root) => PathInfo(
    documentDir: root,
    supportDir: root,
    executableDir: root / 'exe',
    downloadDir: root / 'dl',
    dataRoot: root,
  );

  void writeRecord(DirectoryPath directory, CharaDetailRecord record) {
    File('${directory.path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent('    ').convert(record.toMap()));
  }

  ProviderContainer makeContainer(DirectoryPath root) {
    return ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
      ],
    );
  }

  List<ToastData> listenToasts(ProviderContainer container) {
    final toasts = <ToastData>[];
    final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
    addTearDown(subscription.close);
    return toasts;
  }

  /// Builds both stores and returns the archive controller with [gate] installed.
  Future<CharaArchiveController> controllerFor(ProviderContainer container, RecordRecoveryGate? gate) async {
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    final controller = container.read(charaArchiveControllerProvider.notifier);
    controller.debugRecoveryGate = gate;
    return controller;
  }

  test('a batch whose lock acquisition times out releases the progress and says so', () async {
    final root = DirectoryPath(tempRoot.path);
    writeRecord(pathInfoFor(root).charaDetailActiveDir / 'busy-a', makeRecord(id: 'busy-a', card: 1));
    final container = makeContainer(root);
    addTearDown(container.dispose);
    // The real failure the acquisition budget produces, raised where the real
    // runner raises it: from the lock runner, before any action runs.
    final gate = RecordRecoveryGate(
      mutationLock: RecordMutationLock((name, mode, action) async {
        throw RecordMutationLockBusy(name, const Duration(seconds: 150));
      }),
    );
    final controller = await controllerFor(container, gate);
    final toasts = listenToasts(container);

    await controller.archive(['busy-a'], ArchiveImageOption.none);
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(charaArchiveControllerProvider).isEmpty,
      isTrue,
      reason: 'a non-empty progress hides the record table until the app restarts',
    );
    expect(toasts.map((toast) => toast.type), contains(ToastType.error));
    expect(
      toasts.firstWhere((toast) => toast.type == ToastType.error).description,
      appSentenceAt('pages.chara_detail.archive_records.error').replaceAll('{count}', '1'),
    );
    // Nothing was archived, so the record is still where the user left it.
    expect(Directory((pathInfoFor(root).charaDetailActiveDir / 'busy-a').path).existsSync(), isTrue);
  });

  test('a batch refused by record recovery inside the lock releases the progress and says so', () async {
    final root = DirectoryPath(tempRoot.path);
    writeRecord(pathInfoFor(root).charaDetailActiveDir / 'stuck-a', makeRecord(id: 'stuck-a', card: 1));
    writeRecord(pathInfoFor(root).charaDetailActiveDir / 'stuck-b', makeRecord(id: 'stuck-b', card: 2));
    final container = makeContainer(root);
    addTearDown(container.dispose);
    var lockedNames = 0;
    // The web gate's shape: the lock is granted, and `ensureReady` throws from
    // inside it, before the archive action the executor wraps in its own
    // try/catch. `record_recovery_gate_web.dart` throws a bare `StateError` there
    // when a transaction slot blocks the record.
    final gate = RecordRecoveryGate(
      mutationLock: RecordMutationLock((name, mode, action) async {
        lockedNames++;
        return action();
      }),
      ensureReady: (storageRoot, recordId) async {
        throw StateError('Record $recordId is unavailable while web write recovery is blocked.');
      },
    );
    final controller = await controllerFor(container, gate);
    final toasts = listenToasts(container);

    await controller.archive(['stuck-a', 'stuck-b'], ArchiveImageOption.none);
    await Future<void>.delayed(Duration.zero);

    // The throw really came from inside the lock, not from the acquisition.
    expect(lockedNames, greaterThan(0));
    expect(container.read(charaArchiveControllerProvider).isEmpty, isTrue);
    expect(toasts.map((toast) => toast.type), contains(ToastType.error));
    expect(
      toasts.firstWhere((toast) => toast.type == ToastType.error).description,
      appSentenceAt('pages.chara_detail.archive_records.error').replaceAll('{count}', '2'),
      reason: 'every id of the batch failed, and the count has to say so',
    );
    expect(Directory((pathInfoFor(root).charaDetailActiveDir / 'stuck-a').path).existsSync(), isTrue);
  });

  // Negative control for both tests above: releasing the progress and reporting a
  // failure must not be what the controller does unconditionally.
  test('an archive that succeeds still reports a plain success and leaves no progress', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir / 'ok-a', makeRecord(id: 'ok-a', card: 1));
    final container = makeContainer(root);
    addTearDown(container.dispose);
    final gate = RecordRecoveryGate(mutationLock: RecordMutationLock((name, mode, action) => action()));
    final controller = await controllerFor(container, gate);
    final toasts = listenToasts(container);

    await controller.archive(['ok-a'], ArchiveImageOption.none);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(charaArchiveControllerProvider).isEmpty, isTrue);
    expect(toasts.where((toast) => toast.type == ToastType.error), isEmpty);
    expect(toasts.map((toast) => toast.type), contains(ToastType.success));
    expect(Directory((activeDir / 'ok-a').path).existsSync(), isFalse);
    expect(Directory((pathInfoFor(root).charaDetailArchiveDir / 'ok-a').path).existsSync(), isTrue);
  });

  test('an empty batch publishes no progress and no toast', () async {
    final root = DirectoryPath(tempRoot.path);
    final container = makeContainer(root);
    addTearDown(container.dispose);
    final controller = await controllerFor(container, null);
    final toasts = listenToasts(container);

    await controller.archive(const [], ArchiveImageOption.none);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(charaArchiveControllerProvider).isEmpty, isTrue);
    expect(toasts, isEmpty);
  });
}
