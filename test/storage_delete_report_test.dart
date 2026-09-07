// How the record stores account for work they did not do.
//
// Three claims are pinned here, all of the same family - "the operation reports
// what actually happened to every id it was handed":
//
//  1. A bulk delete used to drop an id it could not see from *both* the
//     succeeded and the failed set, so the result read as a plain success while
//     the directory stayed on disk. These tests require the id to come back as
//     failed, and require the ordinary all-deletable case to still read as a
//     plain success - a "report everything as failed" implementation is rejected
//     by the second test just as a "report everything as succeeded" one is
//     rejected by the first.
//  2. A bulk delete used to run every id's recovery as a precondition of one
//     indivisible action, so a single record whose recovery threw aborted the
//     whole gesture and returned no result for any id. The two gate tests
//     require that failure to be exactly one record wide.
//  3. A record merge that fails leaves the record on disk and out of the list.
//     Its caller only logs, so the failure had no user-facing form at all. The
//     last test drives the merge into the one failure it raises itself (the id
//     set never settling) and requires both the error toast and the throw.
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

import 'support/records.dart';

void main() {
  setUpAll(initializeMappers);

  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_delete_report');
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

  ProviderContainer makeGrowingContainer(DirectoryPath root, RecordMutationLock lock) {
    return ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
        charaDetailRecordStorageLoaderProvider.overrideWith(() => _GrowingActiveStorage(lock)),
      ],
    );
  }

  List<ToastData> listenToasts(ProviderContainer container) {
    final toasts = <ToastData>[];
    final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
    addTearDown(subscription.close);
    return toasts;
  }

  /// Lets the toast's event turn run before [listenToasts]'s list is read.
  ///
  /// Toasts leave through a stream provider, so an assertion made in the same
  /// turn as the delete reads a list the notification has not reached yet. This
  /// matters most where the assertion is that *no* error toast was raised: that
  /// one passes on an empty list however the delete went, so without this it is
  /// not a negative control at all.
  Future<void> settleToasts() => Future<void>.delayed(Duration.zero);

  test('active bulk delete reports an id the store cannot see as failed, not as an omission', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir / 'known', makeRecord(id: 'known', card: 1));
    final container = makeContainer(root);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    // Written after the scan, so it is absent from memory while its directory is
    // very much still on disk - the exact state a record the scan could not open
    // leaves behind on web.
    writeRecord(activeDir / 'stranger', makeRecord(id: 'stranger', card: 2));
    final toasts = listenToasts(container);

    final result = await active.deleteAllAsync(['known', 'stranger']);

    expect(result.failed, {'stranger'});
    expect(result.succeeded, {'known'});
    expect(result.isSuccess, isFalse);
    // Why the accounting matters: the id reported on is still a directory.
    expect(Directory((activeDir / 'stranger').path).existsSync(), isTrue);
    expect(Directory((activeDir / 'known').path).existsSync(), isFalse);
    await settleToasts();
    expect(toasts.map((toast) => toast.type), contains(ToastType.error));
  });

  test('active single delete of an id the store cannot see is not a success', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir / 'known', makeRecord(id: 'known', card: 1));
    final container = makeContainer(root);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    writeRecord(activeDir / 'stranger', makeRecord(id: 'stranger', card: 2));

    final result = await active.deleteAsync('stranger');

    expect(result.succeeded, isEmpty);
    expect(result.failed, {'stranger'});
    expect(result.isSuccess, isFalse);
    expect(Directory((activeDir / 'stranger').path).existsSync(), isTrue);
  });

  // Negative control for both tests above: the ordinary case must stay a plain
  // success with no error toast, so "classify every id as failed" is not a way to
  // pass them.
  test('active bulk delete of ids the store owns still reports a plain success', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir / 'a', makeRecord(id: 'a', card: 1));
    writeRecord(activeDir / 'b', makeRecord(id: 'b', card: 2));
    final container = makeContainer(root);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    final toasts = listenToasts(container);

    final result = await active.deleteAllAsync(['a', 'b']);

    expect(result.succeeded, {'a', 'b'});
    expect(result.failed, isEmpty);
    expect(result.isSuccess, isTrue);
    expect(active.records, isEmpty);
    await settleToasts();
    expect(toasts.where((toast) => toast.type == ToastType.error), isEmpty);
  });

  // Claim 3 of the same family, and the one reachable input the two above do not
  // cover: the per-record recovery the delete runs under is *installed to throw*
  // (the web leg cleans up a committed archive transaction with
  // `failOnError: true`, and either leg's slot probe can raise a filesystem
  // error). A bulk delete used to make every id's recovery a precondition of one
  // indivisible action, so a single unrecoverable record aborted the whole
  // gesture: nothing was erased and the call produced no [RecordDeleteResult] at
  // all, leaving the dialog unable to name either what went or what stayed.
  test('active bulk delete fails only the record whose recovery throws and still deletes the rest', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir / 'unrecoverable', makeRecord(id: 'unrecoverable', card: 1));
    writeRecord(activeDir / 'healthy', makeRecord(id: 'healthy', card: 2));
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
        charaDetailRecordStorageLoaderProvider.overrideWith(() => _GateFailingActiveStorage('unrecoverable')),
      ],
    );
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    final toasts = listenToasts(container);

    final RecordDeleteResult result;
    try {
      result = await active.deleteAllAsync(['unrecoverable', 'healthy']);
    } catch (error) {
      fail(
        "one record's gate exception stopped the whole delete: no RecordDeleteResult was reported "
        'for any id, so neither the record that was erased nor the one that was not reached the user ($error)',
      );
    }

    expect(result.failed, {'unrecoverable'});
    expect(result.succeeded, {'healthy'});
    expect(result.isSuccess, isFalse);
    // The record the recovery could not ready is untouched, and every id the
    // throw said nothing about is gone: the failure is one record wide.
    expect(Directory((activeDir / 'unrecoverable').path).existsSync(), isTrue);
    expect(Directory((activeDir / 'healthy').path).existsSync(), isFalse);
    expect(active.getBy(id: 'unrecoverable'), isNotNull);
    expect(active.getBy(id: 'healthy'), isNull);
    await settleToasts();
    expect(toasts.map((toast) => toast.type), contains(ToastType.error));
  });

  test('archive bulk delete fails only the record whose recovery throws and still deletes the rest', () async {
    final root = DirectoryPath(tempRoot.path);
    final archiveDir = pathInfoFor(root).charaDetailArchiveDir;
    writeRecord(archiveDir / 'arch-unrecoverable', makeRecord(id: 'arch-unrecoverable', card: 1));
    writeRecord(archiveDir / 'arch-healthy', makeRecord(id: 'arch-healthy', card: 2));
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
        charaDetailArchiveStorageLoaderProvider.overrideWith(() => _GateFailingArchiveStorage('arch-unrecoverable')),
      ],
    );
    addTearDown(container.dispose);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    final archive = container.read(charaDetailArchiveStorageLoaderProvider.notifier);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    final toasts = listenToasts(container);

    final RecordDeleteResult result;
    try {
      result = await archive.deleteAllAsync(['arch-unrecoverable', 'arch-healthy']);
    } catch (error) {
      fail(
        "one record's gate exception stopped the whole delete: no RecordDeleteResult was reported "
        'for any id, so neither the record that was erased nor the one that was not reached the user ($error)',
      );
    }

    expect(result.failed, {'arch-unrecoverable'});
    expect(result.succeeded, {'arch-healthy'});
    expect(result.isSuccess, isFalse);
    expect(Directory((archiveDir / 'arch-unrecoverable').path).existsSync(), isTrue);
    expect(Directory((archiveDir / 'arch-healthy').path).existsSync(), isFalse);
    expect(archive.getBy(id: 'arch-unrecoverable'), isNotNull);
    expect(archive.getBy(id: 'arch-healthy'), isNull);
    await settleToasts();
    expect(toasts.map((toast) => toast.type), contains(ToastType.error));
  });

  test('archive bulk delete reports an id the store cannot see as failed', () async {
    final root = DirectoryPath(tempRoot.path);
    final archiveDir = pathInfoFor(root).charaDetailArchiveDir;
    writeRecord(archiveDir / 'arch-known', makeRecord(id: 'arch-known', card: 1));
    final container = makeContainer(root);
    addTearDown(container.dispose);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    final archive = container.read(charaDetailArchiveStorageLoaderProvider.notifier);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    writeRecord(archiveDir / 'arch-stranger', makeRecord(id: 'arch-stranger', card: 2));
    final toasts = listenToasts(container);

    final result = await archive.deleteAllAsync(['arch-known', 'arch-stranger']);

    expect(result.failed, {'arch-stranger'});
    expect(result.succeeded, {'arch-known'});
    expect(result.isSuccess, isFalse);
    expect(Directory((archiveDir / 'arch-stranger').path).existsSync(), isTrue);
    await settleToasts();
    expect(toasts.map((toast) => toast.type), contains(ToastType.error));
  });

  test('archive bulk delete of ids the store owns still reports a plain success', () async {
    final root = DirectoryPath(tempRoot.path);
    final archiveDir = pathInfoFor(root).charaDetailArchiveDir;
    writeRecord(archiveDir / 'arch-a', makeRecord(id: 'arch-a', card: 1));
    writeRecord(archiveDir / 'arch-b', makeRecord(id: 'arch-b', card: 2));
    final container = makeContainer(root);
    addTearDown(container.dispose);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    final archive = container.read(charaDetailArchiveStorageLoaderProvider.notifier);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    final toasts = listenToasts(container);

    final result = await archive.deleteAllAsync(['arch-a', 'arch-b']);

    expect(result.succeeded, {'arch-a', 'arch-b'});
    expect(result.failed, isEmpty);
    expect(result.isSuccess, isTrue);
    await settleToasts();
    expect(toasts.where((toast) => toast.type == ToastType.error), isEmpty);
  });

  // The merge's own failure mode: every attempt observes one more record the
  // resolution wants to write, so the locked id set never settles and the merge
  // gives up. It used to raise a bare StateError that the harvest loop swallowed
  // into a log line, leaving a record on disk, out of the list, and unreported.
  test('a merge whose id set never settles reports the failure to the user and still throws', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    _GrowingActiveStorage? active;
    var grown = 0;
    final lock = RecordMutationLock((name, mode, action) async {
      // One new record per lock-set acquisition (the root lock is taken exactly
      // once per attempt). Each carries `incoming` as its parent-1 card, so the
      // resolution links it and the plan's id set is one wider every round.
      if (mode == RecordMutationLockMode.shared && grown < 16) {
        if (active?.insertIfLoaded(makeRecord(id: 'grown-$grown', card: 100 + grown, parent1Card: 2)) ?? false) {
          grown++;
        }
      }
      return action();
    });
    final container = makeGrowingContainer(root, lock);
    addTearDown(container.dispose);
    active = container.read(charaDetailRecordStorageLoaderProvider.notifier) as _GrowingActiveStorage;
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    // Written only now: a record the initial scan already published would be its
    // own resolution candidate, which makes every child match ambiguous and the
    // id set settle immediately.
    writeRecord(activeDir / 'incoming', makeRecord(id: 'incoming', card: 2));
    final toasts = listenToasts(container);

    await expectLater(active.addFromFileAsync('incoming'), throwsA(isA<StateError>()));
    await settleToasts();

    // The merge really did exhaust its attempts rather than failing some other
    // way on the first round: one record was added per attempt.
    expect(grown, greaterThan(4));
    expect(toasts.map((toast) => toast.type), contains(ToastType.error));
  });
}

