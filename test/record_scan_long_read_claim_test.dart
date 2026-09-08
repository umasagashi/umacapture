// The bulk record scan is the fourth long reader to register, and the first one
// whose two platform legs hold the store for different lengths.
//
//   .fvm/flutter_sdk/bin/flutter test test/record_scan_long_read_claim_test.dart
//
// WHY THIS OPERATION. It walks a whole record store — every directory under
// `active/` or `archive/` — and decodes each `record.json` in it, on desktop
// across worker isolates whose handles outlive nothing the UI can see. Both legs
// said so in their own comments and announced nothing, so a delete offered over
// the store, over one record in it, or over the `quarantine/` folder the scan
// files a corrupt record into, stayed live for the length of the pass.
//
// WHERE THE CLAIM IS TAKEN, and why it is not at the gate. `record_scan_claim.dart`
// builds one declaration above the conditional import and each leg announces it
// around **the whole of `loadRecordsUnder`**, not by forwarding it into the root
// acquisition. Forwarding is the arrangement that looks right and is not: the web
// leg's root acquisition covers its *listing only* — each decode below takes its
// own per-record acquisition — so a forwarded claim would come off before the
// long half of the web scan had begun, and the two legs would end up with
// different claims out of the same builder. The case named for that below is what
// fails if anybody forwards it.
//
// WHAT THIS SUITE CANNOT REACH.
//  * The real web build. `record_loader_web.dart` is not behind the browser side
//    of a conditional import, so it runs here on the VM against the io backend —
//    the same Dart, not a browser, and not another tab.
//  * The handle-release window on Windows. The claim exists so that timing is
//    unreachable from the UI; observing it needs a real scan with a delete timed
//    into it.
//  * Anything the registry grants or refuses. It grants and refuses nothing; the
//    lock is unchanged and is asserted elsewhere.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/record_loader_io.dart' as io_loader;
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_directory_transaction.dart';
import 'package:umacapture/src/core/fs/record_loader_web.dart' as web_loader;
import 'package:umacapture/src/core/fs/record_recovery_gate_web.dart' as web_gate;
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_scan_claim.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/storage/storage_lock_scope.dart';
import 'package:umacapture/src/gui/chara_detail/delete_record_dialog.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/riverpod.dart';
import 'support/records.dart';
import 'support/web_like_fs_backend.dart';

late Directory _tempRoot;
late PathInfo _layout;

DirectoryPath get _activeDir => _layout.charaDetailActiveDir;

DirectoryPath get _quarantineDir => _layout.charaDetailQuarantineDir;

DirectoryPath get _storeRoot => _layout.charaDetailDir;

/// Every root the storage view offers a delete over, split by whether the scan's
/// claim is supposed to cover it.
///
/// **A total function over the group table, and that is the point.** The defect
/// this suite exists for was a claim that named four of the store's directories
/// and missed the rest, so a case guarding it must not itself be a list — and a
/// non-emptiness check written as a list of the roots somebody remembered is the
/// same defect one level up. Every group the table offers a delete for lands in
/// exactly one of these two, by the same two-way containment
/// `storageDeleteAwaitsExtraction` decides with, so a root nobody thought about
/// is asserted about rather than skipped.
({List<PathEntity> covered, List<PathEntity> untouched}) _deletableRootsByCoverage() {
  final covered = <PathEntity>[];
  final untouched = <PathEntity>[];
  for (final group in storageGroups) {
    if (!group.operations.contains(StorageOperation.delete)) {
      continue;
    }
    for (final root in group.resolve(_layout)) {
      // The fold asks containment both ways round, so a root *above* the store
      // is covered too; classifying with only one direction would expect a live
      // button over a directory that legitimately has none.
      final overlaps = placeStorageTarget([_storeRoot], root) != null || placeStorageTarget([root], _storeRoot) != null;
      (overlaps ? covered : untouched).add(root);
    }
  }
  return (covered: covered, untouched: untouched);
}

