// Windows writes the write-transaction journal too, so Windows has to drain it.
//
// `web_record_persistence.dart` and `web_record_write_transaction.dart` carry a
// `Web` prefix and no conditional import: the zip import (「記録を取り込む」)
// publishes through them on the desktop UI exactly as it does in a browser. Until
// this suite existed the desktop legs of both recovery seams were empty — the
// gate installed no hooks and the maintenance was two `RootMaintenanceOutcome.none`
// methods — so a publication interrupted on Windows left a slot nobody would ever
// finish, and deleting 「アプリの残骸」 removed it. When the slot is a first
// publication, or one whose `active/<id>/` has already been carried into
// `<slot>/superseded/`, that slot is the only copy of the record there is.
//
// **Every case here goes through production wiring.** No gate and no maintenance
// object is constructed: the container leaves `storageLockGateProvider` alone, so
// it resolves to `platformRecordRecoveryGate`, and the two direct cases at the
// end drive `platformRootStorageMaintenance` itself. A suite that built its own
// `JournalRootStorageMaintenance` would have passed on the broken build, because
// what was broken was which object the desktop leg hands out.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/fs/root_storage_maintenance.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/storage_delete.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';

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

DirectoryPath _slotPath() => _layout.charaDetailWriteTransactionDir / 'v1' / _slotName();

Directory _slotDir() => Directory(_slotPath().path);

/// The archive journal's slot name for a record, as `RecordDirectoryTransaction`
/// derives it. Spelled out rather than imported because the point of the case
/// that uses it is that the name round-trips through the app's *own* derivation.
String _ownArchiveSlotName() => base64Url.encode(utf8.encode('archive:$_recordId')).replaceAll('=', '');

/// A record id that appears nowhere this build wrote, so a search of the data
/// root for its bytes finds only what the foreign slot carries.
const _foreignRecordId = 'a-record-another-version-saved';

/// A slot in the archive journal whose name no derivation of this build yields.
/// The same name the web leg's suite uses, because the argument is about the
/// name and not about which leg found it.
Directory _foreignArchiveSlotDir() =>
    Directory((_layout.charaDetailArchiveTransactionDir / 'v1' / 'not-an-archive-name-of-ours').path);

Directory _activeDir() => Directory('${_layout.charaDetailDir.path}/active/$_recordId');

Directory _quarantineDir() => Directory('${_layout.charaDetailDir.path}/quarantine');

String _manifest() => jsonEncode({
  'version': 1,
  'owner': _owner,
  'operation': _operation,
  'transactionId': '11111111-2222-4333-8444-555555555555',
  'recordId': _recordId,
  'dataRootPath': _layout.charaDetailDir.path,
  'finalPath': '${_layout.charaDetailDir.path}/active/$_recordId',
  'state': 'ready',
});

