// The archive is the second long reader to register, and the first destructive
// one: while a batch is moving records out of the active store, neither delete
// surface may offer to remove what it is moving.
//
//   .fvm/flutter_sdk/bin/flutter test test/archive_long_read_claim_test.dart
//
// WHY THIS OPERATION AND NOT ANOTHER. Of the jobs that hold a record directory
// open for a while, the archive is the only one that also *writes*, so wiring it
// exercises both halves of the registry at once — announcing a claim and a
// subscriber refusing over it. `archive_executor_shared.dart` opens each record's
// files inside a worker (desktop) or a directory transaction (web) and closes
// them when the batch ends, which is the same shape whose handle-release window
// the zip's gate was built for.
//
// WHERE THE CLAIM IS TAKEN, AND WHY IT IS ONE PLACE. `CharaArchiveController` is
// above the platform-selected `archiveRecords`, so the claim covers both legs by
// construction rather than being written twice. That matters because the legs are
// *not* alike underneath: desktop takes one `runForRecords` around the whole
// batch, web loops `runForRecord` per record. A claim inside the legs would have
// inherited that split and released the web batch a record at a time.
//
// WHAT THIS SUITE CANNOT REACH.
//  * The web leg's execution. `archive_executor.dart` selects it with a
//    conditional import, so a VM suite always links the desktop one. What is
//    asserted here is that the claim is on *before* the selected symbol is called
//    at all — the pinned-batch cases below never let the executor run — which is
//    the property that makes the leg irrelevant to it.
//  * The handle-release window itself. That needs a real archive on Windows with
//    a delete timed into it; the gate exists so that timing is unreachable.
//  * Anything about the record lock. The registry grants nothing and refuses
//    nothing; these cases are about what the two screens offer.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/chara_detail/delete_record_dialog.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/localization.dart';
import 'support/records.dart';
import 'support/riverpod.dart';

late Directory _tempRoot;
late PathInfo _layout;

DirectoryPath get _activeDir => _layout.charaDetailActiveDir;

DirectoryPath get _archiveDir => _layout.charaDetailArchiveDir;

/// Where the web leg's directory transactions keep their manifests, and a
/// `resolve` root of the `retired` group (「アプリの残骸」) — which offers a delete over it.
DirectoryPath get _journalDir => _layout.charaDetailArchiveTransactionDir;

/// Record storage that holds ids in memory, so the dialogs have something to be
/// opened over without a disk scan a `testWidgets` clock cannot drive.
mixin _FakeRecordStore on CharaDetailRecordMutator {
  final deleteAllCalls = <Set<String>>[];

  final Set<String> _held = {'a', 'b'};

  @override
  CharaDetailRecord? getBy({required String id}) => _held.contains(id) ? makeRecord(id: id, card: 1) : null;

  @override
  Future<RecordDeleteResult> deleteAsync(String id) => deleteAllAsync([id]);

  @override
  Future<RecordDeleteResult> deleteAllAsync(Iterable<String> ids) async {
    final idSet = ids.toSet();
    deleteAllCalls.add(idSet);
    _held.removeAll(idSet);
    return RecordDeleteResult(succeeded: Set.unmodifiable(idSet), failed: const {});
  }
}

class _FakeRecordStorage extends CharaDetailRecordStorage with _FakeRecordStore {
  @override
  Future<List<CharaDetailRecord>> build() async => const [];
}

/// The active store, plus a note of what the world looked like at the one moment
/// `CharaArchiveController` brings the two stores back in step.
///
/// That call is the far end of the claim's window and there is no other seam on
/// it: it happens after `archiveRecords` has returned — so after the record lock
/// the executor took — and before `hold`'s `finally`.
class _ObservingRecordStorage extends _FakeRecordStorage {
  List<LongReadClaim>? claimsWhenStoresUpdated;
  bool? lockHeldWhenStoresUpdated;
  bool Function()? readLockHeld;

  @override
  void removeRecords(Iterable<String> ids) {
    claimsWhenStoresUpdated = ref.read(longReadRegistryProvider).values.toList();
    lockHeldWhenStoresUpdated = readLockHeld?.call();
    // `super` is deliberately not called: this fake never loaded a record list,
    // and the real republish rebuilds over one.
  }
}

class _FakeArchiveStorage extends CharaDetailArchiveStorage with _FakeRecordStore {
  @override
  Future<List<CharaDetailRecord>> build() async => const [];
}

