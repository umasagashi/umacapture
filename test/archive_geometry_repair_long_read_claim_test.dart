// The one-time archive geometry repair is the fifth long reader to register.
//
//   .fvm/flutter_sdk/bin/flutter test test/archive_geometry_repair_long_read_claim_test.dart
//
// WHY THIS OPERATION. It walks every `archive/<id>` on the first launch after
// the upgrade, deleting `prediction.json` and rewriting geometry json inside a
// `compute` isolate. 殿堂入り管理 offers a delete over exactly those directories,
// and until this claim existed that delete stayed live for the length of the
// pass: pressing it queued the delete behind the root lock instead of saying so,
// which is the silent wait the registry exists to remove.
//
// WHY THE CLAIM IS OBSERVED AT RUN TIME AND NOT READ OFF THE SOURCE. The scan
// that polices this seam (`long_read_registry_test.dart`) checks that a
// `declaration:` argument is *present* at every gate call. It cannot check that
// the declaration is a claim, that the claim names the right paths, or that it is
// still on while the work runs — so a `LongReadDeclaration.none` and a wrong claim
// are both green to it. Every case below therefore starts the real pass and reads
// the registry while it is inside.
//
// WHAT THIS SUITE CANNOT REACH.
//  * Web. `runArchiveGeometryMigrationIfNeeded` returns immediately under
//    `kIsWeb`, so there is nothing to claim there and nothing here to assert.
//  * The handle-release window itself. Observing it needs a real delete timed
//    into the worker's file writes on Windows; the claim exists so that timing is
//    unreachable from the UI.
//  * Anything the registry grants or refuses. It grants and refuses nothing.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/storage/storage_lock_scope.dart';
import 'package:umacapture/src/gui/chara_detail/delete_record_dialog.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/hive.dart';

late Directory _tempRoot;
late PathInfo _layout;

DirectoryPath get _archiveDir => _layout.charaDetailArchiveDir;

DirectoryPath get _activeDir => _layout.charaDetailActiveDir;

/// Every root the storage view offers a delete over, split by whether the
/// repair's claim is supposed to cover it.
///
/// **A total function over the group table**, for the reason
/// `record_scan_long_read_claim_test.dart` states about its own copy: the defect
/// this kind of claim keeps arriving with is a *list* of directories, and a case
/// that guards it with a second list of the roots somebody remembered is the same
/// defect one level up. Every group that offers a delete lands in exactly one
/// side here, by the same two-way containment the fold decides with, so a root
/// nobody thought about is asserted about rather than skipped.
({List<PathEntity> covered, List<PathEntity> untouched}) _deletableRootsByCoverage() {
  final covered = <PathEntity>[];
  final untouched = <PathEntity>[];
  for (final group in storageGroups) {
    if (!group.operations.contains(StorageOperation.delete)) {
      continue;
    }
    for (final root in group.resolve(_layout)) {
      final overlaps =
          placeStorageTarget([_archiveDir], root) != null || placeStorageTarget([root], _archiveDir) != null;
      (overlaps ? covered : untouched).add(root);
    }
  }
  return (covered: covered, untouched: untouched);
}

void _expectEveryDeletableRootAgreesWithTheRepair(List<LongReadClaim> claims) {
  final (:covered, :untouched) = _deletableRootsByCoverage();
  // The check first, and derived rather than listed: a classifier that put every
  // root on one side would agree with any claim at all, including one that holds
  // nothing.
  expect(covered, isNotEmpty, reason: 'no delete root was classified as inside the archive store');
  expect(untouched, isNotEmpty, reason: 'no delete root was classified as outside the archive store');

  final wrong = <String>[];
  for (final root in covered) {
    final answer = storageDeleteBlockedBy(StorageDeletePathsRequest([root]), claims);
    if (answer != LongReadKind.repair) wrong.add('${root.path}: expected repair, got $answer');
  }
  for (final root in untouched) {
    final answer = storageDeleteBlockedBy(StorageDeletePathsRequest([root]), claims);
    if (answer != null) wrong.add('${root.path}: expected no holder, got $answer');
  }
  expect(wrong, isEmpty, reason: wrong.join('; '));
}

/// One archived record with the file the repair is there to delete.
void _seedArchivedRecord(String id) {
  final dir = _archiveDir / id;
  dir.toDirectory().createSync(recursive: true);
  dir.filePath('prediction.json').writeAsStringSync('{}');
}

bool _repaired(String id) => !(_archiveDir / id).filePath('prediction.json').existsSync();

