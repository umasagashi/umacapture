// Blast-radius contract of the web record gate and the web store scan.
//
// Neither of these lives on the browser side of a conditional import, so the
// real production code paths (`_ensureRecordReady`, `loadRecordsUnder`) run here
// on the VM against the io backend.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_directory_transaction.dart';
import 'package:umacapture/src/core/fs/record_loader_web.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate_shared.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate_web.dart';
import 'package:umacapture/src/core/fs/record_store_unavailable.dart';
import 'package:umacapture/src/core/fs/web_record_write_transaction.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/records.dart';
import 'support/web_like_fs_backend.dart';

void main() {
  late Directory tempRoot;
  late DirectoryPath storageRoot;
  late DirectoryPath dataRoot;
  late DirectoryPath activeRoot;
  late FsBackend originalBackend;

  final passThroughLock = RecordMutationLock((_, _, action) => action());

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_gate_policy');
    storageRoot = DirectoryPath(tempRoot.path) / 'storage';
    dataRoot = storageRoot / 'chara_detail';
    activeRoot = dataRoot / 'active';
    originalBackend = fsBackend;
    fsBackend = WebLikeFsBackend(originalBackend);
  });

  tearDown(() {
    fsBackend = originalBackend;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  Future<DirectoryPath> seed(String id) async {
    final directory = activeRoot / id;
    await directory.create(recursive: true);
    await directory.filePath('record.json').writeAsBytes(_recordJson(id));
    return directory;
  }

  test('a committed cleanup-pending archive slot stays readable', () async {
    const id = 'cleanup-pending';
    final source = await seed(id);
    final spec = RecordDirectoryTransactionSpec(
      recordId: id,
      source: source,
      destination: dataRoot / 'archive' / id,
      metadata: const {'imageOption': 'none'},
    );
    // The move commits; only the removal of our own staging keeps failing.
    fsBackend = _FailSlotDeleteBackend(originalBackend);
    expect(await RecordDirectoryTransaction().execute(spec), RecordTransactionResult.cleanupPending);

    final gate = createPlatformRecordRecoveryGate(mutationLock: passThroughLock);
    var read = 0;
    // Nothing about a pending cleanup makes the record unreadable, and refusing
    // it would strand the record for good.
    await gate.runForRecord(storageRoot, id, () async => read++);
    expect(read, 1);
  });

  test('a committed cleanup-pending web write slot stays readable', () async {
    const id = 'write-cleanup-pending';
    await seed(id);
    fsBackend = _FailSlotDeleteBackend(originalBackend);
    expect(
      await WebRecordWriteTransaction().publish(dataRoot, id, [
        (relativeSegments: ['record.json'], bytes: _recordJson(id)),
        (relativeSegments: ['extra.bin'], bytes: Uint8List.fromList([1])),
      ]),
      WebRecordWriteResult.cleanupPending,
    );

    final gate = createPlatformRecordRecoveryGate(mutationLock: passThroughLock);
    var read = 0;
    await gate.runForRecord(storageRoot, id, () async => read++);
    expect(read, 1);
    expect(await (activeRoot / id).filePath('extra.bin').readAsBytes(), [1]);
  });

  test('a foreign write slot is left byte-for-byte alone by the gate', () async {
    // The gate no longer refuses a record for any recovery outcome, so what this
    // still pins is the other half: a slot no writer of ours produced is
    // reported and *left alone*. Recovery running for its effect rather than for
    // a verdict must not turn into recovery clearing the way.
    //
    // The slot *name* is what says so. This used to be driven with one of our
    // own names carrying a manifest of a later version, on the rule that
    // well-formed JSON the decoder refuses is another writer's; that rule is
    // gone -- a slot of ours that cannot be resumed has its staging quarantined
    // whatever its manifest turned out to be -- and only the name is left.
    const id = 'foreign-slot';
    await seed(id);
    final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / 'not-one-of-ours';
    await slot.create(recursive: true);
    final foreignManifest = jsonEncode({'version': 2, 'recordId': id});
    await slot.filePath('manifest.json').writeAsString(foreignManifest);
    expect((await WebRecordWriteTransaction().recoverAll(dataRoot)).single.result, WebRecordWriteResult.incomplete);

    final gate = createPlatformRecordRecoveryGate(mutationLock: passThroughLock);
    var read = 0;
    await gate.runForRecord(storageRoot, id, () async => read++);
    expect(read, 1);
    // Carried out of the transaction root, never destroyed: the sweep above
    // moved it into `retired/` byte-for-byte, and `retired/` rather than
    // `quarantine/` because it is not the user's record and the banner counts
    // `quarantine/`'s children as records the app could not read.
    expect(await slot.exists(), isFalse);
    expect(await (dataRoot / 'retired' / 'not-one-of-ours').filePath('manifest.json').readAsString(), foreignManifest);
    expect(await (activeRoot / id).filePath('record.json').exists(), isTrue);
  });

  test('an unavailable record is skipped by the store scan instead of failing it', () async {
    final good = await seed('good');
    final bad = await seed('bad');
    final alsoGood = await seed('also-good');
    final loaded = <String>[];

    final (:results, :unavailable) = await loadRecordsUnder(
      activeRoot,
      mutationLock: passThroughLock,
      recoverRecordUnlocked: (_, id) async {
        if (id == 'bad') throw StateError('record $id is unrecoverable');
      },
      snapshotDirectories: (_) async => [good, bad, alsoGood],
      loadAction: (directory) async {
        loaded.add(directory.name);
        return RecordLoaded(makeRecord(id: directory.name, card: 1));
      },
    );

    expect(loaded, ['good', 'also-good']);
    expect(results, hasLength(2));
    expect(results, everyElement(isA<RecordLoaded>()));
    // Skipped, but not lost: the caller is handed the id and the cause, so it can
    // tell the user a record is missing instead of silently showing fewer.
    expect(unavailable.keys, ['bad']);
    expect(unavailable['bad'], isA<StateError>());
  });

  test('a busy record lock is reported as busy, not as a corrupt record', () async {
    final good = await seed('lock-good');
    final busy = await seed('lock-busy');
    const timeout = Duration(seconds: 150);
    // Only the record-scoped acquisition for 'lock-busy' times out; the shared
    // root gate and every other record still grant, exactly as Web Locks behaves
    // when a second tab holds one record mid-regeneration.
    final busyLock = RecordMutationLock((name, _, action) {
      if (name.contains(base64Url.encode(utf8.encode('lock-busy')).replaceAll('=', ''))) {
        throw RecordMutationLockBusy(name, timeout);
      }
      return action();
    });

    final (:results, :unavailable) = await loadRecordsUnder(
      activeRoot,
      mutationLock: busyLock,
      recoverRecordUnlocked: (_, _) async {},
      snapshotDirectories: (_) async => [good, busy],
      loadAction: (directory) async => RecordLoaded(makeRecord(id: directory.name, card: 1)),
    );

    expect(results, hasLength(1));
    // The distinguishing bit: a merely busy lock must stay tellable apart from a
    // record that is actually broken, or the user is told their data is corrupt.
    expect(unavailable['lock-busy'], isA<RecordMutationLockBusy>());
    // The record itself is untouched -- nothing was quarantined or removed.
    expect(await busy.filePath('record.json').exists(), isTrue);
  });

  test('a throw out of the decode is a bug, not an availability skip', () async {
    final one = await seed('decode-throw');

    // The scan contains gate/lock failures only. Letting it swallow anything the
    // load action raised would also mean an `expect` inside an injected
    // loadAction could never fail a test.
    await expectLater(
      loadRecordsUnder(
        activeRoot,
        mutationLock: passThroughLock,
        recoverRecordUnlocked: (_, _) async {},
        snapshotDirectories: (_) async => [one],
        loadAction: (_) async => throw TestFailure('an expectation inside loadAction failed'),
      ),
      throwsA(isA<TestFailure>()),
    );
  });

  test('a busy root lock fails the scan as a transient store outage, not as a bare lock error', () async {
    await seed('never-listed');
    const timeout = Duration(seconds: 150);
    // The root name is taken exclusively before any record directory is listed,
    // so nothing downstream of it ever runs: this is the whole store, not a
    // record. Unwrapped, this exact exception used to escape the store's build()
    // and be painted verbatim by the record page.
    final busyRootLock = RecordMutationLock((name, _, action) {
      if (name.endsWith(':root')) throw RecordMutationLockBusy(name, timeout);
      return action();
    });

    await expectLater(
      loadRecordsUnder(activeRoot, mutationLock: busyRootLock, recoverRecordUnlocked: (_, _) async {}),
      throwsA(
        isA<RecordStoreUnavailable>()
            .having((error) => error.transient, 'transient', isTrue)
            .having((error) => error.cause, 'cause', isA<RecordMutationLockBusy>()),
      ),
    );
  });

  test('a root recovery refusal is a blocked store outage, distinct from a busy one', () async {
    await seed('never-listed');
    // Whole-store recovery refusing is not going to clear by waiting, so the
    // verdict the UI turns on must differ from the busy case above.
    final gate = RecordRecoveryGate(
      mutationLock: passThroughLock,
      ensureRootReady: (_) async => throw StateError('whole-store migration cannot finish'),
    );

    await expectLater(
      loadRecordsUnder(activeRoot, recoveryGate: gate),
      throwsA(
        isA<RecordStoreUnavailable>()
            .having((error) => error.transient, 'transient', isFalse)
            .having((error) => error.cause, 'cause', isA<StateError>()),
      ),
    );
  });

  test('a scan that lists the store never reports a store outage', () async {
    final one = await seed('listed');

    final (:results, :unavailable) = await loadRecordsUnder(
      activeRoot,
      mutationLock: passThroughLock,
      recoverRecordUnlocked: (_, _) async {},
      snapshotDirectories: (_) async => [one],
      loadAction: (directory) async => RecordLoaded(makeRecord(id: directory.name, card: 1)),
    );

    expect(results, hasLength(1));
    expect(unavailable, isEmpty);
  });

  test('an explicit single-record load still reports its own failure', () async {
    final directory = await seed('single');

    await expectLater(
      loadRecord(
        directory,
        mutationLock: passThroughLock,
        recoverRecordUnlocked: (_, _) async => throw StateError('unrecoverable'),
        loadAction: (_) async => const RecordQuarantined(null),
      ),
      throwsA(isA<StateError>()),
    );
  });
}

Uint8List _recordJson(String id) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'metadata': {
        'record_id': {'self': id},
      },
    }),
  ),
);

/// Keeps every transaction slot removal failing, which is what leaves a
/// committed transaction permanently in its cleanup-pending state.
final class _FailSlotDeleteBackend extends WebLikeFsBackend {
  _FailSlotDeleteBackend(super.inner);

  @override
  Future<void> delete(String path, {bool recursive = false}) {
    if (path.contains('-transactions')) {
      throw FileSystemException('synthetic slot cleanup failure', path);
    }
    return super.delete(path, recursive: recursive);
  }
}
