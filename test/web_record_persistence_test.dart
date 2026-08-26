import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/record_zip.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/web_record_persistence.dart';
import 'package:umacapture/src/core/fs/web_record_write_transaction.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/web_like_fs_backend.dart';

void main() {
  late Directory tempRoot;
  late DirectoryPath storageDir;
  late FsBackend originalBackend;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_web_persistence');
    storageDir = DirectoryPath(tempRoot.path) / 'storage';
    originalBackend = fsBackend;
    // The code under test is web-only, so it is exercised against
    // `WebLikeFsBackend`: a sync FS call added here by reflex fails on the VM
    // instead of passing CI and breaking only on web. That pins OPFS's
    // *synchronous* prohibition and nothing else -- see
    // `support/web_like_fs_backend.dart` for what this backend does not model.
    fsBackend = WebLikeFsBackend(originalBackend);
  });

  tearDown(() {
    fsBackend = originalBackend;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  test('ZIP import takes each deduplicated record lock once in order', () async {
    final calls = <(String, RecordMutationLockMode)>[];
    final persistence = WebRecordPersistence(
      mutationLock: RecordMutationLock((name, mode, action) async {
        calls.add((name, mode));
        return action();
      }),
    );
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          'chara_detail/active/record-b/record.json',
          _recordJson('record-b').length,
          _recordJson('record-b'),
        ),
      )
      ..addFile(
        ArchiveFile(
          'chara_detail/active/record-a/record.json',
          _recordJson('record-a').length,
          _recordJson('record-a'),
        ),
      )
      ..addFile(ArchiveFile('chara_detail/active/record-b/trainee.jpg', 1, [3]));

    final result = await RecordZipService.import(
      Uint8List.fromList(ZipEncoder().encode(archive)),
      storageDir,
      persistence: persistence,
    );

    expect(result.recordIds, {'record-a', 'record-b'});
    final recordCalls = calls.where((call) => call.$1.contains(':record:'));
    final expected = [_recordLockName('record-a'), _recordLockName('record-b')]..sort();
    expect(recordCalls.map((call) => call.$1), expected);
    expect(recordCalls.map((call) => call.$2), everyElement(RecordMutationLockMode.exclusive));
  });

  test('the live harvest entrance takes the payload record lock', () async {
    final calls = <String>[];
    final persistence = WebRecordPersistence(
      mutationLock: RecordMutationLock((name, mode, action) async {
        if (name.contains(':record:')) calls.add(name);
        return action();
      }),
    );

    final ids = await persistPlatformHarvestToOpfs(
      [(path: 'chara_detail/active/harvest-id/record.json', bytes: _recordJson('harvest-id'))],
      storageDir,
      persistence: persistence,
    );

    expect(ids, {'harvest-id'});
    expect(calls, [_recordLockName('harvest-id')]);
  });

  test('the incremental live harvest rejects a different record id', () async {
    expect(
      () => persistPlatformHarvestToOpfs(
        [(path: 'chara_detail/active/other-id/record.json', bytes: _recordJson('other-id'))],
        storageDir,
        expectedRecordId: 'expected-id',
      ),
      throwsFormatException,
    );
    expect(await (storageDir / 'chara_detail' / 'active' / 'other-id').exists(), isFalse);
  });

  test('same record ingestion serializes while different records may overlap', () async {
    final sameProbe = _IngestionConcurrencyProbe();
    final samePersistence = WebRecordPersistence(
      mutationLock: RecordMutationLock(_PerNameExclusiveRunner().call),
      writeFile: sameProbe.write,
    );
    final sameFile = [
      (recordId: 'same-ingestion', relativeSegments: ['record.json'], bytes: _recordJson('same-ingestion')),
    ];

    final first = samePersistence.persistFiles(storageDir, sameFile);
    await sameProbe.firstEntered.future;
    final second = samePersistence.persistFiles(storageDir, sameFile);
    await Future<void>.delayed(Duration.zero);
    expect(sameProbe.entered, 1);
    sameProbe.release.complete();
    await Future.wait([first, second]);
    expect(sameProbe.entered, 2);

    final differentProbe = _IngestionConcurrencyProbe(expectedBeforeRelease: 2);
    final differentPersistence = WebRecordPersistence(
      mutationLock: RecordMutationLock(_PerNameExclusiveRunner().call),
      writeFile: differentProbe.write,
    );
    final differentA = differentPersistence.persistFiles(storageDir, [
      (recordId: 'ingestion-a', relativeSegments: ['record.json'], bytes: _recordJson('ingestion-a')),
    ]);
    final differentB = differentPersistence.persistFiles(storageDir, [
      (recordId: 'ingestion-b', relativeSegments: ['record.json'], bytes: _recordJson('ingestion-b')),
    ]);
    await differentProbe.allExpectedEntered.future;
    expect(differentProbe.entered, 2);
    differentProbe.release.complete();
    await Future.wait([differentA, differentB]);
  });

  test('platform update entrance takes the requested record lock once', () async {
    final calls = <String>[];
    final persistence = WebRecordPersistence(
      mutationLock: RecordMutationLock((name, mode, action) async {
        if (name.contains(':record:')) calls.add(name);
        return action();
      }),
    );
    var actionRan = false;

    await persistPlatformRecordUpdateToOpfs('update-id', storageDir, () async {
      actionRan = true;
      return [(path: 'chara_detail/active/update-id/record.json', bytes: _recordJson('update-id'))];
    }, persistence: persistence);

    expect(actionRan, isTrue);
    expect(calls, [_recordLockName('update-id')]);
  });
  test('same record updates serialize while different records may overlap', () async {
    final persistence = WebRecordPersistence(mutationLock: RecordMutationLock(_PerNameExclusiveRunner().call));
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    final events = <String>[];

    final first = persistPlatformRecordUpdateToOpfs('same-id', storageDir, () async {
      events.add('same-1-enter');
      firstEntered.complete();
      await releaseFirst.future;
      events.add('same-1-exit');
      return [(path: 'chara_detail/active/same-id/record.json', bytes: _recordJson('same-id'))];
    }, persistence: persistence);
    await firstEntered.future;
    final second = persistPlatformRecordUpdateToOpfs('same-id', storageDir, () async {
      events.add('same-2-enter');
      return [(path: 'chara_detail/active/same-id/record.json', bytes: _recordJson('same-id'))];
    }, persistence: persistence);
    await Future<void>.delayed(Duration.zero);
    expect(events, ['same-1-enter']);
    releaseFirst.complete();
    await Future.wait([first, second]);
    expect(events, ['same-1-enter', 'same-1-exit', 'same-2-enter']);

    final bothEntered = Completer<void>();
    var entered = 0;
    final releaseDifferent = Completer<void>();
    Future<bool> different(String id) => persistPlatformRecordUpdateToOpfs(id, storageDir, () async {
      entered++;
      if (entered == 2) bothEntered.complete();
      await releaseDifferent.future;
      return [(path: 'chara_detail/active/$id/record.json', bytes: _recordJson(id))];
    }, persistence: persistence);
    final differentA = different('different-a');
    final differentB = different('different-b');
    await bothEntered.future;
    releaseDifferent.complete();
    await Future.wait([differentA, differentB]);
  });

  test('lock wait and unavailable lock prevent persistent writes', () async {
    final recordRequested = Completer<void>();
    final releaseRecord = Completer<void>();
    final writes = <String>[];
    final waitingPersistence = WebRecordPersistence(
      mutationLock: RecordMutationLock((name, mode, action) async {
        if (name.contains(':record:')) {
          recordRequested.complete();
          await releaseRecord.future;
        }
        return action();
      }),
      writeFile: (target, bytes) async {
        writes.add(target.path);
        await target.parent.create(recursive: true);
        await target.writeAsBytes(bytes);
      },
    );
    final persist = persistPlatformHarvestToOpfs(
      [(path: 'chara_detail/active/waiting/record.json', bytes: _recordJson('waiting'))],
      storageDir,
      persistence: waitingPersistence,
    );

    await recordRequested.future;
    expect(writes, isEmpty);
    releaseRecord.complete();
    await persist;
    expect(writes, hasLength(1));

    final unavailableWrites = <String>[];
    final unavailable = WebRecordPersistence(
      mutationLock: const RecordMutationLock(null),
      writeFile: (target, _) async => unavailableWrites.add(target.path),
    );
    expect(
      () => persistPlatformHarvestToOpfs(
        [(path: 'chara_detail/active/unsupported/record.json', bytes: _recordJson('unsupported'))],
        storageDir,
        persistence: unavailable,
      ),
      throwsA(isA<RecordMutationLockUnavailable>()),
    );
    expect(unavailableWrites, isEmpty);
  });

  test('empty and unsafe harvested payloads fail closed before writes', () async {
    final writes = <String>[];
    final persistence = WebRecordPersistence(
      writeFile: (target, bytes) async {
        writes.add(target.path);
        await target.parent.create(recursive: true);
        await target.writeAsBytes(bytes);
      },
    );
    expect(await persistence.persistFiles(storageDir, const []), isEmpty);
    for (final path in [
      '/chara_detail/active/id/record.json',
      r'\chara_detail\active\id\record.json',
      'chara_detail/active/id/../record.json',
      r'chara_detail\active\id\..\record.json',
      'chara_detail//active/id/record.json',
    ]) {
      expect(
        () => parseHarvestedRecordFiles([(path: path, bytes: _recordJson('id'))], logContext: 'test'),
        throwsFormatException,
      );
    }
    expect(
      () => parseHarvestedRecordFiles(
        [
          (path: 'chara_detail/active/a/record.json', bytes: _recordJson('a')),
          (path: 'chara_detail/active/b/record.json', bytes: _recordJson('b')),
        ],
        logContext: 'test',
        expectedRecordId: 'a',
      ),
      throwsFormatException,
    );
    expect(
      () => persistence.persistFiles(storageDir, [
        (recordId: 'missing', relativeSegments: ['data.bin'], bytes: Uint8List.fromList([1])),
      ]),
      throwsFormatException,
    );
    expect(
      () => persistence.persistFiles(storageDir, [
        (recordId: 'mismatch', relativeSegments: ['record.json'], bytes: _recordJson('other')),
      ]),
      throwsFormatException,
    );
    expect(writes, isEmpty);
  });

  test('record update rejects empty and mismatching worker output', () async {
    final persistence = WebRecordPersistence();
    expect(
      await persistPlatformRecordUpdateToOpfs('update', storageDir, () async => null, persistence: persistence),
      isFalse,
    );
    expect(
      await persistPlatformRecordUpdateToOpfs('update', storageDir, () async => const [], persistence: persistence),
      isFalse,
    );
    await expectLater(
      persistPlatformRecordUpdateToOpfs(
        'update',
        storageDir,
        () async => [(path: 'chara_detail/active/other/record.json', bytes: _recordJson('other'))],
        persistence: persistence,
      ),
      throwsFormatException,
    );
  });

  test('multi-record persistence reports committed IDs when a later record fails', () async {
    final persistence = WebRecordPersistence(
      writeFile: (target, bytes) async {
        if (utf8.decode(bytes).contains('second')) throw StateError('synthetic second failure');
        await target.parent.create(recursive: true);
        await target.writeAsBytes(bytes);
      },
    );
    final result = await persistence.persistFiles(storageDir, [
      (recordId: 'first', relativeSegments: ['record.json'], bytes: _recordJson('first')),
      (recordId: 'second', relativeSegments: ['record.json'], bytes: _recordJson('second')),
    ]);
    expect(result.statuses, {
      'first': WebRecordPersistenceStatus.completed,
      'second': WebRecordPersistenceStatus.failed,
    });
    expect(result.committedIds, {'first'});
    expect(result.failures['second'], WebRecordWriteResult.incomplete);
    expect(result.failures.containsKey('first'), isFalse);
    expect(await (storageDir / 'chara_detail' / 'active' / 'first').filePath('record.json').exists(), isTrue);
    expect(await (storageDir / 'chara_detail' / 'active' / 'second').exists(), isFalse);
  });

  test('a prior slot still owing its cleanup is a failed save, not a silent no-op', () async {
    // The trap the fold could have walked into. A prior transaction slot that
    // recovered as `cleanupPending` is committed -- for *its own* publication --
    // so handing that value back from `publish` makes this save look like one
    // that worked: `committedIds` would hold the id, and the zip import derives
    // its refusals from exactly that, so the user is told the import succeeded
    // while `active/<id>/` still holds the old bytes. No toast, no banner, no
    // log line. The value is folded to `incomplete`; the refusal is not.
    const id = 'prior-cleanup';
    final recordDir = storageDir / 'chara_detail' / 'active' / id;
    await recordDir.create(recursive: true);
    await recordDir.filePath('record.json').writeAsBytes(_recordJson(id));
    final slot = storageDir / 'chara_detail' / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName(id);
    // A save whose slot removal throws leaves the slot behind at `published`,
    // which is what a later publish finds and recovers as `cleanupPending`.
    WebRecordPersistence retainingCleanup() => WebRecordPersistence(
      transaction: WebRecordWriteTransaction(
        deleteDirectory: (target) async {
          if (target.path == slot.path) throw StateError('synthetic retained cleanup');
          await target.delete(recursive: true, emptyOk: true);
        },
      ),
    );
    final first = await retainingCleanup().persistFiles(storageDir, [
      (recordId: id, relativeSegments: ['record.json'], bytes: _recordJson(id)),
      (recordId: id, relativeSegments: ['new.bin'], bytes: Uint8List.fromList([1])),
    ]);
    expect(first.statuses[id], WebRecordPersistenceStatus.cleanupPending);
    expect(first.committed(id), isTrue, reason: 'the positive control: that save did publish');

    final blocked = await retainingCleanup().persistFiles(storageDir, [
      (recordId: id, relativeSegments: ['record.json'], bytes: _recordJson(id)),
      (recordId: id, relativeSegments: ['new.bin'], bytes: Uint8List.fromList([2])),
    ]);

    expect(blocked.committed(id), isFalse);
    expect(blocked.failures[id], WebRecordWriteResult.incomplete);
    expect(
      await (storageDir / 'chara_detail' / 'active' / id).filePath('new.bin').readAsBytes(),
      [1],
      reason: 'the record on disk is the one the refused save did not replace',
    );
  });

  test('a refused (non-throwing) publication keeps the transaction result as its reason', () async {
    final recordDir = storageDir / 'chara_detail' / 'active' / 'refused';
    await recordDir.create(recursive: true);
    await recordDir.filePath('record.json').writeAsBytes(_recordJson('refused'));
    final persistence = WebRecordPersistence(transaction: WebRecordWriteTransaction(copyTree: (_, _) async => false));

    final result = await persistence.persistFiles(storageDir, [
      (recordId: 'refused', relativeSegments: ['record.json'], bytes: _recordJson('refused')),
    ]);

    expect(result.statuses['refused'], WebRecordPersistenceStatus.failed);
    expect(result.committedIds, isEmpty);
    expect(result.failures['refused'], WebRecordWriteResult.incomplete);
  });

  test('a thrown publication failure keeps its exception instead of discarding it', () async {
    final originalBackend = fsBackend;
    addTearDown(() => fsBackend = originalBackend);
    // The one probe that runs before the transaction's own try/catch, so this is
    // the exception the bare `catch (_)` used to swallow whole.
    fsBackend = _ThrowOnSlotProbeBackend(originalBackend, _slotName('boom'));

    final result = await WebRecordPersistence().persistFiles(storageDir, [
      (recordId: 'boom', relativeSegments: ['record.json'], bytes: _recordJson('boom')),
    ]);

    expect(result.statuses['boom'], WebRecordPersistenceStatus.failed);
    expect(result.committedIds, isEmpty);
    expect(result.failures['boom'], isA<StateError>());
  });

  test('write failure releases the lock and leaves the active record unchanged', () async {
    var failSecond = true;
    var lockHeld = false;
    final lock = RecordMutationLock((name, mode, action) async {
      if (!name.contains(':record:')) return action();
      expect(lockHeld, isFalse);
      lockHeld = true;
      try {
        return await action();
      } finally {
        lockHeld = false;
      }
    });
    final persistence = WebRecordPersistence(
      mutationLock: lock,
      writeFile: (target, bytes) async {
        if (failSecond && target.name == 'second.bin') {
          throw StateError('synthetic write failure');
        }
        await target.parent.create(recursive: true);
        await target.writeAsBytes(bytes);
      },
    );
    final recordDir = storageDir / 'chara_detail' / 'active' / 'failure-id';
    await recordDir.create(recursive: true);
    await recordDir.filePath('record.json').writeAsBytes(_recordJson('failure-id'));
    await recordDir.filePath('keep.bin').writeAsBytes([7]);
    final files = [
      (recordId: 'failure-id', relativeSegments: ['record.json'], bytes: _recordJson('failure-id')),
      (recordId: 'failure-id', relativeSegments: ['first.bin'], bytes: Uint8List.fromList([1])),
      (recordId: 'failure-id', relativeSegments: ['second.bin'], bytes: Uint8List.fromList([2])),
    ];

    final failed = await persistence.persistFiles(storageDir, files);
    expect(failed.statuses['failure-id'], WebRecordPersistenceStatus.failed);
    expect(lockHeld, isFalse);
    expect(await recordDir.filePath('keep.bin').readAsBytes(), [7]);
    expect(await recordDir.filePath('first.bin').exists(), isFalse);
    expect(await recordDir.filePath('second.bin').exists(), isFalse);

    failSecond = false;
    final recovered = await persistence.persistFiles(storageDir, files);
    expect(recovered.statuses['failure-id'], WebRecordPersistenceStatus.completed);
    expect(await recordDir.filePath('second.bin').exists(), isTrue);
    expect(lockHeld, isFalse);
  });
}