/// The per-record recovery hook, replaced by one that refuses a named id.
///
/// Stands in for what the real hooks raise - the web leg's committed-archive
/// cleanup running with `failOnError: true`, and either leg's slot probe hitting
/// a filesystem error - without needing either platform's failure to be
/// reproducible here.
RecordRecoveryGate _gateRefusing(String recordId, RecordMutationLock lock) {
  return RecordRecoveryGate(
    mutationLock: lock,
    ensureReady: (storageRoot, id) async {
      if (id == recordId) {
        throw StateError('synthetic recovery failure for $id');
      }
    },
  );
}

class _GateFailingActiveStorage extends CharaDetailRecordStorage {
  _GateFailingActiveStorage(this.unrecoverableId);

  final String unrecoverableId;

  @override
  RecordRecoveryGate get recordRecoveryGate => _gateRefusing(unrecoverableId, recordMutationLock);
}

class _GateFailingArchiveStorage extends CharaDetailArchiveStorage {
  _GateFailingArchiveStorage(this.unrecoverableId);

  final String unrecoverableId;

  @override
  RecordRecoveryGate get recordRecoveryGate => _gateRefusing(unrecoverableId, recordMutationLock);
}

class _GrowingActiveStorage extends CharaDetailRecordStorage {
  _GrowingActiveStorage(this.lock);

  final RecordMutationLock lock;

  @override
  RecordMutationLock get recordMutationLock => lock;

  /// Appends [record] to the published list, or reports that the store has not
  /// published one yet (the lock runs during the initial scan too).
  bool insertIfLoaded(CharaDetailRecord record) {
    final current = state.asData?.value;
    if (current == null) {
      return false;
    }
    state = AsyncData([...current, record]);
    return true;
  }
}