/// A gate whose lock body reports the registry from inside the critical section.
///
/// [onInside] is called with the live claims after the acquisition and before the
/// pass's own work, which is the moment the claim has to be on: the claim is
/// registered by the declaration *outside* the acquisition, so a claim scoped to
/// anything narrower than the whole operation shows up here as an empty registry.
RecordRecoveryGate _observingGate(ProviderContainer container, void Function(List<LongReadClaim>) onInside) {
  return RecordRecoveryGate(
    mutationLock: RecordMutationLock((name, mode, action) async {
      onInside(container.read(longReadRegistryProvider).values.toList());
      return action();
    }),
  );
}

ProviderContainer _container() {
  final container = ProviderContainer.test();
  addTearDown(container.dispose);
  return container;
}

LongReadDeclaration _declaration(ProviderContainer container) {
  return archiveGeometryRepairLongReadDeclaration(container.read(containerRefProvider), _layout);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Per test, not per file: the pass records completion in this box and skips
  // itself forever after, so a shared box would leave every case after the first
  // measuring a pass that never ran — which is a hang rather than a failure for
  // the case that waits inside the acquisition.
  useHiveForEachTest(['data_migration']);

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_archive_repair_claim');
    final root = DirectoryPath(_tempRoot);
    _layout = PathInfo(documentDir: root, supportDir: root, executableDir: root, downloadDir: root);
  });

  tearDown(() {
    if (_tempRoot.existsSync()) _tempRoot.deleteSync(recursive: true);
  });

  test('the archive store is claimed for the length of the pass, and given back after it', () async {
    final container = _container();
    _seedArchivedRecord('rec-1');

    List<LongReadClaim>? inside;
    await runArchiveGeometryMigrationIfNeeded(
      _layout,
      declaration: _declaration(container),
      recoveryGate: _observingGate(container, (claims) => inside = claims),
    );

    expect(inside, isNotNull, reason: 'the pass never reached the acquisition, so nothing was measured');
    expect(_repaired('rec-1'), isTrue, reason: 'the control: a pass that did no work proves nothing about its claim');

    final claim = inside!.single;
    expect(claim.kind, LongReadKind.repair);
    expect(claim.holds.map((hold) => hold.directoryPath), [
      _archiveDir.path,
    ], reason: 'one root, not the records the isolate happens to visit');

    expect(container.read(longReadRegistryProvider), isEmpty, reason: 'withheld for the length of the pass, not more');
  });

  test('every delete root the storage view offers is on the right side of the claim', () async {
    final container = _container();
    _seedArchivedRecord('rec-1');

    List<LongReadClaim>? inside;
    await runArchiveGeometryMigrationIfNeeded(
      _layout,
      declaration: _declaration(container),
      recoveryGate: _observingGate(container, (claims) => inside = claims),
    );

    expect(inside, isNotNull);
    _expectEveryDeletableRootAgreesWithTheRepair(inside!);

    // The record page asks the same question with record ids, and it has to
    // answer for the archived end and not for the active one: this pass never
    // opens `active/`.
    expect(
      recordDeleteBlockedBy(
        pathInfo: _layout,
        source: RecordSource.archive,
        recordIds: const ['rec-1'],
        claims: inside!,
      ),
      LongReadKind.repair,
    );
    expect(
      recordDeleteBlockedBy(
        pathInfo: _layout,
        source: RecordSource.active,
        recordIds: const ['rec-1'],
        claims: inside!,
      ),
      isNull,
      reason: 'refusing the active end would withhold a delete over a directory the repair never opens',
    );
    expect(Directory((_activeDir).path).existsSync(), isFalse, reason: 'the pass created no active store');
  });

  test('a pass refused the root scope still gives the claim back', () async {
    // The far end of the window on the failure path. `runArchiveGeometryMigrationIfNeeded`
    // swallows a busy lock into a log line and returns normally, so nothing at
    // the call site would notice a claim left on — and a claim nobody releases
    // greys 殿堂入り管理's delete for the rest of the session.
    final container = _container();
    _seedArchivedRecord('rec-1');
    final reached = Completer<void>();
    final release = Completer<void>();

    final busyGate = RecordRecoveryGate(
      mutationLock: RecordMutationLock((name, mode, action) async {
        if (!reached.isCompleted) reached.complete();
        await release.future;
        throw const RecordMutationLockBusy('record-root', Duration(seconds: 1));
      }),
    );

    final pass = runArchiveGeometryMigrationIfNeeded(
      _layout,
      declaration: _declaration(container),
      recoveryGate: busyGate,
    );
    await reached.future;
    expect(
      container.read(longReadRegistryProvider).values.single.kind,
      LongReadKind.repair,
      reason: 'the claim covers the wait for the scope, which is time the user is waiting too',
    );

    release.complete();
    await pass;

    expect(container.read(longReadRegistryProvider), isEmpty);
    expect(_repaired('rec-1'), isFalse, reason: 'the control: this pass was refused, so it did no work');
  });
}
