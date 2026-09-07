// The data-root relocation is the sixth long reader to register, and the widest
// one: it is the only registered kind that holds trees outside the record store.
//
//   .fvm/flutter_sdk/bin/flutter test test/data_root_relocation_long_read_claim_test.dart
//
// WHY THIS OPERATION. `DataRootMigrationController.migrate` renames `storage/`,
// `modules/` and the settings box away wholesale. Every delete the storage view
// offers over any of those three trees was live for the length of the copy, and
// the copy is the longest file operation in the app.
//
// WHY THE CLAIM IS OBSERVED AT RUN TIME. `long_read_registry_test.dart` scans for
// the *presence* of a `declaration:` argument; it cannot tell a claim from a
// `LongReadDeclaration.none`, cannot check which paths a claim names, and cannot
// see whether it is still on while the trees are being renamed. Both cases below
// therefore drive the real `migrate` and read the registry from inside it.
//
// WHAT THIS SUITE CANNOT REACH.
//  * Web. `migrate` returns `refusedSessionIntact` under `kIsWeb` before it
//    reaches the gate at all — OPFS is the storage root and there is nothing to
//    relocate — so there is no web claim to assert.
//  * The last step of a real relocation. Writing the bootstrap override goes
//    through `getApplicationSupportDirectory()`, which has no plugin under
//    `flutter_test`, so the positive control below ends at `failedAfterClose` —
//    past the copy, which is what it is here to witness.
//  * Whether the dialog's screens are reachable while the claim is on. They are
//    not, and that is why this claim buys less on screen than the others; what it
//    buys is that the registry is a true account of what is held, which every
//    subscriber added later reads.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/data_root_migration.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/storage/storage_lock_scope.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

late Directory _tempRoot;
late PathInfo _source;
late DirectoryPath _target;

/// Every root the storage view offers a delete over, split by whether the
/// relocation's claim is supposed to cover it.
///
/// **A total function over the group table**, for the reason
/// `record_scan_long_read_claim_test.dart` gives for its own: the failure mode of
/// a claim like this one is naming some of what it moves, and a case that guards
/// it with a second hand-written list fails in the same way. Classified against
/// [DataRootMigrationController.movedRoots] — the same enumeration `pairs` copies
/// from — so a tree added to the migration moves both sides of this case at once.
({List<PathEntity> covered, List<PathEntity> untouched}) _deletableRootsByCoverage(List<DirectoryPath> moved) {
  final covered = <PathEntity>[];
  final untouched = <PathEntity>[];
  for (final group in storageGroups) {
    if (!group.operations.contains(StorageOperation.delete)) {
      continue;
    }
    for (final root in group.resolve(_source)) {
      // Both directions, as `storageDeleteAwaitsExtraction` asks them: a root
      // *above* a moved tree is covered too.
      final overlaps = moved.any(
        (tree) => placeStorageTarget([tree], root) != null || placeStorageTarget([root], tree) != null,
      );
      (overlaps ? covered : untouched).add(root);
    }
  }
  return (covered: covered, untouched: untouched);
}

void _expectEveryDeletableRootAgreesWithTheRelocation(
  DataRootMigrationController controller,
  List<LongReadClaim> claims,
) {
  final (:covered, :untouched) = _deletableRootsByCoverage(controller.movedRoots);
  // The check first: a classifier that put every root on one side would agree
  // with any claim at all, including one that holds nothing.
  expect(covered, isNotEmpty, reason: 'no delete root was classified as inside a relocated tree');
  expect(
    untouched,
    isNotEmpty,
    reason: 'no delete root was classified as outside the relocated trees; the case would assert nothing',
  );

  final wrong = <String>[];
  for (final root in covered) {
    final answer = storageDeleteBlockedBy(StorageDeletePathsRequest([root]), claims);
    if (answer != LongReadKind.relocate) wrong.add('${root.path}: expected relocate, got $answer');
  }
  for (final root in untouched) {
    final answer = storageDeleteBlockedBy(StorageDeletePathsRequest([root]), claims);
    if (answer != null) wrong.add('${root.path}: expected no holder, got $answer');
  }
  expect(wrong, isEmpty, reason: wrong.join('; '));
}

ProviderContainer _container() {
  final container = ProviderContainer.test();
  addTearDown(container.dispose);
  return container;
}

