// The exclusion invariant between the one-time archive geometry migration and
// the bulk record scan.
//
// Both write under `archive/<id>`: the migration deletes `prediction.json` and
// rewrites geometry json from a `compute` isolate, while the scan's worker
// isolates can `moveSyncSafe` an entire record directory into `quarantine/` when
// its `record.json` will not decode. Neither worker can take the desktop lock
// (`InProcessNamedLocks` is per-isolate state), so each party takes the exclusive
// root scope on the UI isolate and holds it across the boundary.
//
// The assertion here is on the *invariant*, not on an ordering: whichever party
// wins the queue, the other party's file effect must not be observable while the
// winner's critical section is still open. That holds for either interleaving, so
// nothing in this file depends on which one the scheduler picks.
//
// Named wrong implementations this rejects:
//   - either party not acquiring at all (no acquisition recorded for its tag);
//   - the two acquiring different lock names (they would exclude nothing);
//   - acquiring in `shared` mode (two shared holders run together);
//   - acquiring and releasing *around* the work instead of holding across it
//     (the party's own effect would not yet be present at its release).
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_archive_migration_lock_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/record_loader_io.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';

import 'support/hive.dart';
import 'support/records.dart';

/// One observation of a lock acquisition boundary, with the world state at it.
typedef _Event = ({String tag, String phase, String lockName, RecordMutationLockMode mode, bool migrated, bool moved});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeMappers);

  useHiveForTest(['data_migration']);

  late Directory tempRoot;
  late PathInfo pathInfo;
  late DirectoryPath archiveDir;
  late DirectoryPath quarantineDir;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_archive_lock_test');
    final root = DirectoryPath(tempRoot);
    pathInfo = PathInfo(documentDir: root, supportDir: root, executableDir: root, downloadDir: root);
    archiveDir = pathInfo.charaDetailArchiveDir;
    quarantineDir = pathInfo.charaDetailQuarantineDir;
    archiveDir.toDirectory().createSync(recursive: true);

    // A record the migration has work to do on: `prediction.json` is what it
    // deletes unconditionally, so its disappearance dates the migration's write.
    final good = archiveDir / 'mig-1';
    good.toDirectory().createSync(recursive: true);
    good.filePath('record.json').writeAsStringSync(jsonEncode(makeRecord(id: 'mig-1', card: 1).toMap()));
    good.filePath('prediction.json').writeAsStringSync('{}');

    // A record the scan cannot decode, so the scan quarantines its directory:
    // the appearance of `quarantine/bad-1` dates the scan's write.
    final bad = archiveDir / 'bad-1';
    bad.toDirectory().createSync(recursive: true);
    bad.filePath('record.json').writeAsStringSync('{ this is not json');
  });

  tearDown(() async {
    // AWAITED. `Box.clear()` is a Future: leaving it unawaited lets the next test start while the
    // "archive geometry migrated" flag is still on disk, and a migration that believes it has
    // already run never completes `migrationDone` -- so the positive control below hangs on
    // `await migrationDone.future` until the suite's own timeout, and reads as a failure of the
    // exclusion invariant rather than of the teardown. The other Hive-backed suites on this branch
    // await theirs.
    await Hive.box<dynamic>('data_migration').clear();
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  bool migrated() => !(archiveDir / 'mig-1').filePath('prediction.json').existsSync();
  bool moved() => (quarantineDir / 'bad-1').existsSync();

  /// Violations of "the two critical sections never overlap", read off [events].
  ///
  /// Deliberately derived from the recorded trace rather than asserted inline, so
  /// the positive control below can show the same function reacting.
  List<String> overlaps(List<_Event> events) {
    final violations = <String>[];
    final open = <String>{};
    for (final event in events) {
      if (event.phase == 'enter') {
        if (open.isNotEmpty) {
          violations.add('${event.tag} entered while ${open.join(', ')} was still inside');
        }
        open.add(event.tag);
      } else {
        open.remove(event.tag);
      }
    }
    // A party that never acquired cannot overlap in the trace, and that is
    // precisely the implementation this must reject: report it as a violation of
    // its own.
    for (final tag in const ['migration', 'scan']) {
      if (!events.any((e) => e.tag == tag)) {
        violations.add('$tag never acquired anything');
      }
    }
    return violations;
  }

  /// A gate over [locks] that records both boundaries of every acquisition.
  RecordRecoveryGate recordingGate(InProcessNamedLocks locks, String tag, List<_Event> events) {
    return RecordRecoveryGate(
      mutationLock: RecordMutationLock((name, mode, action) async {
        return locks.run(name, mode, () async {
          events.add((tag: tag, phase: 'enter', lockName: name, mode: mode, migrated: migrated(), moved: moved()));
          try {
            return await action();
          } finally {
            events.add((tag: tag, phase: 'exit', lockName: name, mode: mode, migrated: migrated(), moved: moved()));
          }
        });
      }),
    );
  }

  test('the migration and the bulk scan never hold the archive at the same time', () async {
    final locks = InProcessNamedLocks();
    final events = <_Event>[];

    // Started in the same turn of the event loop, exactly as app startup does:
    // one provider chain runs the migration while another starts a store scan.
    await Future.wait([
      runArchiveGeometryMigrationIfNeeded(pathInfo, recoveryGate: recordingGate(locks, 'migration', events)),
      loadRecordsUnder(archiveDir, recoveryGate: recordingGate(locks, 'scan', events)),
    ]);

    // Both parties acquired, and both acquired the *same* name exclusively.
    // The name assertion is not vacuous even though the root name is a constant:
    // it is what rejects an implementation that reaches for record scope instead
    // (`runForRecord`/`runForRecords` derive a per-id name and additionally take
    // root only in `shared` mode), which would exclude neither party from the
    // other. The mode assertion rejects the same implementation's shared root.
    final acquisitions = {for (final event in events) event.tag: event};
    expect(acquisitions.keys, containsAll(<String>['migration', 'scan']));
    expect(acquisitions.values.map((e) => e.lockName).toSet(), hasLength(1));
    expect(acquisitions.values.map((e) => e.mode).toSet(), {RecordMutationLockMode.exclusive});
    // Exactly one acquisition each, so a per-record fan-out of acquisitions —
    // which could interleave with the other party between two of its own — is
    // rejected rather than averaged away by the checks below.
    expect(events, hasLength(4), reason: 'trace: $events');

    expect(overlaps(events), isEmpty, reason: 'trace: $events');

    // The work happened *inside* the acquisition, not before or after it: at its
    // release each party's own effect is already on disk.
    expect(events.singleWhere((e) => e.tag == 'migration' && e.phase == 'exit').migrated, isTrue);
    expect(events.singleWhere((e) => e.tag == 'scan' && e.phase == 'exit').moved, isTrue);

    // The invariant itself, stated without reference to who won: at the first
    // release, the other party's write has not happened yet.
    final firstExit = events.firstWhere((e) => e.phase == 'exit');
    if (firstExit.tag == 'migration') {
      expect(firstExit.moved, isFalse, reason: 'the scan quarantined a directory during the migration');
    } else {
      expect(firstExit.migrated, isFalse, reason: 'the migration rewrote a record during the scan');
    }

    // Both effects did land, so the test is not passing over work that never ran.
    expect(migrated(), isTrue);
    expect(moved(), isTrue);
  });

  test('positive control: the same trace check reports the overlap when nothing excludes the two', () async {
    final events = <_Event>[];
    final released = Completer<void>();
    final migrationDone = Completer<void>();

    // Stands in for the migration holding the root scope: it records the same
    // boundaries, does the same work, and then stays inside its critical section
    // until this test lets it out. No real lock, so nothing is excluded.
    final holdingGate = RecordRecoveryGate(
      mutationLock: RecordMutationLock((name, mode, action) async {
        events.add((
          tag: 'migration',
          phase: 'enter',
          lockName: name,
          mode: mode,
          migrated: migrated(),
          moved: moved(),
        ));
        final result = await action();
        migrationDone.complete();
        await released.future;
        events.add((tag: 'migration', phase: 'exit', lockName: name, mode: mode, migrated: migrated(), moved: moved()));
        return result;
      }),
    );

    final migration = runArchiveGeometryMigrationIfNeeded(pathInfo, recoveryGate: holdingGate);
    await migrationDone.future;

    // The scan runs to completion while the migration is still inside, through a
    // gate that *records* its boundaries but excludes nothing. That is what makes
    // this a control for the overlap detector itself and not merely for its
    // "never acquired" arm: the scan does contribute a full enter/exit pair, so
    // the trace is a genuine nesting.
    await loadRecordsUnder(
      archiveDir,
      recoveryGate: RecordRecoveryGate(
        mutationLock: RecordMutationLock((name, mode, action) async {
          events.add((tag: 'scan', phase: 'enter', lockName: name, mode: mode, migrated: migrated(), moved: moved()));
          try {
            return await action();
          } finally {
            events.add((tag: 'scan', phase: 'exit', lockName: name, mode: mode, migrated: migrated(), moved: moved()));
          }
        }),
      ),
    );
    expect(moved(), isTrue, reason: 'the control needs the scan to really have written');

    released.complete();
    await migration;

    // Both parties acquired, so the "never acquired" arm is silent and what fires
    // is the nesting arm — the property the real test asserts the absence of.
    final violations = overlaps(events);
    expect(violations, hasLength(1));
    expect(violations.single, contains('scan entered while migration'));

    // ...and the file-level measurement reacts too: the migration's release sees
    // the scan's quarantine move already on disk, which is exactly the
    // observation the real test asserts cannot happen.
    expect(events.singleWhere((e) => e.tag == 'migration' && e.phase == 'exit').moved, isTrue);
  });
}