/// A `ready` slot caught mid-resume, written by hand.
///
/// The state cannot be reached by driving the transaction: it is what is on disk
/// when the process stops *between* two moves. `active/<id>/` has already been
/// carried into `<slot>/superseded/` and the replacement sits in
/// `<slot>/desired/`, so the record exists nowhere else under the data root.
void _writeReadySlotMidResume() {
  final slot = _slotDir();
  File('${slot.path}/manifest.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(_manifest());
  File('${slot.path}/desired/record.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('{"id":"$_recordId","v":"new"}');
  File('${slot.path}/superseded/record.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('{"id":"$_recordId","v":"old"}');
}

/// The same slot with its staged tree gone: `superseded/` is then the only copy
/// of the record there is, and recovery answers with a quarantine move.
void _writeReadySlotStagingLost() {
  final slot = _slotDir();
  File('${slot.path}/manifest.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(_manifest());
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

List<String> _filesUnderDataRoot() => Directory(
  _layout.charaDetailDir.path,
).listSync(recursive: true).whereType<File>().map((entry) => entry.path).toList();

/// Every file under the data root whose bytes contain [needle].
List<String> _bytesNamed(String needle) =>
    _filesUnderDataRoot().where((path) => File(path).readAsStringSync().contains(needle)).toList();

/// A container with the storage layout pointed at the temp root and **nothing
/// else overridden** — in particular not `storageLockGateProvider`, which is the
/// whole point of this suite.
ProviderContainer _container() {
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      pathLayoutLoader.overrideWith((ref) async => _layout),
      pathInfoLoader.overrideWith((ref) async => _layout),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<StorageDeleteReport> _deleteRetiredGroup(ProviderContainer container) => deleteStorageEntries(
  container.read(refBaseProvider),
  group: _groupOf(StorageGroupId.retired),
  targets: _groupOf(StorageGroupId.retired).resolve(_layout),
);

RootStorageMaintenanceRequest _request(RootMaintenanceReason reason) =>
    RootStorageMaintenanceRequest(recordDataRoot: _layout.charaDetailDir, reason: reason);

void main() {
  setUpAll(loadAppTranslations);

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_desktop_journal');
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

  // The defect, stated as the outcome the user gets: the record survives the
  // gesture that removes the journal it was sitting in.
  test('the desktop delete of the retired group recovers the slot before removing the journal', () async {
    _writeReadySlotMidResume();

    final report = await _deleteRetiredGroup(_container());

    expect(report.failed, isEmpty);
    expect(_slotDir().existsSync(), isFalse, reason: 'the journal was still removed');
    final published = File('${_activeDir().path}/record.json');
    expect(published.existsSync(), isTrue, reason: 'survivors: ${_filesUnderDataRoot()}');
    expect(published.readAsStringSync(), contains('"new"'));
  });

  // The same delete after this session has already swept the root clean. The
  // memo is what makes the second reason a different question from the first,
  // and it has to mean that on desktop too: the slot below is created *after*
  // the sweep, by a write of this very session that failed partway.
  test('a desktop slot created after this session swept is still recovered', () async {
    await platformRootStorageMaintenance.runUnlocked(_request(RootMaintenanceReason.readyToUse));
    _writeReadySlotMidResume();

    final report = await _deleteRetiredGroup(_container());

    expect(report.failed, isEmpty);
    final published = File('${_activeDir().path}/record.json');
    expect(published.existsSync(), isTrue, reason: 'survivors: ${_filesUnderDataRoot()}');
    expect(published.readAsStringSync(), contains('"new"'));
  });

  // The other half of the rule, and the reason recovery is not enough on its
  // own: a slot the drain could *not* empty is still the only copy, so the
  // delete has to leave it and say so.
  test('a desktop slot recovery could not empty is not removed with the journal', () async {
    _writeReadySlotStagingLost();
    _blockQuarantine();

    final report = await _deleteRetiredGroup(_container());

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

  // The per-record seam, which no delete reaches: the gate the whole app reads
  // records through has to finish this record's slot before anything reads it.
  test('the production desktop gate finishes one record slot on its own', () async {
    _writeReadySlotMidResume();

    await platformRecordRecoveryGate.ensureReadyUnlocked(_layout.storageDir, _recordId);

    expect(_slotDir().existsSync(), isFalse, reason: 'survivors: ${_filesUnderDataRoot()}');
    expect(File('${_activeDir().path}/record.json').readAsStringSync(), contains('"new"'));
  });

  // The whole-store seam, driven from the production singleton rather than from
  // a construction this suite chose. The archive slot beside it is the control
  // for the one thing desktop really does not do: it writes no archive manifest,
  // because `archiveRecords` resolves to the atomic native rename, so a slot
  // whose name this build *does* derive is left for the leg that stages one.
  test('the production desktop maintenance replays the write journal and not the archive one', () async {
    _writeReadySlotMidResume();
    final archiveSlot = _layout.charaDetailArchiveTransactionDir / 'v1' / _ownArchiveSlotName();
    File('${archiveSlot.path}/payload/record.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{"id":"archived","v":"only"}');

    final outcome = await platformRootStorageMaintenance.runUnlocked(
      _request(RootMaintenanceReason.beforeDestroyingJournals),
    );

    expect(outcome.undrained, isEmpty);
    expect(_slotDir().existsSync(), isFalse, reason: 'survivors: ${_filesUnderDataRoot()}');
    expect(File('${_activeDir().path}/record.json').readAsStringSync(), contains('"new"'));
    expect(File('${archiveSlot.path}/payload/record.json').existsSync(), isTrue);
  });

  // The other half of that journal on this leg, and the half writing none of it
  // does not license leaving alone. The data root is whatever folder the user
  // pointed the app at, so a slot minted by a build this one cannot read is an
  // ordinary thing to find there; its name is the whole of what can be read of
  // it, and a name says who wrote a directory and nothing about what is inside.
  // Web has carried these to `quarantine/` since the archive journal's recovery
  // learned to (`storage_journal_delete_recovery_test.dart`); until this suite
  // said so, desktop left them in the journal for 「アプリの残骸」 to remove at
  // one confirmation.
  group('an archive-journal slot another version minted, on desktop', () {
    setUp(() {
      File('${_foreignArchiveSlotDir().path}/manifest.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{"version":99,"minted-by":"a build this one cannot read"}');
      File('${_foreignArchiveSlotDir().path}/payload/record.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{"id":"$_foreignRecordId","v":"only"}');
    });

    test('the production desktop maintenance carries it out of the journal', () async {
      final outcome = await platformRootStorageMaintenance.runUnlocked(
        _request(RootMaintenanceReason.beforeDestroyingJournals),
      );

      expect(
        _foreignArchiveSlotDir().existsSync(),
        isFalse,
        reason: 'a slot another version minted was left where a single confirmation empties it',
      );
      expect(
        _bytesNamed(_foreignRecordId).map((path) => path.contains('quarantine')),
        everyElement(isTrue),
        reason: 'survivors: ${_filesUnderDataRoot()}',
      );
      expect(outcome.undrained, isEmpty, reason: 'nothing was left behind, so nothing is undrained');
    });

    // The delete that made the defect cost something, as the user meets it.
    test('the desktop delete of the retired group does not take it along', () async {
      expect(_groupOf(StorageGroupId.retired).deleteFriction, StorageDeleteFriction.singleConfirm);

      final report = await _deleteRetiredGroup(_container());

      expect(report.failed, isEmpty);
      expect(_bytesNamed(_foreignRecordId), isNotEmpty, reason: 'the only copy went with the journal');
      expect(
        _bytesNamed(_foreignRecordId).map((path) => path.contains('quarantine')),
        everyElement(isTrue),
        reason: 'survivors: ${_filesUnderDataRoot()}',
      );
    });

    // The same contract the write journal answers with: a slot the sweep could
    // not carry out is still there, so the delete has to leave it and say so.
    test('a carry the sweep could not finish is reported and not removed', () async {
      _blockQuarantine();

      final report = await _deleteRetiredGroup(_container());

      expect(_bytesNamed(_foreignRecordId), isNotEmpty, reason: 'the only copy went with the journal');
      expect(
        report.failed
            .where((failure) => failure.reason == StorageDeleteFailureReason.recoveryIncomplete)
            .map((failure) => failure.subject.path),
        contains(_foreignArchiveSlotDir().path),
        reason: 'the delete has to say which slot it would not remove',
      );
    });
  });
}
