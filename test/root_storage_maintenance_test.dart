import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_directory_transaction.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/root_storage_maintenance.dart';
import 'package:umacapture/src/core/fs/root_storage_maintenance_web.dart';
import 'package:umacapture/src/core/fs/web_record_write_transaction.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';

import 'support/web_like_fs_backend.dart';

void main() {
  final request = RootStorageMaintenanceRequest(recordDataRoot: DirectoryPath(['storage', 'chara_detail']));
  late FsBackend originalBackend;

  // root_storage_maintenance_web.dart is web-only, so it is exercised against
  // `WebLikeFsBackend`: a sync FS call added here by reflex fails on the VM
  // instead of passing CI and breaking only on web. That pins OPFS's
  // *synchronous* prohibition and nothing else -- see
  // `support/web_like_fs_backend.dart` for what this backend does not model.
  setUp(() {
    originalBackend = fsBackend;
    fsBackend = WebLikeFsBackend(originalBackend);
  });
  tearDown(() => fsBackend = originalBackend);

  test('pathInfo startup boundary invokes maintenance once for the record root', () async {
    final info = PathInfo(
      documentDir: DirectoryPath(['documents', 'umacapture']),
      supportDir: DirectoryPath(['support']),
      executableDir: DirectoryPath(['executable']),
      downloadDir: DirectoryPath(['downloads']),
    );
    final maintenance = _RecordingMaintenance();

    await runPathInfoStartupMaintenance(info, maintenance: maintenance);

    expect(maintenance.requests, hasLength(1));
    expect(maintenance.requests.single.recordDataRoot.path, info.charaDetailDir.path);
  });

  test('recovery and cleanup run once under one root lock', () async {
    final events = <String>[];
    final lock = RecordMutationLock((name, mode, action) async {
      expect(name, contains(':root'));
      expect(mode, RecordMutationLockMode.exclusive);
      events.add('lock-enter');
      final result = await action();
      events.add('lock-exit');
      return result;
    });
    final maintenance = WebRootStorageMaintenance(
      mutationLock: lock,
      recoverWrites: (dataRoot) async {
        expect(dataRoot.path, request.recordDataRoot.path);
        events.add('write-recovery');
        return const [];
      },
      recover: (dataRoot) async {
        expect(dataRoot.path, request.recordDataRoot.path);
        events.add('archive-recovery');
        return const <RecordTransactionRecovery>[];
      },
      cleanup: (recoveries) async {
        expect(recoveries, isEmpty);
        events.add('cleanup');
      },
    );

    await maintenance.run(request);

    expect(events, ['lock-enter', 'write-recovery', 'archive-recovery', 'cleanup', 'lock-exit']);
  });

  test('cleanup keeps a record mutation behind the root gate', () async {
    final gate = _RootGateRunner();
    final lock = RecordMutationLock(gate.call);
    final cleanupStarted = Completer<void>();
    final finishCleanup = Completer<void>();
    final events = <String>[];
    final maintenance = WebRootStorageMaintenance(
      mutationLock: lock,
      recover: (_) async => const <RecordTransactionRecovery>[],
      cleanup: (_) async {
        events.add('cleanup-start');
        cleanupStarted.complete();
        await finishCleanup.future;
        events.add('cleanup-end');
      },
    );

    final maintenanceFuture = maintenance.run(request);
    await cleanupStarted.future;
    final recordFuture = lock.runForRecord('record-id', () async {
      events.add('record-mutation');
    });
    await Future<void>.delayed(Duration.zero);
    expect(events, ['cleanup-start']);

    finishCleanup.complete();
    await Future.wait([maintenanceFuture, recordFuture]);
    expect(events, ['cleanup-start', 'cleanup-end', 'record-mutation']);
  });

  test('a data root is swept once per session, and a failed sweep is retried', () async {
    var sweeps = 0;
    var fail = true;
    final maintenance = WebRootStorageMaintenance(
      mutationLock: RecordMutationLock((_, _, action) => action()),
      recoverWrites: (_) async {
        sweeps++;
        if (fail) throw StateError('synthetic sweep failure');
        return const [];
      },
      recover: (_) async => const <RecordTransactionRecovery>[],
      cleanup: (_) async {},
    );

    // A sweep that threw leaves nothing recovered, so it must run again.
    await expectLater(maintenance.run(request), throwsA(isA<StateError>()));
    expect(sweeps, 1);
    fail = false;
    await maintenance.run(request);
    expect(sweeps, 2);

    // The store-wide scan recovers what a *previous* page session left behind;
    // repeating it for the active and archive store scans is pure cost.
    await maintenance.run(request);
    await maintenance.runUnlocked(request);
    expect(sweeps, 2);

    // A different data root is still swept.
    await maintenance.run(RootStorageMaintenanceRequest(recordDataRoot: DirectoryPath(['other', 'chara_detail'])));
    expect(sweeps, 3);
  });

  // The sweep no longer classifies what recovery could not finish. It used to
  // sort each outcome into "stops the store", "refuses its own record" and "not
  // ours", and abort for the first bucket -- which spent the whole app on a slot
  // whose remedies (the record list, and a repair button that has since gone as
  // well) only existed once the app was open. The two enumerations below are the
  // same shape they always were, and
  // the property they buy is the same one in the opposite direction: a *new* enum
  // member that made the sweep abort has to fail here rather than quietly close
  // the door again.
  //
  // What is deliberately not asserted is which slots survive the sweep intact:
  // that belongs to the recovery machines themselves, and lands in quarantine
  // rather than in a verdict.

  test('no web record write outcome stops the sweep', () async {
    for (final result in WebRecordWriteResult.values) {
      final events = <String>[];
      final maintenance = WebRootStorageMaintenance(
        mutationLock: RecordMutationLock((_, _, action) => action()),
        recoverWrites: (_) async => [WebRecordWriteRecovery(recordId: 'id', result: result)],
        recover: (_) async {
          events.add('archive');
          return const [];
        },
        cleanup: (_) async => events.add('cleanup'),
      );
      await maintenance.run(request);
      expect(events, ['archive', 'cleanup'], reason: result.name);
    }
  });

  test('no archive recovery outcome stops the sweep', () async {
    for (final result in RecordTransactionResult.values) {
      final events = <String>[];
      final maintenance = WebRootStorageMaintenance(
        mutationLock: RecordMutationLock((_, _, action) => action()),
        recoverWrites: (_) async => const [],
        recover: (_) async {
          events.add('recover');
          return [RecordTransactionRecovery(null, result)];
        },
        cleanup: (_) async => events.add('cleanup'),
      );

      await maintenance.run(request);
      expect(events, ['recover', 'cleanup'], reason: result.name);
    }
  });

  test('a write recovery that cannot be finished no longer stops the sweep', () async {
    final root = Directory.systemTemp.createTempSync('umacapture_root_write_failure');
    addTearDown(() => root.deleteSync(recursive: true));
    final dataRoot = DirectoryPath(root.path) / 'chara_detail';
    final finalDir = dataRoot / 'active' / 'ready-failure';
    await finalDir.create(recursive: true);
    await finalDir.filePath('record.json').writeAsBytes(_recordJson('ready-failure'));
    final failing = WebRecordWriteTransaction(
      copyTree: (source, target) async {
        if (target.path.contains('active')) throw StateError('synthetic final publish failure');
        return source.copyTreeInto(target);
      },
    );
    expect(
      await failing.publish(dataRoot, 'ready-failure', [
        (relativeSegments: ['record.json'], bytes: _recordJson('ready-failure')),
        (relativeSegments: ['new.bin'], bytes: Uint8List.fromList([1])),
      ]),
      WebRecordWriteResult.incomplete,
    );
    var archives = 0;
    final maintenance = WebRootStorageMaintenance(
      mutationLock: RecordMutationLock((_, _, action) => action()),
      recoverWrites: WebRecordWriteTransaction(
        copyTree: (source, target) async {
          if (target.path.contains('active')) throw StateError('synthetic final publish failure');
          return source.copyTreeInto(target);
        },
      ).recoverAll,
      recover: (_) async {
        archives++;
        return const [];
      },
      cleanup: (_) async {},
    );
    // `incomplete` on a real slot is the worst case the write machine produces:
    // the resume moved `active/<id>/` aside into the slot and then threw before
    // the copy, so the final tree really is mid-replacement. It used to abort
    // the sweep. It no longer does -- archive recovery runs behind it, and the
    // slot is still there for the resume that works.
    await maintenance.run(RootStorageMaintenanceRequest(recordDataRoot: dataRoot));
    expect(archives, 1);
    expect((await WebRecordWriteTransaction().recoverAll(dataRoot)).single.result, WebRecordWriteResult.completed);
    expect(await finalDir.filePath('new.bin').readAsBytes(), [1]);
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

final class _RecordingMaintenance implements RootStorageMaintenance {
  final requests = <RootStorageMaintenanceRequest>[];

  @override
  Future<void> run(RootStorageMaintenanceRequest request) async {
    requests.add(request);
  }

  @override
  Future<void> runUnlocked(RootStorageMaintenanceRequest request) async {
    requests.add(request);
  }
}

final class _RootGateRunner {
  bool _exclusive = false;
  int _shared = 0;
  Completer<void>? _stateChanged;

  Future<Object?> call(String name, RecordMutationLockMode mode, Future<Object?> Function() action) async {
    if (!name.endsWith(':root')) return action();
    if (mode == RecordMutationLockMode.exclusive) {
      while (_exclusive || _shared != 0) {
        await _waitForChange();
      }
      _exclusive = true;
      try {
        return await action();
      } finally {
        _exclusive = false;
        _signalChange();
      }
    }

    while (_exclusive) {
      await _waitForChange();
    }
    _shared++;
    try {
      return await action();
    } finally {
      _shared--;
      _signalChange();
    }
  }

  Future<void> _waitForChange() {
    return (_stateChanged ??= Completer<void>()).future;
  }

  void _signalChange() {
    final changed = _stateChanged;
    _stateChanged = null;
    changed?.complete();
  }
}
