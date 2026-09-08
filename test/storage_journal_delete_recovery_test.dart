// Deleting the write-transaction journal from the storage view must not destroy
// a record whose only copy is a slot inside it.
//
// The slot this suite builds is a `ready` transaction caught mid-resume:
// `active/<id>/` has already been carried into `<slot>/superseded/` and the
// replacement sits in `<slot>/desired/`, so the record exists nowhere else under
// the data root. Whole-store recovery publishes it; the delete that runs without
// recovery removes it.
//
// The two cases differ in *one* thing, and it is not the slot: whether
// `JournalRootStorageMaintenance` has already swept this data root during the page
// session. The memo that records that used to suppress the gate's recovery hook
// for every caller, so the case that matters — a write that failed after the
// session's own startup sweep — deleted the record. The control below is the
// same delete with no memo, which was green before the fix and is the reason the
// defect was invisible.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock_shared.dart';
import 'package:umacapture/src/core/fs/record_directory_transaction.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/fs/record_recovery_reason.dart';
import 'package:umacapture/src/core/fs/root_storage_maintenance.dart';
import 'package:umacapture/src/core/fs/root_storage_maintenance_shared.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/storage_delete.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/gui/storage_delete_action.dart';
import 'package:umacapture/src/gui/storage_tree.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';

late Directory _tempRoot;
late PathInfo _layout;

const _recordId = 'only-copy-record';
const _owner = 'umacapture.web-record-persistence';
const _operation = 'publish-active-record';

StorageGroup _groupOf(StorageGroupId id) => storageGroups.firstWhere((group) => group.id == id);

/// The slot directory name `WebRecordWriteTransaction` mints for this record.
String _slotName() => base64Url.encode(utf8.encode('$_operation:$_recordId')).replaceAll('=', '');

/// The slot as the delete names it. Derived with the path type rather than by
/// interpolating separators, so an assertion compares the same spelling the
/// report carries.
DirectoryPath _slotPath() => _layout.charaDetailWriteTransactionDir / 'v1' / _slotName();

Directory _slotDir() => Directory(_slotPath().path);

Directory _activeDir() => Directory('${_layout.charaDetailDir.path}/active/$_recordId');

Directory _quarantineDir() => Directory('${_layout.charaDetailDir.path}/quarantine');

/// A `ready` slot mid-resume, written by hand.
///
/// The state cannot be reached by driving the transaction: it is what is on disk
/// when the process stops *between* two moves. The manifest satisfies
/// `_WriteManifest.fromJson` and `_isRecoverableManifest`, which is what recovery
/// reads.
void _writeReadySlotMidResume() {
  final slot = _slotDir();
  File('${slot.path}/manifest.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      jsonEncode({
        'version': 1,
        'owner': _owner,
        'operation': _operation,
        'transactionId': '11111111-2222-4333-8444-555555555555',
        'recordId': _recordId,
        'dataRootPath': _layout.charaDetailDir.path,
        'finalPath': '${_layout.charaDetailDir.path}/active/$_recordId',
        'state': 'ready',
      }),
    );
  File('${slot.path}/desired/record.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('{"id":"$_recordId","v":"new"}');
  File('${slot.path}/superseded/record.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('{"id":"$_recordId","v":"old"}');
}

/// The same slot with its staged tree gone: `superseded/` — the version the
/// publication was replacing — is then the only copy of the record there is.
///
/// Recovery answers this with `_abandonSlot`, whose first step moves that copy
/// onto the `quarantine/` shelf.
void _writeReadySlotStagingLost() {
  final slot = _slotDir();
  File('${slot.path}/manifest.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      jsonEncode({
        'version': 1,
        'owner': _owner,
        'operation': _operation,
        'transactionId': '11111111-2222-4333-8444-555555555555',
        'recordId': _recordId,
        'dataRootPath': _layout.charaDetailDir.path,
        'finalPath': '${_layout.charaDetailDir.path}/active/$_recordId',
        'state': 'ready',
      }),
    );
  File('${slot.path}/superseded/record.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('{"id":"$_recordId","v":"old"}');
}