String _slotName(String id) => base64Url.encode(utf8.encode('publish-active-record:$id')).replaceAll('=', '');

/// Fails the very first filesystem probe `WebRecordWriteTransaction.publish`
/// makes for one record's slot, which sits outside its own error handling.
final class _ThrowOnSlotProbeBackend extends WebLikeFsBackend {
  _ThrowOnSlotProbeBackend(super.inner, this.slotName);

  final String slotName;

  @override
  Future<bool> exists(String path) {
    if (path.endsWith(slotName)) throw StateError('synthetic slot probe failure');
    return super.exists(path);
  }
}

String _recordLockName(String id) {
  final encoded = base64Url.encode(utf8.encode(id)).replaceAll('=', '');
  return 'umacapture:v1:record:$encoded';
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

final class _IngestionConcurrencyProbe {
  _IngestionConcurrencyProbe({this.expectedBeforeRelease = 1});

  final int expectedBeforeRelease;
  final firstEntered = Completer<void>();
  final allExpectedEntered = Completer<void>();
  final release = Completer<void>();
  int entered = 0;

  Future<void> write(FilePath target, Uint8List bytes) async {
    entered++;
    if (!firstEntered.isCompleted) firstEntered.complete();
    if (entered == expectedBeforeRelease && !allExpectedEntered.isCompleted) {
      allExpectedEntered.complete();
    }
    await release.future;
    await target.parent.create(recursive: true);
    await target.writeAsBytes(bytes);
  }
}

final class _PerNameExclusiveRunner {
  final _held = <String>{};
  final _changed = <String, Completer<void>>{};

  Future<Object?> call(String name, RecordMutationLockMode mode, Future<Object?> Function() action) async {
    if (!name.contains(':record:')) return action();
    while (_held.contains(name)) {
      await (_changed[name] ??= Completer<void>()).future;
    }
    _held.add(name);
    try {
      return await action();
    } finally {
      _held.remove(name);
      _changed.remove(name)?.complete();
    }
  }
}
