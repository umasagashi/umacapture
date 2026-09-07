// The storage view's delete engine: which exclusion it takes, and what it reports
// about the entries it could not remove.
//
// Two claims are pinned here that nothing else in the suite can see.
//
//  1. **The per-group lock table is obeyed at the level of lock *names*.** Only
//     active and archive directories are named by record id; quarantine and
//     retired carry a de-duplicating `<name>_n` suffix and so take the exclusive
//     root instead. A delete that
//     calls `runForRecord` with a quarantine directory's `<name>_1` acquires a
//     name no writer will ever contend for, so it excludes nobody while reading
//     as if it excludes everyone. The scope suite asserts the plan; this one
//     asserts the acquisitions the plan produces, because that is the layer where
//     the false comfort is observable at all.
//  2. **Partial success is representable and produced.** A folder in which
//     one file is held has to come back as "these went, that one stayed", not as
//     a success and not as a failure.
//
// The backend under the whole file is `WebLikeFsBackend`, whose synchronous
// surface throws exactly as the OPFS backend's does. That is not incidental: the
// delete engine has to be usable from the browser build, and a path that reached
// `deleteSync` would pass on the VM's io backend and fail only in a browser.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/storage_delete.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';

import 'support/long_read_declarations.dart';
import 'support/riverpod.dart';
import 'support/web_like_fs_backend.dart';

/// The lock name `RecordMutationLock` builds for a record id, spelled here so a
/// test can assert on the name rather than on the call that produced it.
String _recordLockName(String id) => 'umacapture:v1:record:${base64Url.encode(utf8.encode(id)).replaceAll('=', '')}';

const _rootLockName = 'umacapture:v1:root';

typedef _Acquisition = ({String name, RecordMutationLockMode mode});

/// An [ExclusiveLockRunner] that records every acquisition and then delegates to
/// a real [InProcessNamedLocks], so the same object answers "which names?" and
/// "does it actually block?".
class _RecordingLocks {
  _RecordingLocks({this.refuse});

  /// Names for which acquisition fails with [RecordMutationLockBusy], standing in
  /// for the 150 s budget expiring against another tab.
  final bool Function(String name)? refuse;

  final inner = InProcessNamedLocks();
  final acquired = <_Acquisition>[];

  Iterable<String> get names => acquired.map((e) => e.name);

  Future<Object?> run(String name, RecordMutationLockMode mode, Future<Object?> Function() action) {
    acquired.add((name: name, mode: mode));
    if (refuse?.call(name) ?? false) {
      throw RecordMutationLockBusy(name, const Duration(seconds: 150));
    }
    return inner.run(name, mode, action);
  }
}

/// Delegates to the io backend but refuses [refuse] paths, and pauses on
/// [pauseOn] until the returned completer is completed.
///
/// This is how a held file is produced deterministically: actually holding one
/// open depends on the operating system's sharing rules, which differ between the
/// two platforms this engine has to work on, so the refusal is injected at the
/// boundary the engine talks to instead.
class _ObstructedFsBackend extends WebLikeFsBackend {
  _ObstructedFsBackend(super.inner, {this.refuse, this.pauseOn, this.gate});

  final bool Function(String path)? refuse;
  final bool Function(String path)? pauseOn;
  final Future<void>? gate;

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    if (pauseOn?.call(path) ?? false) {
      await gate;
    }
    if (refuse?.call(path) ?? false) {
      throw FileSystemException('The process cannot access the file because it is being used', path);
    }
    return super.delete(path, recursive: recursive);
  }
}

/// Records the path of every **recursive** delete the engine issues.
///
/// The read-only fallback works by re-issuing the refused delete recursively, and
/// the whole safety of that manoeuvre is that its root is a single file: a
/// recursive call on a directory would remove entries the report never named.
/// That is a property of the call, not of the outcome, so it is observed here at
/// the backend boundary rather than inferred from what survived.
class _RecursionWatchingFsBackend extends _ObstructedFsBackend {
  _RecursionWatchingFsBackend(super.inner, {super.refuse});

  final recursiveRoots = <String>[];

  @override
  Future<void> delete(String path, {bool recursive = false}) {
    if (recursive) {
      recursiveRoots.add(path);
    }
    return super.delete(path, recursive: recursive);
  }
}