bool _relocated() => (_target / 'storage' / 'chara_detail' / 'active' / 'rec-1').existsSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_relocation_claim');
    // Documents and support are deliberately *different* directories, which is
    // what a real desktop layout has and what gives this file a control: with no
    // data-root override in force `modules/` lives under support while `storage/`
    // and the settings box live under documents, so the three claimed roots have
    // no common ancestor and some delete roots fall outside all of them.
    _source = PathInfo(
      documentDir: DirectoryPath('${_tempRoot.path}/documents'),
      supportDir: DirectoryPath('${_tempRoot.path}/support'),
      executableDir: DirectoryPath('${_tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${_tempRoot.path}/downloads'),
    );
    _target = DirectoryPath(Directory('${_tempRoot.path}/target')..createSync(recursive: true));
    final record = _source.charaDetailActiveDir / 'rec-1';
    record.toDirectory().createSync(recursive: true);
    record.filePath('record.json').writeAsStringSync('{}');
  });

  tearDown(() {
    if (_tempRoot.existsSync()) _tempRoot.deleteSync(recursive: true);
  });

  test('a relocation refused the root scope claimed all three trees, and gave them back', () async {
    final container = _container();
    final controller = DataRootMigrationController(source: _source);
    final reached = Completer<void>();
    final release = Completer<void>();

    // Refused rather than completed, so this case can assert the claim without
    // closing Hive — which is one-way for the process. The claim opens before the
    // acquisition, so it is on while the relocation is merely *waiting*, which is
    // time a user is waiting too.
    final busyGate = RecordRecoveryGate(
      mutationLock: RecordMutationLock((name, mode, action) async {
        if (!reached.isCompleted) reached.complete();
        await release.future;
        throw const RecordMutationLockBusy('record-root', Duration(seconds: 1));
      }),
    );

    var stopCalled = false;
    final attempt = controller.migrate(
      _target,
      isCapturing: true,
      // Nothing else is holding the trees here; what these cases watch is the
      // claim this relocation makes for itself.
      blockedBy: null,
      declaration: dataRootRelocationLongReadDeclaration(container.read(containerRefProvider), controller),
      stopCapture: () async => stopCalled = true,
      recoveryGate: busyGate,
    );
    await reached.future;

    final claims = container.read(longReadRegistryProvider).values.toList();
    final claim = claims.single;
    expect(claim.kind, LongReadKind.relocate);
    expect(
      claim.holds.map((hold) => hold.directoryPath),
      controller.movedRoots.map((root) => root.path),
      reason: 'the claim has to name what the copy moves, read off the same enumeration',
    );
    expect(
      claim.holds.map((hold) => hold.directoryPath),
      contains(_source.modulesDir.path),
      reason: 'the control against claiming `storage/` alone: modules is a delete row of its own and is moved too',
    );
    _expectEveryDeletableRootAgreesWithTheRelocation(controller, claims);

    release.complete();
    final outcome = await attempt;

    expect(outcome, MigrationOutcome.refusedSessionIntact);
    expect(stopCalled, isFalse, reason: 'the control: this attempt moved nothing, so it held the trees for the wait');
    expect(_relocated(), isFalse);
    expect(
      container.read(longReadRegistryProvider),
      isEmpty,
      reason: 'a refusal releases too, or the delete stays grey',
    );
  });

  test('positive control: a relocation that really moves the trees holds them past the lock, then releases', () async {
    // Deliberately last in the file, for the reason `data_root_migration_lock_test.dart`
    // states about its own final case: a relocation that gets this far calls
    // `StorageBox.markHiveClosed()`, which is one-way for the process.
    //
    // This is the case the refusal above cannot be: the claim is read at the
    // moment the copy has *finished* and the lock is about to open, which is
    // exactly where the shipped defect lived — the handles are closed, the
    // directories are gone, and a delete offered here would be offered over a
    // path that no longer exists.
    final container = _container();
    final controller = DataRootMigrationController(source: _source);

    List<LongReadClaim>? atRelease;
    var movedWhenObserved = false;
    final gate = RecordRecoveryGate(
      mutationLock: RecordMutationLock((name, mode, action) async {
        try {
          return await action();
        } finally {
          atRelease = container.read(longReadRegistryProvider).values.toList();
          movedWhenObserved = _relocated();
        }
      }),
    );

    final outcome = await controller.migrate(
      _target,
      isCapturing: false,
      blockedBy: null,
      declaration: dataRootRelocationLongReadDeclaration(container.read(containerRefProvider), controller),
      recoveryGate: gate,
    );

    // Not asserted as `succeeded`: the override write has no plugin here (see the
    // header), so this run ends past the copy and short of the override.
    expect(outcome, isNot(MigrationOutcome.refusedSessionIntact));
    expect(movedWhenObserved, isTrue, reason: 'the observation point is before the copy, so it says nothing');
    expect(_relocated(), isTrue, reason: 'the control: a relocation that moved nothing proves nothing about its claim');
    expect(atRelease?.single.kind, LongReadKind.relocate, reason: 'the claim was already off when the lock opened');
    expect(container.read(longReadRegistryProvider), isEmpty, reason: 'held for the relocation, not for the session');
  });
}
