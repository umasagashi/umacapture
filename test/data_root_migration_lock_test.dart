// The data-root relocation is a record mutation, and takes the same exclusive
// root scope as the bulk scan and the archive geometry repair.
//
// Moving `storage/` moves every record directory at once, while a store scan's
// worker isolates may be decoding — and quarantining — out of the very tree being
// renamed. Nothing else in the app can exclude that: the scan takes the root
// scope, so the relocation has to take it too.
//
// Named wrong implementations these reject:
//   - no acquisition at all: the relocation proceeds while another party holds
//     the root scope, so `stopCapture` fires and the destination appears;
//   - the acquisition placed after the point of no return (Hive closed, capture
//     stopped, directories swapped): the same observations fire;
//   - a `shared` acquisition, or a per-record one: neither is refused by an
//     exclusive holder, so the relocation would again proceed.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/data_root_migration_lock_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/data_root_migration.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';

import 'support/long_read_declarations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late PathInfo source;
  late DirectoryPath target;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_dataroot_lock');
    final sourceRoot = DirectoryPath(Directory('${tempRoot.path}/source')..createSync(recursive: true));
    target = DirectoryPath(Directory('${tempRoot.path}/target')..createSync(recursive: true));
    source = PathInfo(
      documentDir: sourceRoot,
      supportDir: sourceRoot,
      executableDir: sourceRoot,
      downloadDir: sourceRoot,
    );
    // One real record directory, so a relocation that runs has something to move
    // and its arrival at the destination is observable.
    final record = source.charaDetailActiveDir / 'rec-1';
    record.toDirectory().createSync(recursive: true);
    record.filePath('record.json').writeAsStringSync('{}');
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  bool relocated() => (target / 'storage' / 'chara_detail' / 'active' / 'rec-1').existsSync();

  test('a relocation is refused while another party holds the root record scope', () async {
    // A short budget so the refusal is the *outcome* under test rather than a
    // 150s wait; the production budget is exercised by the lock's own suite.
    final locks = InProcessNamedLocks(acquireTimeout: const Duration(milliseconds: 100));
    final gate = RecordRecoveryGate(mutationLock: RecordMutationLock(locks.run));
    final release = Completer<void>();

    // Stands in for a bulk scan in flight: the same name, the same mode.
    final holder = gate.runForRoot(
      source.storageDir,
      (_) => release.future,
      declaration: undeclaredInTest,
      reason: RootMaintenanceReason.readyToUse,
      beforeMaintenance: const BeforeRootMaintenance.none(reason: 'this holder surveys nothing'),
    );
    var stopCalled = false;

    final outcome = await DataRootMigrationController(source: source).migrate(
      target,
      isCapturing: true,
      // No registered long reader in these cases: they are about the root record
      // scope, which is the other half of the refusal.
      blockedBy: null,
      declaration: undeclaredInTest,
      stopCapture: () async => stopCalled = true,
      recoveryGate: gate,
    );

    expect(outcome.isSuccess, isFalse);
    // Nothing was done, not merely "not finished": the acquisition sits ahead of
    // every irreversible step, so a refusal leaves the session usable and the old
    // location authoritative.
    //
    // And the caller is told so. The dialog is non-dismissible and drops its
    // close button once Hive is closed, so a refusal reported as a bare failure
    // leaves a fully healthy session with no exit but quit or relaunch — for an
    // attempt that moved nothing and is retryable as soon as the startup scan
    // holding the scope is done.
    expect(outcome, MigrationOutcome.refusedSessionIntact);
    expect(outcome.sessionUsable, isTrue);
    expect(stopCalled, isFalse, reason: 'capture was stopped before the scope was granted');
    expect(relocated(), isFalse);
    expect((source.charaDetailActiveDir / 'rec-1').existsSync(), isTrue);

    release.complete();
    await holder;
  });

  test('positive control: with the scope free, the same observations fire', () async {
    // The refusal above is a claim of absence, so the measurement has to be shown
    // reacting. Same call, same observation points, only the holder removed.
    //
    // Deliberately last in the file: a relocation that gets this far calls
    // `StorageBox.markHiveClosed()`, which is one-way for the process.
    final locks = InProcessNamedLocks(acquireTimeout: const Duration(milliseconds: 100));
    final gate = RecordRecoveryGate(mutationLock: RecordMutationLock(locks.run));
    var stopCalled = false;

    final outcome = await DataRootMigrationController(source: source).migrate(
      target,
      isCapturing: true,
      // No registered long reader in these cases: they are about the root record
      // scope, which is the other half of the refusal.
      blockedBy: null,
      declaration: undeclaredInTest,
      stopCapture: () async => stopCalled = true,
      recoveryGate: gate,
    );

    // The control for the refusal's `sessionUsable`: a relocation that got in
    // did close Hive, so the same bit has to come back false. Otherwise the
    // dialog would offer a close button on a session that cannot read settings.
    //
    // Not asserted as `succeeded`: the last step of a relocation writes the
    // bootstrap override through `getApplicationSupportDirectory()`, which has
    // no plugin implementation under `flutter_test`, so this run ends at
    // `failedAfterClose` -- past the close, which is what is under test here,
    // and deliberately short of writing an override into the real user profile.
    expect(outcome, isNot(MigrationOutcome.refusedSessionIntact));
    expect(outcome.sessionUsable, isFalse);
    expect(stopCalled, isTrue);
    expect(relocated(), isTrue);
    expect(locks.isIdle, isTrue, reason: 'the scope has to be released once the relocation is over');
  });
}