/// Asserts the whole group table against the claim that is live right now.
///
/// Collects rather than expecting per root: an `expect` inside the loop stops at
/// the first mismatch, so a claim missing three directories would only ever name
/// one of them. Every wrong answer is reported together with the path that gave
/// it.
void _expectEveryDeletableRootAgreesWithTheScan(ProviderContainer container) {
  final (:covered, :untouched) = _deletableRootsByCoverage();
  // The check first, and derived rather than listed: a classifier that put
  // everything on one side would agree with any claim at all, including a claim
  // that holds nothing.
  expect(covered, isNotEmpty, reason: 'no delete root was classified as inside the record store');
  expect(untouched, isNotEmpty, reason: 'no delete root was classified as outside the record store');

  final wrong = <String>[];
  for (final root in covered) {
    final answer = _storageSurface(container, root);
    if (answer != LongReadKind.scan) wrong.add('${root.path}: expected scan, got $answer');
  }
  for (final root in untouched) {
    final answer = _storageSurface(container, root);
    if (answer != null) wrong.add('${root.path}: expected no holder, got $answer');
  }
  expect(wrong, isEmpty, reason: wrong.join('; '));
}

ProviderContainer _container() {
  final container = ProviderContainer.test();
  addTearDown(container.dispose);
  return container;
}

/// What the storage view's delete button would answer for [target] right now.
LongReadKind? _storageSurface(ProviderContainer container, PathEntity target) {
  return storageDeleteBlockedBy(StorageDeletePathsRequest([target]), container.read(longReadRegistryProvider).values);
}

/// What the record page's delete confirmation would answer for [id] right now.
LongReadKind? _recordSurface(ProviderContainer container, String id) {
  return recordDeleteBlockedBy(
    pathInfo: _layout,
    source: RecordSource.active,
    recordIds: [id],
    claims: container.read(longReadRegistryProvider).values,
  );
}