/// Makes `quarantine/` permanently unusable as a directory, which is what a
/// quarantine move that will never succeed looks like from inside recovery.
void _blockQuarantine() {
  File(_quarantineDir().path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('not a directory');
}

Directory _retiredDir() => Directory('${_layout.charaDetailDir.path}/retired');

/// A slot directory whose name this version does not derive: recovery carries it
/// into `quarantine/` and only then reports it unfinished.
Directory _foreignSlotDir() =>
    Directory((_layout.charaDetailWriteTransactionDir / 'v1' / 'not-a-name-this-version-mints').path);

/// The same thing in the *archive* journal. `RecordDirectoryTransaction` shares
/// the disposition (`quarantineForeignSlot`) because the argument is about the
/// name, not about which journal the name was found under.
Directory _foreignArchiveSlotDir() =>
    Directory((_layout.charaDetailArchiveTransactionDir / 'v1' / 'not-an-archive-name-of-ours').path);

List<String> _filesUnder(Directory dir) => dir.existsSync()
    ? (dir.listSync(recursive: true).whereType<File>().map((entry) => entry.path).toList()..sort())
    : const [];

/// Every file under the data root whose bytes contain [needle].
List<String> _bytesNamed(String needle) => _filesUnder(
  Directory(_layout.charaDetailDir.path),
).where((path) => File(path).readAsStringSync().contains(needle)).toList();

/// The whole retired group, exactly as the view's group row asks for it.
Future<StorageDeleteReport> _deleteRetiredGroup(ProviderContainer container) => deleteStorageEntries(
  container.read(refBaseProvider),
  group: _groupOf(StorageGroupId.retired),
  targets: _groupOf(StorageGroupId.retired).resolve(_layout),
);

Future<StorageDeleteReport> _deleteQuarantine(ProviderContainer container) => deleteStorageEntry(
  container.read(refBaseProvider),
  group: _groupOf(StorageGroupId.quarantine),
  target: _layout.charaDetailQuarantineDir,
);

/// How many times the archive journal's recovery was driven.
///
/// The archive journal is the write journal's twin in this group: the same
/// roots, the same delete, the same reason. Its slots **that this build minted**
/// really are duplicates — a `payload/` is copied *from* the record and the
/// source is not removed until the destination exists
/// (`record_directory_transaction.dart`), so no state of it is the only copy —
/// which is why this suite's data-loss cases are about the write journal. That
/// argument runs on the slot *name* round-tripping through our own derivation
/// and stops where the name does; the group at the bottom of this file is the
/// case where it does not hold. What is still worth pinning here is that the
/// drain covers both: the grouping is what makes a delete of one a delete of the
/// other.
late int _archiveRecoveries;

/// The real web maintenance, with the archive journal's recovery counted rather
/// than run: its own state machine is exercised by its own suites.
JournalRootStorageMaintenance _maintenance() => JournalRootStorageMaintenance.bothJournals(
  mutationLock: RecordMutationLock(InProcessNamedLocks().run),
  recover: (_) async {
    _archiveRecoveries++;
    return [];
  },
  cleanup: (_) async {},
);

/// The same maintenance with the archive journal's **real** recovery, which is
/// what the app runs. The stub above is right for the write-journal cases, where
/// the archive leg is only asked to have been driven; it is exactly wrong for the
/// cases below, whose whole subject is where that leg puts a slot it cannot name.
JournalRootStorageMaintenance _maintenanceWithRealArchiveRecovery() => JournalRootStorageMaintenance.bothJournals(
  mutationLock: RecordMutationLock(InProcessNamedLocks().run),
  cleanup: (_) async {},
);

/// A gate wired exactly as `record_recovery_gate_web.dart` wires the real one:
/// the root hook forwards the caller's reason into the maintenance request.
ProviderContainer _container(JournalRootStorageMaintenance maintenance) {
  final gate = RecordRecoveryGate(
    mutationLock: RecordMutationLock(InProcessNamedLocks().run),
    ensureRootReady: (storageRoot, reason) => maintenance.runUnlocked(
      RootStorageMaintenanceRequest(recordDataRoot: storageRoot / 'chara_detail', reason: reason),
    ),
  );
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      pathLayoutLoader.overrideWith((ref) async => _layout),
      pathInfoLoader.overrideWith((ref) async => _layout),
      storageLockGateProvider.overrideWithValue(gate),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<StorageDeleteReport> _deleteJournal(ProviderContainer container) {
  return deleteStorageEntry(
    container.read(refBaseProvider),
    group: _groupOf(StorageGroupId.retired),
    target: _layout.charaDetailWriteTransactionDir,
  );
}

/// One entry under the retired group on its own, which is a gesture the tree
/// really offers: the journal's children are ordinary entry rows and each
/// carries its group's delete, so a user who expands `v1/` can point at a single
/// slot directory — or, expanding once more, at something inside one.
Future<StorageDeleteReport> _deleteRetiredTarget(ProviderContainer container, PathEntity target) {
  return deleteStorageEntry(container.read(refBaseProvider), group: _groupOf(StorageGroupId.retired), target: target);
}

Future<StorageDeleteReport> _deleteSlot(ProviderContainer container) => _deleteRetiredTarget(container, _slotPath());

List<String> _filesUnderDataRoot() => Directory(
  _layout.charaDetailDir.path,
).listSync(recursive: true).whereType<File>().map((entry) => entry.path).toList();

void main() {
  setUpAll(loadAppTranslations);

  setUp(() {
    _archiveRecoveries = 0;
    _tempRoot = Directory.systemTemp.createTempSync('uma_journal_delete');
    _layout = PathInfo(
      documentDir: DirectoryPath('${_tempRoot.path}/documents'),
      supportDir: DirectoryPath('${_tempRoot.path}/support'),
      executableDir: DirectoryPath('${_tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${_tempRoot.path}/downloads'),
    );
    Directory(_layout.charaDetailDir.path).createSync(recursive: true);
  });

  tearDown(() {
    if (_tempRoot.existsSync()) {
      _tempRoot.deleteSync(recursive: true);
    }
  });

  test('a slot created after this session swept is recovered before the journal is deleted', () async {
    final maintenance = _maintenance();
    // This tab's own startup sweep, over a clean root: it succeeds, so the data
    // root is memoed as swept.
    await maintenance.runUnlocked(
      RootStorageMaintenanceRequest(recordDataRoot: _layout.charaDetailDir, reason: RootMaintenanceReason.readyToUse),
    );
    // Only afterwards does the slot appear — another tab, or a write in this
    // session that failed after carrying `active/<id>/` aside.
    _writeReadySlotMidResume();

    final report = await _deleteJournal(_container(maintenance));

    expect(report.failed, isEmpty);
    expect(_slotDir().existsSync(), isFalse, reason: 'the journal was still removed');
    final published = File('${_activeDir().path}/record.json');
    expect(published.existsSync(), isTrue, reason: 'survivors: ${_filesUnderDataRoot()}');
    expect(published.readAsStringSync(), contains('"new"'));
    // Both journals are in the group and both are drained: the startup sweep was
    // one, and the delete's own is the second.
    expect(_archiveRecoveries, 2);
  });

  test('control: the same delete with no memo recovers the slot too', () async {
    final maintenance = _maintenance();
    _writeReadySlotMidResume();

    final report = await _deleteJournal(_container(maintenance));

    expect(report.failed, isEmpty);
    expect(_slotDir().existsSync(), isFalse);
    final published = File('${_activeDir().path}/record.json');
    expect(published.existsSync(), isTrue, reason: 'survivors: ${_filesUnderDataRoot()}');
    expect(published.readAsStringSync(), contains('"new"'));
  });

  // The drain is owed to the journals, and asking for it before removing one of
  // its *destinations* would be the same data loss with the shelves swapped:
  // recovery moves a slot it gives up on into `quarantine/`, and the quarantine
  // group takes the identical exclusive root scope.
  test('deleting quarantine does not drain the journals into what it is removing', () async {
    final maintenance = _maintenance();
    await maintenance.runUnlocked(
      RootStorageMaintenanceRequest(recordDataRoot: _layout.charaDetailDir, reason: RootMaintenanceReason.readyToUse),
    );
    _writeReadySlotMidResume();
    _quarantineDir().createSync(recursive: true);

    final report = await deleteStorageEntry(
      _container(maintenance).read(refBaseProvider),
      group: _groupOf(StorageGroupId.quarantine),
      target: _layout.charaDetailQuarantineDir,
    );

    expect(report.failed, isEmpty);
    expect(_slotDir().existsSync(), isTrue, reason: 'the slot must be left where the user can still see it');
    expect(File('${_slotDir().path}/superseded/record.json').existsSync(), isTrue);
  });

  test('the reason a group asks for is decided by whether its roots hold a journal', () {
    expect(_groupOf(StorageGroupId.retired).destroysTransactionJournal(_layout), isTrue);
    expect(_groupOf(StorageGroupId.quarantine).destroysTransactionJournal(_layout), isFalse);
    expect(_groupOf(StorageGroupId.activeRecords).destroysTransactionJournal(_layout), isFalse);
  });

  // The quarantine cases above warm the memo first, so no sweep runs under the
  // delete at all. These do not: a session whose startup sweep never happened —
  // the store was unopenable, the tab was reloaded mid-scan — reaches the delete
  // with the memo cold, and then the delete's own drain runs and puts a record
  // on the very shelf the delete is emptying.
  test('cold: deleting quarantine keeps what this delete own recovery just moved into it', () async {
    final maintenance = _maintenance();
    _writeReadySlotStagingLost();
    _quarantineDir().createSync(recursive: true);

    await _deleteQuarantine(_container(maintenance));

    expect(_slotDir().existsSync(), isFalse, reason: 'the drain did not run at all');
    expect(
      _bytesNamed('"old"'),
      isNotEmpty,
      reason: 'the only copy of the record was carried onto the shelf and then deleted with it',
    );
  });

  test('cold: the quarantine delete says it left something behind', () async {
    final maintenance = _maintenance();
    _writeReadySlotStagingLost();
    _quarantineDir().createSync(recursive: true);

    final report = await _deleteQuarantine(_container(maintenance));

    expect(report.isComplete, isFalse, reason: 'the user was told the shelf is empty while a record sits on it');
    expect(
      report.retained.map((retention) => retention.subject.path),
      contains(_layout.charaDetailQuarantineDir.path),
      reason: 'the directory that still holds the record has to be named',
    );
    expect(report.retentionReasons, {
      StorageDeleteRetentionReason.setAsideByThisDelete,
    }, reason: 'naming it is half of it: nothing else in the report says why it is still there');
  });

  test('cold: a quarantine that did not exist when the gesture started is not taken', () async {
    final maintenance = _maintenance();
    _writeReadySlotStagingLost();
    // Deliberately not created: the drain makes it, and the user never asked for
    // what the drain put in it.

    final report = await _deleteQuarantine(_container(maintenance));

    expect(_bytesNamed('"old"'), isNotEmpty, reason: 'the shelf the drain created was taken with its contents');
    // The bytes surviving is half of it. A delete that keeps something has to
    // say so, and this is the one shape where saying so is not free: the survey
    // found nothing, so the plan carries no tree and the ancestor bookkeeping
    // that names a survivor's parent never runs. Reported as complete, the
    // result panel does not open at all and the user is told the shelf is empty
    // while the only copy of a record sits on it.
    expect(report.isComplete, isFalse, reason: 'the delete kept a directory it was asked to remove');
    expect(
      report.retained.map((retention) => retention.subject.path),
      contains(_layout.charaDetailQuarantineDir.path),
      reason: 'the directory the drain filled has to be named as kept',
    );
    expect(report.retentionReasons, {
      StorageDeleteRetentionReason.setAsideByThisDelete,
    }, reason: 'the shelf the drain created is the one survivor no other list names');
    expect(report.deleted, isEmpty, reason: 'nothing went, so nothing may be counted as gone');
  });

  // The control for the case above, and the reason its assertions are about the
  // *drain* rather than about absence: with no slot to rescue, the same delete
  // of the same absent shelf covers nothing and is complete. So the report
  // above is produced by what the drain wrote, not by the target having been
  // missing.
  test('cold: an absent quarantine no drain filled covers nothing and is complete', () async {
    final maintenance = _maintenance();

    final report = await _deleteQuarantine(_container(maintenance));

    expect(_quarantineDir().existsSync(), isFalse, reason: 'nothing created the shelf');
    expect(report.isComplete, isTrue);
    expect(report.requestedCount, 0, reason: 'a delete of something that was never there covered nothing');
  });

  // The other half of the same rule: a slot the drain could not empty is still
  // in the journal when the journal is deleted, and it may be the only copy of
  // the record there is.
  test('a slot recovery could not empty is not removed with the journal', () async {
    final maintenance = _maintenance();
    _writeReadySlotStagingLost();
    _blockQuarantine();

    final report = await _deleteRetiredGroup(_container(maintenance));

    expect(_bytesNamed('"old"'), isNotEmpty, reason: 'the only copy of the record went with the journal');
    expect(
      report.failed
          .where((failure) => failure.reason == StorageDeleteFailureReason.recoveryIncomplete)
          .map((failure) => failure.subject.path),
      contains(_slotPath().path),
      reason: 'the delete has to say which slot it would not remove',
    );
    expect(report.failed.single.detail, isNotEmpty, reason: 'a refusal the user cannot describe is not a report');
  });

  test('a slot whose republication failed is not removed with the journal', () async {
    final maintenance = _maintenance();
    _writeReadySlotMidResume();
    // A file where `active/<id>/` has to be created, which is the shape a store
    // that cannot take another byte has: the resume cannot publish, and it
    // rejects without ever attempting a quarantine.
    File(_activeDir().path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('in the way');

    final report = await _deleteRetiredGroup(_container(maintenance));

    expect(_bytesNamed('"old"'), isNotEmpty, reason: 'the version being replaced went with the journal');
    expect(report.failed.map((failure) => failure.reason), contains(StorageDeleteFailureReason.recoveryIncomplete));
  });

  test('a slot the archive journal could not drain is not removed with it either', () async {
    final stalledPath = _layout.charaDetailArchiveTransactionDir / 'v1' / 'stalled-archive-slot';
    final stalled = Directory(stalledPath.path);
    File('${stalled.path}/payload/record.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{"id":"archived","v":"only"}');
    final maintenance = JournalRootStorageMaintenance.bothJournals(
      mutationLock: RecordMutationLock(InProcessNamedLocks().run),
      recover: (_) async => [
        RecordTransactionRecovery(
          null,
          RecordTransactionResult.incomplete,
          slot: stalledPath,
          reason: RecordRecoveryIncompleteReason.archiveMoveIncomplete,
        ),
      ],
      cleanup: (_) async {},
    );

    final report = await _deleteRetiredGroup(_container(maintenance));

    expect(
      File('${stalled.path}/payload/record.json').existsSync(),
      isTrue,
      reason: 'the archive journal is in the same group and takes the same gesture',
    );
    expect(report.failed.map((failure) => failure.reason), contains(StorageDeleteFailureReason.recoveryIncomplete));
  });

  // The exists() filter. Recovery reports "unfinished" for a slot it has already
  // carried out of the journal, and refusing over one of those costs the user
  // the journal they asked to remove and names a path they cannot find.
  test('a slot recovery moved to retired/ does not refuse the journal delete', () async {
    final maintenance = _maintenance();
    File('${_foreignSlotDir().path}/whatever.bin')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('bytes of a version this build cannot read');

    // The journal on its own, and not the whole group: the retirement and the
    // delete that has to ignore it then happen in the same call. Asking for the
    // group instead retires the slot during the *first* target (`retired/`), by
    // which time the journal's own drain finds nothing and the question is never
    // put.
    final report = await _deleteJournal(_container(maintenance));

    expect(report.failed, isEmpty, reason: 'the delete refused over a slot that was no longer there');
    expect(
      Directory(_layout.charaDetailWriteTransactionDir.path).existsSync(),
      isFalse,
      reason: 'the journal the user asked to remove is still there',
    );
  });

  // The same rule stated where it lives, because the delete cannot state it: a
  // slot that is no longer there matches no entry, so a sweep that named one
  // anyway would change nothing the report can show. What it would change is the
  // meaning of the value — `UndrainedSlot` says "still on disk", and a caller
  // that trusts that (one which refuses a *root* it holds, say) would refuse over
  // an entry nobody can find.
  test('the sweep does not name a slot it has already carried out of the journal', () async {
    final maintenance = _maintenance();
    File('${_foreignSlotDir().path}/whatever.bin')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('bytes of a version this build cannot read');

    final outcome = await maintenance.runUnlocked(
      RootStorageMaintenanceRequest(
        recordDataRoot: _layout.charaDetailDir,
        reason: RootMaintenanceReason.beforeDestroyingJournals,
      ),
    );

    expect(_foreignSlotDir().existsSync(), isFalse, reason: 'the retirement did not happen, so this proves nothing');
    expect(outcome.undrained, isEmpty, reason: 'a slot that is no longer in the journal was reported as stuck in it');
  });

  test('control: the sweep does name a slot it really could not empty', () async {
    final maintenance = _maintenance();
    _writeReadySlotStagingLost();
    _blockQuarantine();

    final outcome = await maintenance.runUnlocked(
      RootStorageMaintenanceRequest(
        recordDataRoot: _layout.charaDetailDir,
        reason: RootMaintenanceReason.beforeDestroyingJournals,
      ),
    );

    expect(outcome.undrained.map((slot) => slot.path.path), [_slotPath().path]);
    // The value, and not merely that there is one. The survivor row the user reads is built by
    // switching on this, so "it said something" and "it said which" are different guards — and
    // the weaker of the two was what let the reason ship as untranslated English for as long as
    // it did. This slot's `desired/` is gone and `quarantine/` is blocked, so what recovery could
    // not do is save the version the interrupted resume was replacing.
    expect(outcome.undrained.single.reason, RecordRecoveryIncompleteReason.supersededCopyNotSaved);
  });

  // The shelf a foreign slot is carried to, which is the whole of what its
  // eventual delete's friction rests on.
  //
  // This case used to assert that the slot, retired by this very gesture,
  // survived it — true, because the delete's target set is fixed before the
  // drain runs, and the reason it proved nothing about the *next* gesture. A
  // second delete of `retired/` surveys it and removes it at one confirmation,
  // on that group's stated basis that nothing on it is the only copy of
  // anything. That basis cannot be established here: the slot's name is all this
  // build can read of it, and it settles only that another version minted it. A
  // first publication of theirs, interrupted, holds the whole record in
  // `desired/` and nothing else does.
  //
  // So the claim moves with the shelf. The slot goes to `quarantine/`, which
  // this gesture does not own at all, and whose delete tells the user the app
  // cannot put back what it removes.
  test('a foreign slot the drain carries out is put where the app says it cannot undo removing it', () async {
    final maintenance = _maintenance();
    File('${_foreignSlotDir().path}/whatever.bin')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('bytes of a version this build cannot read');

    await _deleteRetiredGroup(_container(maintenance));

    expect(_foreignSlotDir().existsSync(), isFalse, reason: 'the drain carried nothing out, so this proves nothing');
    expect(
      _filesUnder(_retiredDir()),
      isEmpty,
      reason:
          'a slot written by another version was put on the shelf a single confirmation empties, '
          'whose delete is offered on the stated basis that nothing on it is the only copy of anything',
    );
    expect(
      _filesUnder(_quarantineDir()),
      isNotEmpty,
      reason: 'the bytes are on neither shelf, so the drain destroyed them',
    );
    expect(
      _groupOf(StorageGroupId.quarantine).deleteFriction,
      StorageDeleteFriction.doubleConfirm,
      reason: 'the shelf it was carried to removes it without telling the user that cannot be undone',
    );
  });

  // A foreign slot on `quarantine/` is a child that is not a record directory:
  // it carries a manifest and a `desired/` tree and no `record.json` of its own.
  // Every path that enumerates, shows or removes this shelf therefore has to
  // work on paths alone. These are those paths, one test each.
  group('a quarantined slot with no record.json', () {
    setUp(() async {
      File('${_foreignSlotDir().path}/manifest.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{"version":99,"minted-by":"a build this one cannot read"}');
      File('${_foreignSlotDir().path}/desired/some-record-file.bin')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('the staged tree of a publication this build cannot resume');
      // Placed by the drain rather than by hand, so the shape under test is the
      // one the machine actually produces.
      await _maintenance().runUnlocked(
        RootStorageMaintenanceRequest(recordDataRoot: _layout.charaDetailDir, reason: RootMaintenanceReason.readyToUse),
      );
      expect(
        _quarantineDir().listSync().map((entry) => entry.uri.pathSegments.where((s) => s.isNotEmpty).last),
        ['not-a-name-this-version-mints'],
        reason: 'the drain did not put the slot on this shelf, so none of these cases proves anything',
      );
    });

    // The banner over the record table, which counts this directory's children
    // straight into a sentence that calls them records.
    test('the banner count includes it', () async {
      final container = _container(_maintenance());

      expect(await container.read(charaDetailQuarantineCountProvider.future), 1);
    });

    // The storage view's row for the group, and the size cell beside it. Both
    // walk the tree; neither may ask what a child is.
    test('the storage view lists it and sizes it', () async {
      final container = _container(_maintenance());

      final children = await container.read(
        storageTreeChildrenProvider((group: StorageGroupId.quarantine, path: null)).future,
      );
      expect(children.map((listing) => listing.entity.name), ['not-a-name-this-version-mints']);

      final totals = await container.read(storageGroupTotalsProvider(StorageGroupId.quarantine).future);
      expect(totals.knownBytes, greaterThan(0));
      expect(totals.unresolvedEntries, 0, reason: 'the walk could not resolve the slot and said so as an unknown');
    });

    // The delete the group offers, which is the one gesture that removes it —
    // and, unlike `retired/`'s, warns first.
    test('its own group removes it, at the friction that says the app cannot put it back', () async {
      final container = _container(_maintenance());
      expect(_groupOf(StorageGroupId.quarantine).deleteFriction, StorageDeleteFriction.doubleConfirm);

      final report = await _deleteQuarantine(container);

      expect(report.failed, isEmpty);
      expect(report.isComplete, isTrue);
      expect(_filesUnder(_quarantineDir()), isEmpty);
    });
  });

  // The archive journal's twin of the group above. `RecordDirectoryTransaction`
  // used to retire a slot it could not name, on the reading that a `payload/` is
  // always a copy taken from a record that still stands. That is a fact about
  // slots *this* build minted, derived from a protocol only this build follows;
  // a name that does not decode says who wrote the directory and nothing else,
  // so the fact is not available and `retired/`'s one-confirmation delete — sold
  // on "nothing here is the only copy of anything" — is not licensed.
  //
  // Same three routes, because a slot on `quarantine/` is a child with no
  // `record.json` however it arrived, and no route onto this shelf may ask what
  // a child is.
  group('an archive-journal slot no writer of ours minted', () {
    setUp(() async {
      File('${_foreignArchiveSlotDir().path}/manifest.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{"version":99,"minted-by":"a build this one cannot read"}');
      File('${_foreignArchiveSlotDir().path}/payload/some-record-file.bin')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('whatever that version was carrying');
      // Placed by the drain, with the archive journal's real recovery running —
      // not by hand, and not by the stub the write-journal cases use.
      await _maintenanceWithRealArchiveRecovery().runUnlocked(
        RootStorageMaintenanceRequest(recordDataRoot: _layout.charaDetailDir, reason: RootMaintenanceReason.readyToUse),
      );
      // The wrong shelf first, and by a listing that reads an absent directory
      // as empty: this is the sentence the defect makes false, and asserting the
      // right shelf first would report the defect as a directory that is not
      // there rather than as the claim that stopped being true.
      expect(
        _filesUnder(_retiredDir()),
        isEmpty,
        reason:
            'an archive slot written by another version was put on the shelf a single confirmation empties, '
            'whose delete is offered on the stated basis that nothing on it is the only copy of anything',
      );
      expect(
        _filesUnder(_quarantineDir()),
        isNotEmpty,
        reason: 'the drain did not put the slot on this shelf, so none of these cases proves anything',
      );
      expect(_quarantineDir().listSync().map((entry) => entry.uri.pathSegments.where((s) => s.isNotEmpty).last), [
        'not-an-archive-name-of-ours',
      ]);
    });

    test('the banner count includes it', () async {
      final container = _container(_maintenance());

      expect(await container.read(charaDetailQuarantineCountProvider.future), 1);
    });

    test('the storage view lists it and sizes it', () async {
      final container = _container(_maintenance());

      final children = await container.read(
        storageTreeChildrenProvider((group: StorageGroupId.quarantine, path: null)).future,
      );
      expect(children.map((listing) => listing.entity.name), ['not-an-archive-name-of-ours']);

      final totals = await container.read(storageGroupTotalsProvider(StorageGroupId.quarantine).future);
      expect(totals.knownBytes, greaterThan(0));
      expect(totals.unresolvedEntries, 0, reason: 'the walk could not resolve the slot and said so as an unknown');
    });

    test('its own group removes it, at the friction that says the app cannot put it back', () async {
      final container = _container(_maintenance());
      expect(_groupOf(StorageGroupId.quarantine).deleteFriction, StorageDeleteFriction.doubleConfirm);

      final report = await _deleteQuarantine(container);

      expect(report.failed, isEmpty);
      expect(report.isComplete, isTrue);
      expect(_filesUnder(_quarantineDir()), isEmpty);
    });
  });

  // Rescue is not refusal. The delete's own drain runs before the delete, and
  // for a single slot it can carry away the whole of the target: this one is
  // published into `active/<id>/`, so the slot directory the user pointed at is
  // gone before the first `delete()` is attempted. Reported from the attempt,
  // that is a `PathNotFoundException` and therefore
  // `StorageDeleteFailureReason.refused`, whose sentence tells the user the
  // entry is in use or read-only — for a delete that had already happened, by
  // the app, one step earlier in the same call.
  test('a slot the drain published is not reported as refused', () async {
    final maintenance = _maintenance();
    _writeReadySlotMidResume();

    final report = await _deleteSlot(_container(maintenance));

    expect(_activeDir().existsSync(), isTrue, reason: 'the drain published nothing, so this proves nothing');
    expect(_slotDir().existsSync(), isFalse, reason: 'the slot is still there, so this proves nothing');
    expect(
      report.failed.map((failure) => '${failure.subject} | ${failure.reason.name}'),
      isEmpty,
      reason: 'the delete of a slot recovery had already rescued was reported as a failure',
    );
    expect(report.requestedCount, 0, reason: 'nothing was left where the user pointed, so nothing was covered');
    expect(report.isComplete, isTrue, reason: 'a result panel opens for a delete that found its work already done');
    expect(
      storageDeleteOutcomeMessage(report).type,
      ToastType.success,
      reason: 'the user is shown an error for a delete nothing refused',
    );
  });

  // The other side of the same question, and the reason the case above asserts
  // about the *rescue* rather than about absence: a slot the drain could not
  // empty is still exactly where the user pointed, and its own delete must still
  // say it stayed. What the branch above answers is "there is nothing there",
  // not "a slot delete never fails".
  test('control: a slot the drain could not empty still fails its own delete', () async {
    final maintenance = _maintenance();
    _writeReadySlotStagingLost();
    _blockQuarantine();

    final report = await _deleteSlot(_container(maintenance));

    expect(_slotDir().existsSync(), isTrue, reason: 'the slot was drained after all, so this proves nothing');
    expect(report.failed.map((failure) => failure.reason), contains(StorageDeleteFailureReason.recoveryIncomplete));
    expect(_bytesNamed('"old"'), isNotEmpty, reason: 'the only copy of the record went with the slot');
  });

  // The same delete, pointed one level further in. The tree lists a slot's
  // children as ordinary entry rows carrying their group's delete, so this is
  // the control above plus one more expansion — and it is the case where the
  // slot directory is not part of the request at all, so a report that only ever
  // names the slot names nothing. An empty report is what this library returns
  // for a target that was already absent, and this target is neither absent nor
  // attempted.
  test('a delete pointed inside a slot the drain could not empty is refused, not called complete', () async {
    final maintenance = _maintenance();
    _writeReadySlotStagingLost();
    _blockQuarantine();
    final target = _slotPath() / 'superseded';

    final report = await _deleteRetiredTarget(_container(maintenance), target);

    expect(Directory(target.path).existsSync(), isTrue, reason: 'the target went after all, so this proves nothing');
    expect(
      report.failed
          .where((failure) => failure.reason == StorageDeleteFailureReason.recoveryIncomplete)
          .map((failure) => failure.subject.path),
      [target.path],
      reason: 'a target that is still there and was never attempted was reported as 0 entries deleted',
    );
    expect(report.requestedCount, 1, reason: 'the request covered an entry the three lists did not partition');
    expect(report.isComplete, isFalse, reason: 'a delete that removed nothing reported itself complete');
    expect(
      storageDeleteOutcomeMessage(report).type,
      ToastType.error,
      reason: 'the user was shown a success for a delete that never ran',
    );
  });

  // The archive journal's twin of the case above: same group, same gesture, same
  // shared `_deleteOne`, and a slot recovery reports it could not finish.
  test('a delete pointed inside an archive slot the drain could not empty is refused too', () async {
    final stalledPath = _layout.charaDetailArchiveTransactionDir / 'v1' / 'stalled-archive-slot';
    final target = stalledPath / 'payload';
    File('${target.path}/record.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{"id":"archived","v":"only"}');
    final maintenance = JournalRootStorageMaintenance.bothJournals(
      mutationLock: RecordMutationLock(InProcessNamedLocks().run),
      recover: (_) async => [
        RecordTransactionRecovery(
          null,
          RecordTransactionResult.incomplete,
          slot: stalledPath,
          reason: RecordRecoveryIncompleteReason.archiveMoveIncomplete,
        ),
      ],
      cleanup: (_) async {},
    );

    final report = await _deleteRetiredTarget(_container(maintenance), target);

    expect(
      File('${target.path}/record.json').existsSync(),
      isTrue,
      reason: 'the archive slot was emptied after all, so this proves nothing',
    );
    expect(
      report.failed
          .where((failure) => failure.reason == StorageDeleteFailureReason.recoveryIncomplete)
          .map((failure) => failure.subject.path),
      [target.path],
      reason: 'the archive leg reports through the same three lists and has to name this one too',
    );
    expect(report.isComplete, isFalse, reason: 'a delete that removed nothing reported itself complete');
    expect(
      storageDeleteOutcomeMessage(report).type,
      ToastType.error,
      reason: 'the user was shown a success for a delete that never ran',
    );
  });
}
