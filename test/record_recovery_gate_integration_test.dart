import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/archive_executor.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_directory_transaction.dart';
import 'package:umacapture/src/core/fs/record_loader_web.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate_shared.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate_web.dart';
import 'package:umacapture/src/core/fs/root_storage_maintenance.dart';
import 'package:umacapture/src/core/fs/root_storage_maintenance_shared.dart';
import 'package:umacapture/src/core/fs/web_record_persistence.dart';
import 'package:umacapture/src/core/fs/web_record_write_transaction.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/long_read_declarations.dart';
import 'support/records.dart';
import 'support/web_like_fs_backend.dart';

void main() {
  late Directory tempRoot;
  late DirectoryPath storageRoot;
  late DirectoryPath dataRoot;
  late DirectoryPath activeRoot;
  late FsBackend originalBackend;
  late RecordRecoveryGate gate;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_recovery_gate');
    storageRoot = DirectoryPath(tempRoot.path) / 'storage';
    dataRoot = storageRoot / 'chara_detail';
    activeRoot = dataRoot / 'active';
    originalBackend = fsBackend;
    fsBackend = WebLikeFsBackend(originalBackend);
    final mutationLock = RecordMutationLock((_, _, action) => action());
    final rootMaintenance = JournalRootStorageMaintenance.bothJournals(mutationLock: mutationLock);
    // The per-record half is production's, taken off the real platform gate
    // rather than re-written here: a hand-written predicate can only ever pin
    // itself, and this file is about the composition around it.
    final platformGate = createPlatformRecordRecoveryGate(mutationLock: mutationLock);
    gate = RecordRecoveryGate(
      mutationLock: mutationLock,
      ensureReady: platformGate.ensureReadyUnlocked,
      // The root half cannot come from the same factory: `platformRootStorageMaintenance`
      // resolves to the *io* implementation on the VM, and this suite is about the
      // web store. Its memoisation is per instance, so a fresh one per test also
      // keeps the sweep from being skipped.
      ensureRootReady: (storage, reason) => rootMaintenance.runUnlocked(
        RootStorageMaintenanceRequest(recordDataRoot: storage / 'chara_detail', reason: reason),
      ),
    );
  });

  tearDown(() {
    fsBackend = originalBackend;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  Future<void> leaveReadyWrite(String id, {String marker = 'desired'}) async {
    final result =
        await WebRecordWriteTransaction(
          onCheckpoint: (checkpoint) async {
            if (checkpoint == WebRecordWriteCheckpoint.readyPersisted) {
              throw StateError('leave ready slot');
            }
          },
        ).publish(dataRoot, id, [
          (relativeSegments: ['record.json'], bytes: _recordJson(id, marker: marker)),
        ]);
    expect(result, WebRecordWriteResult.incomplete);
  }

  test('bulk scan performs root recovery before listing a missing active final', () async {
    const id = 'scan-ready';
    await leaveReadyWrite(id);
    expect(await (activeRoot / id).exists(), isFalse);
    final events = <String>[];

    final (:results, :unavailable) = await loadRecordsUnder(
      activeRoot,
      declaration: undeclaredInTest,
      recoveryGate: gate,
      snapshotDirectories: (_) async {
        events.add('list');
        expect(await (activeRoot / id).exists(), isTrue);
        return [activeRoot / id];
      },
      loadAction: (directory) async {
        events.add('load');
        expect(await directory.filePath('record.json').readAsString(), contains('desired'));
        return RecordLoaded(makeRecord(id: id, card: 1));
      },
    );

    expect(events, ['list', 'load']);
    expect(results.single, isA<RecordLoaded>());
    expect(unavailable, isEmpty);
  });

  test('a ready slot whose staging was lost keeps its record listed, and the sweep clears the slot', () async {
    const id = 'staging-lost';
    // A record already in the store, then a second publication that reached
    // `ready` and lost its staged tree underneath it. `ready` is written only
    // after that tree was validated, so nothing in this machine can produce the
    // state -- only the layer below it losing bytes the manifest already outran.
    expect(
      await WebRecordWriteTransaction().publish(dataRoot, id, [
        (relativeSegments: ['record.json'], bytes: _recordJson(id, marker: 'stored')),
      ]),
      WebRecordWriteResult.completed,
    );
    await leaveReadyWrite(id, marker: 'in-flight');
    final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName(id);
    await (slot / 'desired').delete(recursive: true);

    // 1. Startup completes *and* resolves the slot. It used to throw here, and
    //    every page then carried a permanent banner over an empty record tab --
    //    with the repair that resolved this behind exactly the door that had
    //    just closed. Then it stopped throwing but still left the slot standing
    //    until a person pressed a button. Now the sweep sets it aside itself.
    await gate.runForRoot(
      storageRoot,
      (_) async {},
      declaration: undeclaredInTest,
      reason: RootMaintenanceReason.readyToUse,
      beforeMaintenance: const BeforeRootMaintenance.none(reason: 'this case surveys nothing'),
    );
    expect(await slot.exists(), isFalse);

    // 2. The scan lists the record. It used to refuse it: the gate turned the
    //    slot's classification into a missing record, so a stored tree nothing
    //    had touched disappeared from the list because an *update* to it had
    //    torn. The stored tree is readable, so it is read; the slot the app
    //    cannot finish is the slot's own problem.
    Future<RecordScanResult> scan() => loadRecordsUnder(
      activeRoot,
      declaration: undeclaredInTest,
      recoveryGate: gate,
      loadAction: (directory) async => RecordLoaded(makeRecord(id: directory.name, card: 1)),
    );
    final listed = await scan();
    expect(listed.unavailable, isEmpty);
    expect(listed.results.single, isA<RecordLoaded>());
    // And it is the stored record, not the update that was in flight: the
    // update is what is lost when a publication cannot be finished, never the
    // record already on disk.
    expect(await (activeRoot / id).filePath('record.json').readAsString(), contains('stored'));

    // 3. Nothing is left for a later session to trip on, and a new publication
    //    of the same record goes through.
    expect(
      await WebRecordWriteTransaction().publish(dataRoot, id, [
        (relativeSegments: ['record.json'], bytes: _recordJson(id, marker: 'second')),
      ]),
      WebRecordWriteResult.completed,
    );
    expect(await (activeRoot / id).filePath('record.json').readAsString(), contains('second'));
  });

  test('a torn archive move keeps its record listed, and the sweep clears the slot', () async {
    const id = 'move-torn';
    final source = activeRoot / id;
    await source.create(recursive: true);
    await source.filePath('record.json').writeAsBytes(_recordJson(id, marker: 'stored'));
    // An archive move interrupted mid-flight, whose manifest then tore. The
    // second state machine's twin of the case above: stuck for good, because
    // every resume re-derives the same answer from the same unreadable bytes.
    await RecordDirectoryTransaction(
      onCheckpoint: (point) async {
        if (point == RecordTransactionCheckpoint.payloadCopied) throw StateError('interrupt');
      },
    ).execute(
      RecordDirectoryTransactionSpec(
        recordId: id,
        source: source,
        destination: dataRoot / 'archive' / id,
        metadata: const {'imageOption': 'none'},
      ),
    );
    final slot =
        dataRoot / '.umacapture-transactions' / 'v1' / base64Url.encode(utf8.encode('archive:$id')).replaceAll('=', '');
    await slot.filePath('manifest.json').writeAsString('{ this is not json');

    // 1. Startup completes *and* resolves the slot. It used to throw here for
    //    every later session, with no repair defined for an archive slot at all.
    await gate.runForRoot(
      storageRoot,
      (_) async {},
      declaration: undeclaredInTest,
      reason: RootMaintenanceReason.readyToUse,
      beforeMaintenance: const BeforeRootMaintenance.none(reason: 'this case surveys nothing'),
    );
    expect(await slot.exists(), isFalse);

    // 2. The scan lists the record, which never moved: the move is what tore.
    //    The second state machine's twin of the case above, and the same
    //    correction -- an unfinishable slot is not a reason to hide the tree it
    //    failed to move.
    Future<RecordScanResult> scan() => loadRecordsUnder(
      activeRoot,
      declaration: undeclaredInTest,
      recoveryGate: gate,
      loadAction: (directory) async => RecordLoaded(makeRecord(id: directory.name, card: 1)),
    );
    final listed = await scan();
    expect(listed.unavailable, isEmpty);
    expect(listed.results.single, isA<RecordLoaded>());
    expect(await source.filePath('record.json').readAsString(), contains('stored'));

    // 3. The move is what was given up on, never the record: it stands where it
    //    stood, nothing was archived, and the staged copy is in quarantine/
    //    rather than deleted.
    expect(await (dataRoot / 'archive' / id).exists(), isFalse);
    expect(await (dataRoot / 'quarantine' / id).filePath('record.json').exists(), isTrue);
  });

  test('pending write is recovered before delete and cannot revive at startup', () async {
    const id = 'delete-ready';
    await leaveReadyWrite(id);
    var deletes = 0;

    await gate.runForRecord(storageRoot, id, declaration: undeclaredInTest, () async {
      expect(await (activeRoot / id).exists(), isTrue);
      deletes++;
      await (activeRoot / id).delete(recursive: true);
    });
    await gate.runForRoot(
      storageRoot,
      (_) async {},
      declaration: undeclaredInTest,
      reason: RootMaintenanceReason.readyToUse,
      beforeMaintenance: const BeforeRootMaintenance.none(reason: 'this case surveys nothing'),
    );

    expect(deletes, 1);
    expect(await (activeRoot / id).exists(), isFalse);
  });

  test('archive and update observe the recovered desired tree', () async {
    const archiveId = 'archive-ready';
    await leaveReadyWrite(archiveId, marker: 'archive-desired');
    final archived = await archiveRecordAsync(
      ArchiveRecordArgs(
        (activeRoot / archiveId).path,
        (dataRoot / 'archive' / archiveId).path,
        ArchiveImageOption.none,
      ),
      recoveryGate: gate,
    );
    expect(archived, isTrue);
    expect(
      await (dataRoot / 'archive' / archiveId).filePath('record.json').readAsString(),
      contains('archive-desired'),
    );

    const updateId = 'update-ready';
    await leaveReadyWrite(updateId, marker: 'update-desired');
    var builders = 0;
    final persistence = WebRecordPersistence(recoveryGate: gate);
    final updated = await persistence.persistRecordUpdate(storageRoot, updateId, () async {
      builders++;
      expect(await (activeRoot / updateId).filePath('record.json').readAsString(), contains('update-desired'));
      return [(path: 'chara_detail/active/$updateId/record.json', bytes: _recordJson(updateId, marker: 'updated'))];
    });

    expect(updated, isTrue);
    expect(builders, 1);
    expect(await (activeRoot / updateId).filePath('record.json').readAsString(), contains('updated'));
  });

  test('exact archive cleanup finishes before action and remains retryable on failure', () async {
    const id = 'directory-pending';
    final source = activeRoot / id;
    await source.create(recursive: true);
    await source.filePath('record.json').writeAsBytes(_recordJson(id));
    await source.filePath('prediction.json').writeAsString('{}');
    await source.filePath('skill.png').writeAsBytes([1, 2, 3]);
    await source.filePath('skill.json').writeAsString('{geometry:true}');
    await source.filePath('factor.png').writeAsBytes([4, 5, 6]);
    await source.filePath('factor.json').writeAsString('{geometry:true}');
    final spec = RecordDirectoryTransactionSpec(
      recordId: id,
      source: source,
      destination: dataRoot / 'archive' / id,
      metadata: const {'imageOption': 'none'},
    );
    expect(
      await RecordDirectoryTransaction().execute(
        spec,
        beforeCommittedCleanup: (_) async => throw StateError('leave cleanup in progress'),
      ),
      RecordTransactionResult.cleanupPending,
    );
    final slotRoot = dataRoot / '.umacapture-transactions' / 'v1';
    expect(await slotRoot.list().isEmpty, isFalse);

    var actions = 0;
    fsBackend = _FailArchiveImageDeleteBackend(originalBackend, 'factor.png');
    // The cleanup keeps failing, so the transaction stays parked -- but it has
    // *committed*, and the production gate lets a committed-but-cleanup-pending
    // record be acted on rather than stranding it behind a failing cleanup. The
    // partial cleanup is already visible to the action, which is what proves
    // recovery ran first.
    await gate.runForRecord(storageRoot, id, declaration: undeclaredInTest, () async {
      actions++;
      expect(await spec.destination.filePath('prediction.json').exists(), isFalse);
      expect(await spec.destination.filePath('skill.png').exists(), isFalse);
      expect(await spec.destination.filePath('skill.json').exists(), isFalse);
      expect(await spec.destination.filePath('factor.png').exists(), isTrue);
      expect(await spec.destination.filePath('factor.json').exists(), isTrue);
    });
    expect(actions, 1);
    expect(await slotRoot.list().isEmpty, isFalse);
    final slot = await slotRoot.list().first;
    final manifest = jsonDecode(await slot.asDirectoryPath.filePath('manifest.json').readAsString());
    // Parked at `cleaning`, not advanced to `completed`: the remaining images are
    // still owed, so the next acquisition retries instead of dropping them.
    expect(manifest['state'], RecordTransactionState.cleaning.name);

    fsBackend = WebLikeFsBackend(originalBackend);
    await gate.runForRecord(storageRoot, id, declaration: undeclaredInTest, () async {
      actions++;
      expect(await spec.destination.filePath('prediction.json').exists(), isFalse);
      expect(await spec.destination.filePath('skill.png').exists(), isFalse);
      expect(await spec.destination.filePath('skill.json').exists(), isFalse);
      expect(await spec.destination.filePath('factor.png').exists(), isFalse);
      expect(await spec.destination.filePath('factor.json').exists(), isFalse);
      expect(await slotRoot.list().isEmpty, isTrue);
      await (dataRoot / 'archive' / id).filePath('inheritance.json').writeAsString('applied');
    });
    expect(actions, 2);
    expect(await (dataRoot / 'archive' / id).filePath('inheritance.json').readAsString(), 'applied');
  });
}

String _slotName(String id) => base64Url.encode(utf8.encode('publish-active-record:$id')).replaceAll('=', '');

Uint8List _recordJson(String id, {String marker = 'base'}) {
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'metadata': {
          'record_id': {'self': id},
        },
        marker: true,
      }),
    ),
  );
}

final class _FailArchiveImageDeleteBackend extends WebLikeFsBackend {
  _FailArchiveImageDeleteBackend(super.inner, this.fileName);

  final String fileName;

  @override
  Future<void> delete(String path, {bool recursive = false}) {
    if (!recursive && PathEntity(path).name == fileName) {
      throw FileSystemException('synthetic archive image cleanup failure', path);
    }
    return super.delete(path, recursive: recursive);
  }
}