/// A lock that lets the caller stand in the middle of the acquisition.
///
/// Completes [entered] once the scan is inside it and does not run the guarded
/// work until [resume] is completed, which is the only way to ask the two delete
/// surfaces a question *while* the scan is running.
RecordMutationLock _pausingLock(Completer<void> entered, Future<void> resume) {
  return RecordMutationLock((_, _, action) async {
    if (!entered.isCompleted) {
      entered.complete();
    }
    await resume;
    return action();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_record_scan_claim');
    _layout = PathInfo(
      documentDir: DirectoryPath('${_tempRoot.path}/documents'),
      supportDir: DirectoryPath('${_tempRoot.path}/support'),
      executableDir: DirectoryPath('${_tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${_tempRoot.path}/downloads'),
    );
    Directory(_activeDir.path).createSync(recursive: true);
  });

  tearDown(() {
    if (_tempRoot.existsSync()) {
      _tempRoot.deleteSync(recursive: true);
    }
  });

  group('the desktop leg', () {
    test('withholds a delete of the store, of a record in it and of quarantine, and gives them all back', () async {
      final container = _container();
      final entered = Completer<void>();
      final resume = Completer<void>();

      final scan = io_loader.loadRecordsUnder(
        _activeDir,
        declaration: bulkRecordScanLongReadDeclaration(container.read(refBaseProvider), _activeDir),
        mutationLock: _pausingLock(entered, resume.future),
      );
      await entered.future;

      // Not a list of the paths the claim happens to carry: the whole group
      // table, every root of it, classified by the same containment the fold
      // uses. A claim that names some of the store's directories fails here.
      _expectEveryDeletableRootAgreesWithTheScan(container);
      expect(_storageSurface(container, _activeDir / 'id-001'), LongReadKind.scan);
      expect(_recordSurface(container, 'id-001'), LongReadKind.scan);

      resume.complete();
      await scan;

      for (final root in _deletableRootsByCoverage().covered) {
        expect(_storageSurface(container, root), isNull, reason: root.path);
      }
      expect(_storageSurface(container, _activeDir / 'id-001'), isNull);
      expect(_recordSurface(container, 'id-001'), isNull);
    });

    test('leaves a folder it never walks alone', () async {
      final container = _container();
      final entered = Completer<void>();
      final resume = Completer<void>();

      final scan = io_loader.loadRecordsUnder(
        _activeDir,
        declaration: bulkRecordScanLongReadDeclaration(container.read(refBaseProvider), _activeDir),
        mutationLock: _pausingLock(entered, resume.future),
      );
      await entered.future;

      // The negative half, and it is what says the assertions above are about
      // containment rather than about the registry being non-empty.
      //
      // `archive/` is deliberately *not* in here, although the first version of
      // this case asserted it was free: an interrupted archive move that the web
      // gate's per-record recovery hook finishes during a scan of `active/`
      // creates `archive/<id>` and deletes `active/<id>`, so the scan really can
      // write the other store. These two are outside the record store root
      // altogether, which is the whole of what the claim covers.
      // `sound/` is the discriminating one: it is the only other child of
      // `storage/`, so it is what separates a claim over the record store from a
      // claim over the whole storage root. The other two are further out still.
      expect(_storageSurface(container, _layout.customSoundDir), isNull);
      expect(_storageSurface(container, _layout.settingsDir), isNull);
      expect(_storageSurface(container, _layout.modulesDir), isNull);

      resume.complete();
      await scan;
    });
  });

  group('the web leg', () {
    test('is still holding the store while it decodes, after the root acquisition has been given back', () async {
      final container = _container();
      final decoding = Completer<void>();
      final resume = Completer<void>();

      // WHAT THIS CASE FALSIFIES, in one sentence: *the web scan's claim is
      // handed to `runForRoot` and therefore ends with the listing.* The pause is
      // inside `loadAction`, which runs after that acquisition has been released
      // — a forwarded declaration is off the registry by then and every
      // expectation below reads null.
      final scan = web_loader.loadRecordsUnder(
        _activeDir,
        declaration: bulkRecordScanLongReadDeclaration(container.read(refBaseProvider), _activeDir),
        mutationLock: RecordMutationLock((_, _, action) => action()),
        recoverRecordUnlocked: (_, _) async {},
        snapshotDirectories: (_) async => [_activeDir / 'id-001'],
        loadAction: (directory) async {
          if (!decoding.isCompleted) {
            decoding.complete();
          }
          await resume.future;
          return RecordLoaded(makeRecord(id: directory.name, card: 1));
        },
      );
      await decoding.future;

      // The same total assertion as the desktop case, guard included — it used to
      // be the loop only, so a web run whose classification came back empty
      // passed while checking nothing. It matters more here than there: the
      // recovery hooks that write the journals and finish an archive move are on
      // the *web* gate, and they run per record — inside this very window.
      _expectEveryDeletableRootAgreesWithTheScan(container);
      expect(_storageSurface(container, _activeDir / 'id-001'), LongReadKind.scan);
      expect(_recordSurface(container, 'id-001'), LongReadKind.scan);

      resume.complete();
      await scan;

      expect(_storageSurface(container, _activeDir), isNull);
      expect(_storageSurface(container, _quarantineDir), isNull);
      expect(_storageSurface(container, _layout.charaDetailWriteTransactionDir), isNull);
      expect(_recordSurface(container, 'id-001'), isNull);
    });

    test('really does finish an archive move inside the claim, through the gate the web build ships', () async {
      // WHAT THIS CASE IS FOR. Every other case here hands the loader a gate the
      // test built, which is enough to ask what the claim covers and nothing at
      // all about what the *production* recovery hooks write. This one takes the
      // gate from `record_recovery_gate_web.dart`'s own public factory — the one
      // the web build uses — and lets its per-record hook run for real.
      //
      // It is reachable on the VM and it was wrongly reported as not being: the
      // factory is public, two suites already call it here, and nothing in the
      // chain touches `dart:js_interop`. What genuinely cannot be reached is the
      // *root* hook, because it goes through `platformRootStorageMaintenance`,
      // which is a conditional import and resolves to the native no-op here.
      const id = 'interrupted';
      final original = fsBackend;
      fsBackend = WebLikeFsBackend(original);
      addTearDown(() => fsBackend = original);

      final source = Directory('${_activeDir.path}/$id')..createSync(recursive: true);
      File('${source.path}/record.json').writeAsStringSync('{"id":"$id"}');
      final destination = _layout.charaDetailArchiveDir / id;
      // Interrupted with the destination already published and the source still
      // standing: the record is listed by the scan, so the per-record hook is
      // asked about it.
      final interrupted = RecordDirectoryTransaction(
        onCheckpoint: (checkpoint) async {
          if (checkpoint == RecordTransactionCheckpoint.beforeSourceDelete) {
            throw StateError('leave a publishable move for the scan to finish');
          }
        },
      );
      final seeded = await interrupted.execute(
        RecordDirectoryTransactionSpec(recordId: id, source: DirectoryPath(source.path), destination: destination),
      );
      expect(seeded, isNot(RecordTransactionResult.completed), reason: 'the seed has to leave work for recovery');
      expect(source.existsSync(), isTrue, reason: 'the scan must still list this record');

      final container = _container();
      final decoding = Completer<void>();
      final resume = Completer<void>();

      final scan = web_loader.loadRecordsUnder(
        _activeDir,
        declaration: bulkRecordScanLongReadDeclaration(container.read(refBaseProvider), _activeDir),
        recoveryGate: web_gate.createPlatformRecordRecoveryGate(
          mutationLock: RecordMutationLock((_, _, action) => action()),
        ),
        loadAction: (directory) async {
          if (!decoding.isCompleted) {
            decoding.complete();
          }
          await resume.future;
          return RecordLoaded(makeRecord(id: directory.name, card: 1));
        },
      );
      await decoding.future;

      // The hook has run by now — `runForRecord` awaits it before the action. It
      // wrote into `archive/` and into the journal, from a scan of `active/`,
      // which is the whole reason the claim is the store root and not a list of
      // the directories the scan body itself touches.
      expect(await destination.exists(), isTrue);
      expect(source.existsSync(), isFalse, reason: 'the per-record hook did not finish the interrupted move');
      _expectEveryDeletableRootAgreesWithTheScan(container);
      expect(_storageSurface(container, destination), LongReadKind.scan);

      resume.complete();
      await scan;

      expect(_storageSurface(container, destination), isNull);
    });
  });

  group('the claim both legs are given', () {
    test('is the record store root, one path, and calls itself a mutation', () {
      final container = _container();
      final declaration = bulkRecordScanLongReadDeclaration(container.read(refBaseProvider), _activeDir);

      // Read off the one builder rather than off two call sites: what keeps the
      // legs from claiming differently is that there is a single object, so the
      // property worth asserting is what that object says.
      expect(declaration, isA<LongReadClaimDeclaration>());
      final claim = declaration as LongReadClaimDeclaration;
      expect(claim.kind, LongReadKind.scan);
      // Not `read`, although the operation is called a scan: the pass quarantines
      // what it cannot decode, promotes a slot it gives up on, and can finish an
      // interrupted archive move — all writes.
      // One path, and specifically not a list of the store's directories. A list
      // is what the first version of this carried, and it had already missed
      // three of them.
      expect(claim.paths.map((path) => path.path), [_storeRoot.path]);
    });

    test('is the same root whichever of the two stores is being scanned', () {
      final container = _container();
      final active =
          bulkRecordScanLongReadDeclaration(container.read(refBaseProvider), _activeDir) as LongReadClaimDeclaration;
      final archive =
          bulkRecordScanLongReadDeclaration(container.read(refBaseProvider), _layout.charaDetailArchiveDir)
              as LongReadClaimDeclaration;

      // Not an accident and not laziness: the web gate's per-record recovery hook
      // can move a record between the two stores while either one is being
      // scanned, so a scan of `archive/` reaches `active/` exactly as a scan of
      // `active/` reaches `archive/`.
      expect(active.paths.map((path) => path.path), archive.paths.map((path) => path.path));
      expect(archive.paths.map((path) => path.path), [_storeRoot.path]);
    });
  });
}
