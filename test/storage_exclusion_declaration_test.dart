// What `runUnderStorageExclusion` does with the declaration its callers hand it.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_exclusion_declaration_test.dart
//
// WHY THIS EXISTS. `runUnderStorageExclusion` is the production path for every
// delete, download and extraction the storage view offers, and it is the one
// frame that applies the caller's `LongReadDeclaration`. That application was
// asserted nowhere: no test in the repository called the function at all, so
// deleting `declaration.runDeclared(` from it left the whole suite green. A
// claim that silently stops being registered is not a visible failure — it is a
// delete button that stays live over a folder somebody is reading, which is the
// exact defect this seam was built to remove.
//
// WHAT EACH CLAIM IS.
//  1. The declaration is applied around **every** scope, not forwarded into the
//     gate. Two of the four scopes (`providerSerialized`, `unlocked`) never
//     reach `RecordRecoveryGate`, so a declaration handed only to the gate calls
//     would vanish for a group whose scope happened to be one of those. The
//     cases are generated from `StorageLockScope.values`, so a fifth scope is
//     covered the day it is added rather than the day somebody remembers.
//  2. The claim is live *while the guarded action runs* and gone once it
//     returns — the window is the operation's, not the lock's.
//  3. It is gone after the action throws, too, and the error still reaches the
//     caller.
//
// WHAT THIS SUITE DOES NOT REACH. Real Web Locks: the gate here is built over
// `InProcessNamedLocks`, the same substitution every other lock suite in this
// repo makes. It says nothing about whether the OS has closed its handles by
// the time the claim comes off — that window is not observable in process, and
// nothing in this repository measures it. And it asserts the exclusion frame
// only; which declaration each of the three call sites passes is theirs to
// state.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_exclusion.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/storage/storage_lock_scope.dart';

import 'support/riverpod.dart';

void main() {
  late Directory tempRoot;
  late PathInfo layout;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_storage_exclusion_declaration');
    layout = PathInfo(
      documentDir: DirectoryPath('${tempRoot.path}/documents'),
      supportDir: DirectoryPath('${tempRoot.path}/support'),
      executableDir: DirectoryPath('${tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${tempRoot.path}/downloads'),
    );
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  ProviderContainer containerOf() {
    final container = ProviderContainer(
      overrides: [
        pathLayoutLoader.overrideWith((ref) async => layout),
        storageLockGateProvider.overrideWithValue(
          RecordRecoveryGate(mutationLock: RecordMutationLock(InProcessNamedLocks().run)),
        ),
        // The real serialiser drops the controller that owns the target file,
        // which is a different subject; what matters here is only that the
        // `providerSerialized` leg runs its action inside the declaration.
        storageDeleteSerializerProvider.overrideWithValue((target, action) => action()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// A real group whose plan resolves to [scope], and a target inside it.
  ///
  /// Chosen from `storageGroups` rather than named here: the case is about the
  /// scope, and pinning a group id would make it about that group instead.
  ({StorageGroup group, PathEntity target}) subjectFor(StorageLockScope scope) {
    for (final group in storageGroups) {
      final roots = group.resolve(layout);
      if (roots.isEmpty) {
        continue;
      }
      final root = roots.first;
      // A per-record plan is resolved from the *child* of the store root; the
      // root itself resolves to `exclusiveRoot`, which is a different leg.
      final target = root is DirectoryPath && group.lockScope == StorageLockScope.perRecord ? root / 'rec-1' : root;
      if (resolveStorageLockPlan(group: group, info: layout, target: target).scope == scope) {
        return (group: group, target: target);
      }
    }
    throw StateError('no storage group resolves a $scope plan; the cases below are asserting nothing about it');
  }

  for (final scope in StorageLockScope.values) {
    test('a claim covers the guarded work of a ${scope.name} target, and is off once it returns', () async {
      final container = containerOf();
      final subject = subjectFor(scope);
      Map<LongReadToken, LongReadClaim> whileRunning = const {};

      final answer = await runUnderStorageExclusion<int>(
        container.read(refBaseProvider),
        group: subject.group,
        target: subject.target,
        intent: StorageExclusionIntent.mutate,
        declaration: LongReadDeclaration.claim(
          registry: container.read(longReadRegistryProvider.notifier),
          kind: LongReadKind.export,
          paths: [subject.target],
        ),
        beforeMaintenance: const BeforeRootMaintenance.none(reason: 'this case is about the declaration, not the set'),
        action: (_) async {
          whileRunning = container.read(longReadRegistryProvider);
          return 7;
        },
      );

      expect(answer, 7, reason: 'the declaration frame changed what the guarded work answered');
      expect(
        whileRunning.values.map((claim) => claim.kind),
        [LongReadKind.export],
        reason:
            'the caller declared a claim and nothing was registered while its work ran, '
            'so a delete over ${subject.target.path} would have been offered',
      );
      expect(
        whileRunning.values.single.holds.map((hold) => hold.directoryPath),
        [subject.target.path],
        reason: 'the claim was registered over paths the caller did not name',
      );
      expect(
        container.read(longReadRegistryProvider),
        isEmpty,
        reason: 'the claim outlived the work it was announced for',
      );
    });
  }

  test('the claim comes off when the guarded work throws, and the error still reaches the caller', () async {
    final container = containerOf();
    final subject = subjectFor(StorageLockScope.exclusiveRoot);

    await expectLater(
      runUnderStorageExclusion<void>(
        container.read(refBaseProvider),
        group: subject.group,
        target: subject.target,
        intent: StorageExclusionIntent.mutate,
        declaration: LongReadDeclaration.claim(
          registry: container.read(longReadRegistryProvider.notifier),
          kind: LongReadKind.zip,
          paths: [subject.target],
        ),
        beforeMaintenance: const BeforeRootMaintenance.none(reason: 'this case is about the declaration, not the set'),
        action: (_) async => throw const FormatException('the guarded work failed'),
      ),
      throwsFormatException,
    );
    expect(
      container.read(longReadRegistryProvider),
      isEmpty,
      reason: 'a failed operation left its paths claimed for the rest of the session',
    );
  });

  test('a declaration that announces nothing leaves the registry alone', () async {
    // The control for the cases above: without it, an implementation that
    // claimed unconditionally — ignoring the declaration entirely — would pass
    // every one of them.
    final container = containerOf();
    final subject = subjectFor(StorageLockScope.perRecord);
    Map<LongReadToken, LongReadClaim> whileRunning = const {};

    await runUnderStorageExclusion<void>(
      container.read(refBaseProvider),
      group: subject.group,
      target: subject.target,
      intent: StorageExclusionIntent.mutate,
      declaration: const LongReadDeclaration.none(reason: 'this case is about what a non-claim does not register'),
      beforeMaintenance: const BeforeRootMaintenance.none(reason: 'this case is about the declaration, not the set'),
      action: (_) async {
        whileRunning = container.read(longReadRegistryProvider);
      },
    );

    expect(whileRunning, isEmpty, reason: 'a declaration of none registered something');
    expect(container.read(longReadRegistryProvider), isEmpty);
  });
}