void main() {
  late Directory tempRoot;
  late FsBackend realBackend;
  late PathInfo layout;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_storage_delete');
    realBackend = fsBackend;
    layout = PathInfo(
      documentDir: DirectoryPath('${tempRoot.path}/documents'),
      supportDir: DirectoryPath('${tempRoot.path}/support'),
      executableDir: DirectoryPath('${tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${tempRoot.path}/downloads'),
    );
  });

  tearDown(() {
    fsBackend = realBackend;
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  StorageGroup groupOf(StorageGroupId id) => storageGroups.firstWhere((e) => e.id == id);

  /// Creates [relative] under the temp root and writes a byte into each file.
  void seed(Iterable<String> files) {
    for (final file in files) {
      final entity = File('${tempRoot.path}/$file');
      entity.parent.createSync(recursive: true);
      entity.writeAsStringSync('x');
    }
  }

  ProviderContainer containerWith(_RecordingLocks locks, {StorageDeleteSerializer? serializer}) {
    final gate = RecordRecoveryGate(mutationLock: RecordMutationLock(locks.run));
    final container = ProviderContainer(
      overrides: [
        pathInfoProvider.overrideWithValue(layout),
        // The exclusion resolves its plan from the layout rather than from
        // `pathInfoProvider`, so it keeps working while the record store is
        // unavailable.
        pathLayoutLoader.overrideWith((ref) async => layout),
        storageLockGateProvider.overrideWithValue(gate),
        if (serializer != null) storageDeleteSerializerProvider.overrideWithValue(serializer),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  // Spelled through `PathEntity`, not with a literal separator: the report
  // carries the paths the engine saw, and on Windows those are backslash-joined.
  DirectoryPath activeDir(String id) => layout.charaDetailActiveDir / id;

  String activePath(String id) => activeDir(id).path;

  group('the lock a delete takes is the one the group states', () {
    test('an active record takes the shared root and then its own record name', () async {
      seed(['documents/storage/chara_detail/active/rec-1/record.json']);
      final locks = _RecordingLocks();
      fsBackend = _ObstructedFsBackend(realBackend);
      final container = containerWith(locks);

      final report = await deleteStorageEntry(
        container.read(refBaseProvider),
        group: groupOf(StorageGroupId.activeRecords),
        target: activeDir('rec-1'),
      );

      expect(report.isComplete, isTrue);
      expect(locks.acquired, [
        (name: _rootLockName, mode: RecordMutationLockMode.shared),
        (name: _recordLockName('rec-1'), mode: RecordMutationLockMode.exclusive),
      ]);
    });

    for (final entry in {StorageGroupId.quarantine: 'quarantine', StorageGroupId.retired: 'retired'}.entries) {
      test('${entry.value} takes the exclusive root and no record-shaped name', () async {
        final dir = 'documents/storage/chara_detail/${entry.value}/2026-08-29-broken_1';
        seed(['$dir/record.json']);
        final locks = _RecordingLocks();
        fsBackend = _ObstructedFsBackend(realBackend);
        final container = containerWith(locks);

        final report = await deleteStorageEntry(
          container.read(refBaseProvider),
          group: groupOf(entry.key),
          target: DirectoryPath('${tempRoot.path}/$dir'),
        );

        expect(report.isComplete, isTrue);
        expect(locks.acquired, [(name: _rootLockName, mode: RecordMutationLockMode.exclusive)]);
        // The false comfort this table exists to prevent: `2026-08-29-broken_1`
        // must never
        // reach a record lock, because nobody else would ever ask for that name.
        expect(locks.names.where((e) => e.startsWith('umacapture:v1:record:')), isEmpty);
        expect(locks.names, isNot(contains(_recordLockName('2026-08-29-broken_1'))));
      });
    }

    test('metadata takes no lock at all and goes through the serialiser', () async {
      seed(['documents/storage/chara_detail/metadata/rating/main.json']);
      final locks = _RecordingLocks();
      fsBackend = _ObstructedFsBackend(realBackend);
      final serialised = <String>[];
      final container = containerWith(
        locks,
        serializer: (target, action) async {
          serialised.add(target.path);
          await action();
        },
      );

      final target = layout.charaDetailRatingDir.filePath('main.json');
      final report = await deleteStorageEntry(
        container.read(refBaseProvider),
        group: groupOf(StorageGroupId.metadata),
        target: target,
      );

      expect(report.deletedPaths, [target.path]);
      // Not the gate: the writers of this file take no lock, so an acquisition
      // here would exclude nobody while looking like it excluded everyone.
      expect(locks.acquired, isEmpty);
      expect(serialised, [target.path]);
    });

    test('a group that is not a record store takes nothing and is not serialised', () async {
      seed(['support/modules/version_info.json']);
      final locks = _RecordingLocks();
      fsBackend = _ObstructedFsBackend(realBackend);
      final serialised = <String>[];
      final container = containerWith(
        locks,
        serializer: (target, action) async {
          serialised.add(target.path);
          await action();
        },
      );

      await deleteStorageEntry(
        container.read(refBaseProvider),
        group: groupOf(StorageGroupId.modules),
        target: layout.modulesDir,
      );

      expect(locks.acquired, isEmpty);
      expect(serialised, isEmpty);
    });
  });

  group('a delete in progress blocks a writer on the same record', () {
    /// Starts a delete that is parked inside the filesystem, still holding
    /// whatever lock it took, and answers the release handle.
    ({Future<StorageDeleteReport> delete, Completer<void> release, _RecordingLocks locks}) parkedDelete(String id) {
      final release = Completer<void>();
      final locks = _RecordingLocks();
      fsBackend = _ObstructedFsBackend(
        realBackend,
        pauseOn: (path) => path.endsWith('record.json'),
        gate: release.future,
      );
      final container = containerWith(locks);
      final delete = deleteStorageEntry(
        container.read(refBaseProvider),
        group: groupOf(StorageGroupId.activeRecords),
        target: activeDir(id),
      );
      return (delete: delete, release: release, locks: locks);
    }

    test('a writer on the same id waits until the delete finishes', () async {
      seed(['documents/storage/chara_detail/active/rec-1/record.json']);
      final parked = parkedDelete('rec-1');
      await pumpEventQueue();

      final gate = RecordRecoveryGate(mutationLock: RecordMutationLock(parked.locks.run));
      final writes = <String>[];
      final writer = gate.runForRecord(
        layout.storageDir,
        'rec-1',
        () async => writes.add('rec-1'),
        declaration: undeclaredInTest,
      );
      await pumpEventQueue();

      expect(writes, isEmpty, reason: 'the delete still holds the record lock');
      parked.release.complete();
      expect((await parked.delete).isComplete, isTrue);
      await writer;
      expect(writes, ['rec-1']);
    });

    test('a writer on a different id is not blocked, so the check above is not vacuous', () async {
      seed(['documents/storage/chara_detail/active/rec-1/record.json']);
      final parked = parkedDelete('rec-1');
      await pumpEventQueue();

      final gate = RecordRecoveryGate(mutationLock: RecordMutationLock(parked.locks.run));
      final writes = <String>[];
      final writer = gate.runForRecord(
        layout.storageDir,
        'rec-2',
        () async => writes.add('rec-2'),
        declaration: undeclaredInTest,
      );
      await pumpEventQueue();

      expect(writes, ['rec-2'], reason: 'a different record name excludes nothing');
      parked.release.complete();
      await parked.delete;
      await writer;
    });
  });

  group('the report names what went and what stayed', () {
    test('one held file leaves a partial report naming it and its parent', () async {
      seed([
        'documents/storage/chara_detail/active/rec-1/a.png',
        'documents/storage/chara_detail/active/rec-1/b.png',
        'documents/storage/chara_detail/active/rec-1/record.json',
      ]);
      fsBackend = _ObstructedFsBackend(realBackend, refuse: (path) => path.endsWith('b.png'));
      final container = containerWith(_RecordingLocks());

      final report = await deleteStorageEntry(
        container.read(refBaseProvider),
        group: groupOf(StorageGroupId.activeRecords),
        target: activeDir('rec-1'),
      );

      expect(report.isPartial, isTrue);
      expect(report.isComplete, isFalse);
      expect(report.deletedPaths.length, 2);
      expect(report.failed.single.subject.path, endsWith('b.png'));
      expect(report.failed.single.reason, StorageDeleteFailureReason.refused);
      // The Windows "file is in use" case, the named reason a delete is expected
      // to fail on: the platform's own words
      // travel with the path, so the caller does not have to re-derive them.
      expect(report.failed.single.detail, contains('being used'));
      // Not attempted rather than reported as a second failure, but still named:
      // the user asked for it to go and it did not.
      expect(report.retained, [
        StorageDeleteRetention(
          subject: StorageDeletePathSubject(activePath('rec-1')),
          reason: StorageDeleteRetentionReason.blockedBySurvivor,
        ),
      ]);
      expect(report.requestedCount, 4);
      expect(Directory(activePath('rec-1')).existsSync(), isTrue);
    });

    test('a clean delete reports every entry and nothing else', () async {
      seed([
        'documents/storage/chara_detail/active/rec-1/a.png',
        'documents/storage/chara_detail/active/rec-1/nested/b.png',
      ]);
      fsBackend = _ObstructedFsBackend(realBackend);
      final container = containerWith(_RecordingLocks());

      final report = await deleteStorageEntry(
        container.read(refBaseProvider),
        group: groupOf(StorageGroupId.activeRecords),
        target: activeDir('rec-1'),
      );

      expect(report.isComplete, isTrue);
      expect(report.isPartial, isFalse);
      expect(report.failed, isEmpty);
      expect(report.retained, isEmpty);
      expect(report.requestedCount, 4);
      expect(Directory(activePath('rec-1')).existsSync(), isFalse);
    });

    test('a lock that never frees is reported, not thrown (the web 150 s budget)', () async {
      seed(['documents/storage/chara_detail/active/rec-1/record.json']);
      fsBackend = _ObstructedFsBackend(realBackend);
      final locks = _RecordingLocks(refuse: (name) => name == _recordLockName('rec-1'));
      final container = containerWith(locks);

      final report = await deleteStorageEntry(
        container.read(refBaseProvider),
        group: groupOf(StorageGroupId.activeRecords),
        target: activeDir('rec-1'),
      );

      expect(report.deletedPaths, isEmpty);
      expect(report.failed.single.reason, StorageDeleteFailureReason.lockBusy);
      expect(report.failed.single.subject.path, activePath('rec-1'));
      expect(report.reasons, {StorageDeleteFailureReason.lockBusy});
      expect(File('${activePath('rec-1')}/record.json').existsSync(), isTrue);
    });

    test('a build with no exclusion primitive refuses before touching anything', () async {
      seed(['documents/storage/chara_detail/active/rec-1/record.json']);
      fsBackend = _ObstructedFsBackend(realBackend);
      final container = ProviderContainer(
        overrides: [
          pathInfoProvider.overrideWithValue(layout),
          pathLayoutLoader.overrideWith((ref) async => layout),
          // A `null` runner is what an insecure context or a browser without Web
          // Locks produces; it means "unsupported", never "run unlocked".
          storageLockGateProvider.overrideWithValue(const RecordRecoveryGate(mutationLock: RecordMutationLock(null))),
        ],
      );
      addTearDown(container.dispose);

      final report = await deleteStorageEntry(
        container.read(refBaseProvider),
        group: groupOf(StorageGroupId.activeRecords),
        target: activeDir('rec-1'),
      );

      expect(report.failed.single.reason, StorageDeleteFailureReason.lockUnavailable);
      expect(File('${activePath('rec-1')}/record.json').existsSync(), isTrue);
    });

    test('a target that is already gone is a success covering nothing', () async {
      fsBackend = _ObstructedFsBackend(realBackend);
      final container = containerWith(_RecordingLocks());

      final report = await deleteStorageEntry(
        container.read(refBaseProvider),
        group: groupOf(StorageGroupId.activeRecords),
        target: activeDir('rec-gone'),
      );

      expect(report.isComplete, isTrue);
      // Covering *nothing*, and not covering one deleted entry: this delete
      // removed no file, and `deleted` is what the image-cache eviction reads as
      // the list of files that went. The distinction is load-bearing one branch
      // over, where the same absent target is there again by the time the
      // deletes run because this operation's own drain created it — that one is
      // retained, and it can only be told apart from this one if "was never
      // there" is not already spelled as a deletion (see
      // `storage_journal_delete_recovery_test.dart`).
      expect(report.requestedCount, 0);
      expect(report.deletedPaths, isEmpty);
    });

    test('several targets are added up once, in the report', () async {
      seed([
        'documents/storage/chara_detail/metadata/rating/main.json',
        'documents/storage/chara_detail/metadata/memo/main.json',
      ]);
      fsBackend = _ObstructedFsBackend(realBackend, refuse: (path) => path.contains('memo'));
      final container = containerWith(_RecordingLocks());

      final report = await deleteStorageEntries(
        container.read(refBaseProvider),
        group: groupOf(StorageGroupId.metadata),
        targets: [layout.charaDetailRatingDir.filePath('main.json'), layout.charaDetailMemoDir.filePath('main.json')],
      );

      expect(report.deletedCount, 1);
      expect(report.failedCount, 1);
      expect(report.requestedCount, 2);
      expect(report.isPartial, isTrue);
    });
  });

  group('a read-only refusal is cleared and retried, on a file and only on a file', () {
    // `dart:io` reads a mode through `FileStat` and has nothing that writes one,
    // so the attribute has to be set from outside the VM. `attrib` is the
    // shell's own tool for it and lives here, in the test, only: nothing in
    // `lib/` runs a process to change an attribute, and the fallback under test
    // does not either — it clears the flag as a side effect of a recursive
    // delete.
    Future<void> setReadOnly(String path) async {
      final result = await Process.run('attrib', ['+R', path]);
      expect(result.exitCode, 0, reason: 'attrib +R $path failed: ${result.stderr}');
    }

    const windowsOnly =
        'The read-only attribute is a Windows one and `attrib` is a Windows command. On POSIX the '
        'same refusal comes from a mode bit and a different errno, so this pins nothing there.';

    test('a read-only file is deleted, with that one file as the recursive root', () async {
      seed([
        'documents/storage/chara_detail/active/rec-1/a.png',
        'documents/storage/chara_detail/active/rec-1/record.json',
      ]);
      final readOnly = activeDir('rec-1').filePath('a.png');
      await setReadOnly(readOnly.path);
      final backend = _RecursionWatchingFsBackend(realBackend);
      fsBackend = backend;
      final container = containerWith(_RecordingLocks());

      final report = await deleteStorageEntry(
        container.read(refBaseProvider),
        group: groupOf(StorageGroupId.activeRecords),
        target: activeDir('rec-1'),
      );

      // Before the fallback existed this was a partial report naming `a.png` as a
      // survivor, with its parent retained underneath it.
      expect(report.isComplete, isTrue, reason: report.failed.map((e) => e.detail).join(' / '));
      expect(report.deletedPaths, contains(readOnly.path));
      expect(report.retained, isEmpty);
      expect(Directory(activePath('rec-1')).existsSync(), isFalse);
      // The safety property, asserted directly rather than through the outcome:
      // exactly one recursive delete, and its root is the file that was refused.
      expect(backend.recursiveRoots, [readOnly.path]);
    }, skip: Platform.isWindows ? null : windowsOnly);

    test('a refusal carrying no access-denied code is left alone, not retried recursively', () async {
      seed([
        'documents/storage/chara_detail/active/rec-1/a.png',
        'documents/storage/chara_detail/active/rec-1/record.json',
      ]);
      // The held-file refusal the suite uses elsewhere: a `FileSystemException`
      // with no `osError` at all, which is what a browser refusal also looks like
      // to this predicate. The fallback must not fire for it — "retry every
      // refusal recursively" is exactly what it is not.
      final backend = _RecursionWatchingFsBackend(realBackend, refuse: (path) => path.endsWith('a.png'));
      fsBackend = backend;
      final container = containerWith(_RecordingLocks());

      final report = await deleteStorageEntry(
        container.read(refBaseProvider),
        group: groupOf(StorageGroupId.activeRecords),
        target: activeDir('rec-1'),
      );

      expect(report.isPartial, isTrue);
      expect(report.failed.single.subject.path, activeDir('rec-1').filePath('a.png').path);
      expect(backend.recursiveRoots, isEmpty);
    });

    test(
      'a read-only directory stays a survivor and never becomes a recursive root',
      () async {
        seed(['documents/storage/chara_detail/active/rec-1/nested/b.png']);
        final nested = activeDir('rec-1') / 'nested';
        await setReadOnly(nested.path);
        // The suite's own teardown deletes the temp root recursively, and measured
        // here: that call is refused by a read-only *directory* under it — the VM's
        // recursive delete clears the attribute on files and not on directories.
        addTearDown(() => Process.run('attrib', ['-R', '/S', '/D', '${tempRoot.path}${Platform.pathSeparator}*']));
        final backend = _RecursionWatchingFsBackend(realBackend);
        fsBackend = backend;
        final container = containerWith(_RecordingLocks());

        final report = await deleteStorageEntry(
          container.read(refBaseProvider),
          group: groupOf(StorageGroupId.activeRecords),
          target: activeDir('rec-1'),
        );

        expect(report.isPartial, isTrue);
        expect(report.failed.map((e) => e.subject.path), contains(nested.path));
        expect(Directory(nested.path).existsSync(), isTrue);
        expect(backend.recursiveRoots, isNot(contains(nested.path)));
      },
      skip: Platform.isWindows ? null : windowsOnly,
    );
  });
}