/// Creates `active/<id>/record.json` and answers the record's directory.
DirectoryPath _seedRecord(String id) {
  final directory = _activeDir / id;
  final file = File((directory.filePath('record.json')).path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('{}');
  return directory;
}

/// The app with nothing else going on, and both record stores faked.
///
/// The capture and import blockers are pinned for the reason
/// `storage_extraction_delete_gate_test.dart` states: the active record group is
/// one a capture writes into, so an unpinned activity blocker would disable the
/// very buttons these cases are about.
ProviderContainer _container({_FakeRecordStorage? storage}) {
  final container = ProviderContainer(
    overrides: [
      pathInfoProvider.overrideWithValue(_layout),
      pathInfoLoader.overrideWith((ref) async => _layout),
      pathLayoutLoader.overrideWith((ref) async => _layout),
      capturingStateProvider.overrideWithValue(false),
      videoImportListenableProvider.overrideWithValue(ValueNotifier(VideoImportState.idle)),
      charaDetailRecordStorageLoaderProvider.overrideWith(() => storage ?? _FakeRecordStorage()),
      charaDetailArchiveStorageLoaderProvider.overrideWith(_FakeArchiveStorage.new),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

typedef _PinnedArchive = ({Future<void> reached, Future<void> archiving, Completer<void> release});

/// Starts the real bulk archive over [ids] and pins it inside the record lock.
///
/// Pinned *before* the executor runs, which is what lets these cases assert the
/// claim without the desktop leg's `compute` isolate touching the disk — and what
/// says the claim does not depend on which leg was linked. [abandon] decides how
/// the batch ends once released.
_PinnedArchive _startPinnedArchive(ProviderContainer container, List<String> ids, {bool abandon = true}) {
  final reachedLock = Completer<void>();
  final release = Completer<void>();
  final controller = container.read(charaArchiveControllerProvider.notifier);
  controller.debugRecoveryGate = RecordRecoveryGate(
    mutationLock: RecordMutationLock((name, mode, action) async {
      if (mode != RecordMutationLockMode.exclusive) {
        return action();
      }
      if (!reachedLock.isCompleted) reachedLock.complete();
      await release.future;
      if (abandon) {
        throw StateError('the archive was abandoned');
      }
      return action();
    }),
  );
  return (reached: reachedLock.future, archiving: controller.archive(ids, ArchiveImageOption.none), release: release);
}

Finder get _confirm => find.widgetWithIcon(FilledButton, Symbols.delete_rounded);

bool _confirmLive(WidgetTester tester) {
  final button = tester.widget<FilledButton>(_confirm);
  return button.onLongPress != null && button.onPressed != null;
}

bool _buttonEnabled(WidgetTester tester, Key key) => tester.widget<IconButton>(find.byKey(key)).onPressed != null;

/// Lets the real event loop run, which a `testWidgets` body's fake clock does not.
Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 20; round++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

Future<void> _pumpTree(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.activeRecords, path: null));
  await pumpWithContainer(tester, container, const MaterialApp(home: Scaffold(body: StorageTreeView())));
  await _settle(tester);
}

class _ShowSingle extends ConsumerWidget {
  final String recordId;

  const _ShowSingle(this.recordId);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      onPressed: () => DeleteRecordDialog.show(ref.base, recordId: recordId, source: RecordSource.active),
      child: const Text('open'),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    initializeMappers();
    loadAppTranslations();
  });

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_archive_long_read');
    _layout = PathInfo(
      documentDir: DirectoryPath('${_tempRoot.path}/documents'),
      supportDir: DirectoryPath('${_tempRoot.path}/support'),
      executableDir: DirectoryPath('${_tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${_tempRoot.path}/downloads'),
    );
  });

  tearDown(() {
    if (_tempRoot.existsSync()) _tempRoot.deleteSync(recursive: true);
  });

  group('the claim', () {
    test('a batch is one token holding both ends of every record it moves', () async {
      final container = _container();
      final archive = _startPinnedArchive(container, ['a', 'b']);
      await archive.reached;

      final claims = container.read(longReadRegistryProvider);
      expect(claims, hasLength(1), reason: 'a batch is one registration, not one per record');
      final claim = claims.values.single;
      expect(claim.kind, LongReadKind.archive);
      expect(
        claim.holds.map((hold) => hold.directoryPath),
        [
          (_activeDir / 'a').path,
          (_archiveDir / 'a').path,
          (_activeDir / 'b').path,
          (_archiveDir / 'b').path,
          _journalDir.path,
        ],
        reason: 'the destination is being written for as long as the source is being emptied, and so is the journal',
      );

      // Both delete surfaces answer over it, at both ends of the move.
      expect(
        storageDeleteBlockedBy(StorageDeletePathsRequest([_activeDir / 'a']), claims.values),
        LongReadKind.archive,
      );
      expect(
        storageDeleteBlockedBy(StorageDeletePathsRequest([_archiveDir / 'b']), claims.values),
        LongReadKind.archive,
      );
      expect(
        recordDeleteBlockedBy(
          pathInfo: _layout,
          source: RecordSource.active,
          recordIds: const ['b'],
          claims: claims.values,
        ),
        LongReadKind.archive,
      );

      archive.release.complete();
      await archive.archiving;
      expect(container.read(longReadRegistryProvider), isEmpty);
    });

    test('a record the batch did not name keeps its delete', () async {
      final container = _container();
      final archive = _startPinnedArchive(container, ['a']);
      await archive.reached;
      final claims = container.read(longReadRegistryProvider).values;

      // The control for every refusal above: a gate that refused everything would
      // satisfy them and ship a delete that never works.
      expect(storageDeleteBlockedBy(StorageDeletePathsRequest([_activeDir / 'b']), claims), isNull);
      expect(
        storageDeleteBlockedBy(StorageDeletePathsRequest([_activeDir / 'ab']), claims),
        isNull,
        reason: 'a prefix is not containment: `ab` is a different record with a different lock',
      );
      expect(
        recordDeleteBlockedBy(pathInfo: _layout, source: RecordSource.active, recordIds: const ['b'], claims: claims),
        isNull,
      );
      expect(
        recordDeleteBlockedBy(pathInfo: _layout, source: RecordSource.archive, recordIds: const ['b'], claims: claims),
        isNull,
        reason: 'the other end of a record the batch is not moving is free too',
      );

      archive.release.complete();
      await archive.archiving;
    });

    test('the claim goes on and off whole, never a hold at a time', () async {
      final container = _container();
      final transcript = <(int, int)>[];
      final subscription = container.listen(longReadRegistryProvider, (_, next) {
        transcript.add((next.length, next.values.fold(0, (sum, claim) => sum + claim.holds.length)));
      }, fireImmediately: true);
      addTearDown(subscription.close);

      final archive = _startPinnedArchive(container, ['a', 'b']);
      await archive.reached;
      archive.release.complete();
      await archive.archiving;

      // Idle, the whole batch, idle. A per-record claim — which is what putting
      // this in the executor legs would have produced on web — would show a state
      // with fewer holds than the batch, and the records released early would come
      // back live while the rest of the batch still had handles open.
      expect(transcript, [(0, 0), (1, 5), (0, 0)]);
    });

    test('a batch that ends by throwing still releases', () async {
      final container = _container();
      final archive = _startPinnedArchive(container, ['a']);
      await archive.reached;
      expect(container.read(longReadRegistryProvider), hasLength(1));

      archive.release.complete();
      await archive.archiving;

      // `CharaArchiveController` swallows the failure into a toast, so the future
      // completes normally and nothing here would notice a claim left on: the
      // release belongs to the registry's own `finally`, not to a call site.
      expect(
        container.read(longReadRegistryProvider),
        isEmpty,
        reason: 'a claim nobody releases greys the delete for the rest of the session',
      );
    });

    test('the transaction journal is held too, and only the journal the archive writes', () async {
      final container = _container();
      final archive = _startPinnedArchive(container, ['a']);
      await archive.reached;
      final claims = container.read(longReadRegistryProvider).values;

      // The web leg stages every record through a `RecordDirectoryTransaction`
      // whose manifest is written here for the length of the batch, and this
      // directory is a `resolve` root of a group that offers a delete. Unheld, it
      // is the one folder the archive is actively writing whose delete button
      // stays live.
      expect(
        storageDeleteBlockedBy(StorageDeletePathsRequest([_journalDir]), claims),
        LongReadKind.archive,
        reason: 'the archive writes this folder for its whole length, and `retired` offers a delete over it',
      );

      // The control that stops "claim the whole of `chara_detail`" from passing:
      // the *write* journal is the sibling root of the same shape, written by the
      // capture merge and never by an archive, and its delete has to stay live.
      expect(
        storageDeleteBlockedBy(StorageDeletePathsRequest([_layout.charaDetailWriteTransactionDir]), claims),
        isNull,
        reason: 'an archive drives no write transaction; withholding that delete would refuse for nothing',
      );

      archive.release.complete();
      await archive.archiving;
      expect(storageDeleteBlockedBy(StorageDeletePathsRequest([_journalDir]), const []), isNull);
    });

    test('the claim outlives the lock: the delete is still withheld after the executor has let go', () async {
      // WHY THIS CASE EXISTS. Every other case above pins the batch *inside* the
      // record lock, so all of them stay green if the claim is narrowed to the
      // lock's own window — which is exactly the defect this whole seam was built
      // for: on the real filesystem the handles outlive the acquisition, and a
      // delete let through the instant the lock opened is the failure that was
      // reproduced twice by hand. So this case observes the claim at a moment the
      // lock is provably no longer held.
      //
      // The moment chosen is the one `CharaArchiveController` documents as the
      // far end of its window: bringing the two record stores back in step. It is
      // strictly after `archiveRecords` has returned (so after the lock it took),
      // strictly before `hold` returns, and it is reachable from a fake store, so
      // no timer or extra seam is needed to name it.
      //
      // Unlike its neighbours this one lets the executor really run — the record
      // directory is moved on disk — because a pinned batch never reaches the
      // bookkeeping this case is about.
      final storage = _ObservingRecordStorage();
      final container = _container(storage: storage);
      _seedRecord('a');
      Directory(_archiveDir.path).createSync(recursive: true);

      var lockHeld = false;
      var lockWasTaken = false;
      final controller = container.read(charaArchiveControllerProvider.notifier);
      controller.debugRecoveryGate = RecordRecoveryGate(
        mutationLock: RecordMutationLock((name, mode, action) async {
          lockWasTaken = true;
          lockHeld = true;
          try {
            return await action();
          } finally {
            lockHeld = false;
          }
        }),
      );
      storage.readLockHeld = () => lockHeld;

      await controller.archive(['a'], ArchiveImageOption.none);

      expect(lockWasTaken, isTrue, reason: 'the control: an executor that took no lock proves nothing about order');
      expect(
        storage.claimsWhenStoresUpdated,
        isNotNull,
        reason: 'the batch never reached the bookkeeping, so this case measured nothing',
      );
      expect(
        storage.lockHeldWhenStoresUpdated,
        isFalse,
        reason: 'the observation point has to be outside the lock for the assertion below to say anything',
      );
      expect(
        storageDeleteBlockedBy(StorageDeletePathsRequest([_activeDir / 'a']), storage.claimsWhenStoresUpdated!),
        LongReadKind.archive,
        reason: 'the lock had opened and the folder had already moved; a delete offered here is the shipped defect',
      );
      expect(
        recordDeleteBlockedBy(
          pathInfo: _layout,
          source: RecordSource.archive,
          recordIds: const ['a'],
          claims: storage.claimsWhenStoresUpdated!,
        ),
        LongReadKind.archive,
        reason: 'the destination end is the one the record has already arrived at while the stores still disagree',
      );

      // The other end of the window, so "withheld" is not read as "withheld
      // forever": the claim is off once `archive` returns.
      expect(container.read(longReadRegistryProvider), isEmpty);
      expect(Directory((_archiveDir / 'a').path).existsSync(), isTrue, reason: 'the executor really ran');
    });
  });

  group('the surfaces', () {
    testWidgets('殿堂入り管理: the confirm goes dead while the archive holds the record, and comes back', (tester) async {
      final storage = _FakeRecordStorage();
      final container = _container(storage: storage);
      await pumpWithContainer(
        tester,
        container,
        const MaterialApp(
          home: DialogLayer(child: Scaffold(body: _ShowSingle('a'))),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(_confirmLive(tester), isTrue, reason: 'the control that separates the gate from a broken dialog');

      final archive = _startPinnedArchive(container, ['a']);
      await archive.reached;
      await tester.pump();
      expect(_confirmLive(tester), isFalse);

      // The refusal says so on screen, and the assertion a finder cannot fake:
      // press it and read what the store was asked to do.
      expect(find.text(longReadBusyMessage()), findsOneWidget);
      await tester.longPress(_confirm);
      await tester.pump();
      expect(storage.deleteAllCalls, isEmpty, reason: 'a delete started over a running archive');

      archive.release.complete();
      await archive.archiving;
      await tester.pump();
      expect(_confirmLive(tester), isTrue, reason: 'withheld for the length of the archive, not of the session');
    });

    testWidgets('ストレージ管理: the row delete goes dead while the archive holds the folder', (tester) async {
      final recordA = _seedRecord('a');
      final recordB = _seedRecord('b');
      final container = _container();
      await _pumpTree(tester, container);

      expect(_buttonEnabled(tester, storageDeleteEntityKey(recordA)), isTrue);
      expect(_buttonEnabled(tester, storageDeleteEntityKey(recordB)), isTrue);

      final archive = _startPinnedArchive(container, ['a']);
      await archive.reached;
      await tester.pump();

      expect(_buttonEnabled(tester, storageDeleteEntityKey(recordA)), isFalse);
      expect(
        _buttonEnabled(tester, storageDeleteEntityKey(recordB)),
        isTrue,
        reason: 'a record the batch is not moving takes a different lock; refusing it would refuse nothing',
      );

      archive.release.complete();
      await archive.archiving;
      await tester.pump();
      expect(_buttonEnabled(tester, storageDeleteEntityKey(recordA)), isTrue);
    });
  });
}
