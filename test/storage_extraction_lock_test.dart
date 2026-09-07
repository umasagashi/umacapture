// What a storage-view *extraction* excludes while it reads.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_extraction_lock_test.dart
//
// WHY THIS EXISTS. A lock unit is stated per group for deleting, and reading is
// held to the same rule: 「読み取り（zip 化）も同じロックが要る」 — bundling a
// folder needs the lock a delete of it would need. Stage 5 shipped the zip and the
// download taking nothing at all: bundling a record folder while the capture
// merge writes into it produces an archive assembled from a half-written record,
// and a broken zip looks exactly like a good one until it is opened. So this
// suite asserts the acquisitions an extraction makes -- names, not calls, because
// a record-shaped name minted from a directory that is not a record id reads as
// exclusion and excludes nobody (the "false comfort" the lock table warns of).
//
// WHAT EACH CLAIM IS.
//  1. A zip of a record folder acquires *that record's* lock, and a zip of
//     quarantine acquires the *root* -- never a name built from `<name>_n`.
//  2. The exclusion covers the read and not the save dialog. On Windows the
//     dialog is a modal that sits open until the user answers; a lock held across
//     it would stall the capture merge for however long they take, over work that
//     is not touching the store.
//  3. An acquisition that times out is *reported*, not swallowed. Nothing
//     is written and the user is told so.
//  4. A metadata extraction takes nothing and does not drop the owning
//     controller: that exclusion is itself a write, and a read must not perform
//     one to protect itself. This is the control for claim 1 -- without it, a fix
//     that serialised everything would look identical.
//
// WHAT THIS SUITE DOES NOT REACH. The browser: `zip_export_web.dart` is
// unbuildable on the VM, so the placement of its guard (around the OPFS walk and
// the byte reads, not around the encode) is asserted nowhere here. It does not
// run real Web Locks, only `InProcessNamedLocks` behind the same facade. And it
// says nothing about whether an archive built *under* the lock is actually
// consistent -- that would need a concurrent writer, which no test in this repo
// has.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/file_download.dart';
import 'package:umacapture/src/core/storage/storage_delete.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/storage/zip_export.dart';
import 'package:umacapture/src/core/utils.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';

/// The lock name `RecordMutationLock` builds for a record id, spelled out so the
/// assertion is on the name a writer would contend for rather than on the call
/// that produced it.
String _recordLockName(String id) => 'umacapture:v1:record:${base64Url.encode(utf8.encode(id)).replaceAll('=', '')}';

const _rootLockName = 'umacapture:v1:root';

/// An [ExclusiveLockRunner] that records every acquisition and every release,
/// then delegates to a real [InProcessNamedLocks].
///
/// The releases are what claim 2 is asserted against: "the dialog is outside the
/// lock" is a statement about *when*, and only the pairing of the two lists can
/// say it.
class _RecordingLocks {
  _RecordingLocks({this.refuse});

  final bool Function(String name)? refuse;

  final inner = InProcessNamedLocks();
  final acquired = <String>[];
  final released = <String>[];

  bool holds(String name) => acquired.contains(name) && !released.contains(name);

  Future<Object?> run(String name, RecordMutationLockMode mode, Future<Object?> Function() action) async {
    acquired.add(name);
    if (refuse?.call(name) ?? false) {
      throw RecordMutationLockBusy(name, const Duration(seconds: 150));
    }
    try {
      return await inner.run(name, mode, action);
    } finally {
      released.add(name);
    }
  }
}

void main() {
  late Directory tempRoot;
  late PathInfo layout;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    loadAppTranslations();
  });

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_storage_extract_lock');
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

  void write(FilePath file, String contents) {
    final entity = File(file.path);
    entity.parent.createSync(recursive: true);
    entity.writeAsStringSync(contents);
  }

  ProviderContainer containerWith(
    _RecordingLocks locks, {
    required StorageSaveFile save,
    StorageDeleteSerializer? serializer,
  }) {
    final gate = RecordRecoveryGate(mutationLock: RecordMutationLock(locks.run));
    final container = ProviderContainer(
      overrides: [
        pathInfoProvider.overrideWithValue(layout),
        // The exclusion resolves its plan from the layout rather than from
        // `pathInfoProvider`, so it keeps working while the record store is
        // unavailable.
        pathLayoutLoader.overrideWith((ref) async => layout),
        storageLockGateProvider.overrideWithValue(gate),
        storageSaveFileProvider.overrideWithValue(save),
        if (serializer != null) storageDeleteSerializerProvider.overrideWithValue(serializer),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  RefBase refOf(ProviderContainer container) => container.read(refBaseProvider);

  test('a zip of a record folder takes that record lock, and takes it after the dialog', () async {
    final locks = _RecordingLocks();
    final destination = '${tempRoot.path}/out.zip';
    final acquiredWhenAsked = <String>[];
    final container = containerWith(
      locks,
      save: ({required dialogTitle, required fileName, required bytes}) async {
        acquiredWhenAsked.addAll(locks.acquired);
        return destination;
      },
    );
    final record = layout.charaDetailActiveDir / 'rec-1';
    write(record.filePath('record.json'), '{}');

    final outcome = await exportDirectoryAsZip(
      refOf(container),
      record,
      group: storageGroupOf(StorageGroupId.activeRecords),
      silent: true,
    );

    expect(outcome, StorageZipOutcome.written);
    expect(locks.acquired, contains(_recordLockName('rec-1')));
    expect(acquiredWhenAsked, isEmpty, reason: 'the record lock was held across the save dialog');
    expect(File(destination).existsSync(), isTrue);
  });

  test('a zip of quarantine takes the root, never a name built from the folder', () async {
    final locks = _RecordingLocks();
    final container = containerWith(
      locks,
      save: ({required dialogTitle, required fileName, required bytes}) async => '${tempRoot.path}/out.zip',
    );
    final quarantined = layout.charaDetailQuarantineDir / 'rec-1_1';
    write(quarantined.filePath('record.json'), '{}');

    final outcome = await exportDirectoryAsZip(
      refOf(container),
      quarantined,
      group: storageGroupOf(StorageGroupId.quarantine),
      silent: true,
    );

    expect(outcome, StorageZipOutcome.written);
    expect(locks.acquired, contains(_rootLockName));
    expect(locks.acquired, isNot(contains(_recordLockName('rec-1_1'))));
  });

  test('a download takes the record lock and has released it before the dialog', () async {
    final locks = _RecordingLocks();
    var heldAtDialog = true;
    final container = containerWith(
      locks,
      save: ({required dialogTitle, required fileName, required bytes}) async {
        heldAtDialog = locks.holds(_recordLockName('rec-1'));
        return '${tempRoot.path}/saved.json';
      },
    );
    final file = (layout.charaDetailActiveDir / 'rec-1').filePath('record.json');
    write(file, '{"id":"rec-1"}');

    final outcome = await downloadStorageFile(
      refOf(container),
      file,
      group: storageGroupOf(StorageGroupId.activeRecords),
      silent: true,
    );

    expect(outcome, StorageDownloadOutcome.saved);
    expect(locks.acquired, contains(_recordLockName('rec-1')));
    expect(heldAtDialog, isFalse, reason: 'the record lock was held across the save dialog');
  });

  test('a zip whose lock never comes free says so and writes nothing', () async {
    final locks = _RecordingLocks(refuse: (name) => name == _recordLockName('rec-1'));
    final destination = '${tempRoot.path}/out.zip';
    final container = containerWith(
      locks,
      save: ({required dialogTitle, required fileName, required bytes}) async => destination,
    );
    final record = layout.charaDetailActiveDir / 'rec-1';
    write(record.filePath('record.json'), '{}');

    final outcome = await exportDirectoryAsZip(
      refOf(container),
      record,
      group: storageGroupOf(StorageGroupId.activeRecords),
      silent: true,
    );

    expect(outcome, StorageZipOutcome.lockBusy);
    expect(File(destination).existsSync(), isFalse);
    // And the view is usable again: the single-flight slot is released whatever
    // the outcome was.
    expect(container.read(storageZipProgressProvider), isNull);
  });

  test('a download whose lock never comes free says so and hands the dialog nothing', () async {
    final locks = _RecordingLocks(refuse: (name) => name == _recordLockName('rec-1'));
    var dialogCalls = 0;
    final container = containerWith(
      locks,
      save: ({required dialogTitle, required fileName, required bytes}) async {
        dialogCalls++;
        return '${tempRoot.path}/saved.json';
      },
    );
    final file = (layout.charaDetailActiveDir / 'rec-1').filePath('record.json');
    write(file, '{"id":"rec-1"}');

    final outcome = await downloadStorageFile(
      refOf(container),
      file,
      group: storageGroupOf(StorageGroupId.activeRecords),
      silent: true,
    );

    expect(outcome, StorageDownloadOutcome.lockBusy);
    expect(dialogCalls, 0, reason: 'a file that was never read was still offered to the user');
  });

  test('a metadata download takes nothing and does not drop the owning controller', () async {
    final locks = _RecordingLocks();
    final serialized = <String>[];
    final container = containerWith(
      locks,
      save: ({required dialogTitle, required fileName, required bytes}) async => '${tempRoot.path}/saved.json',
      serializer: (target, action) async {
        serialized.add(target.path);
        await action();
      },
    );
    final file = layout.charaDetailRatingDir.filePath('rating.json');
    write(file, '{}');

    final outcome = await downloadStorageFile(
      refOf(container),
      file,
      group: storageGroupOf(StorageGroupId.metadata),
      silent: true,
    );

    expect(outcome, StorageDownloadOutcome.saved);
    expect(locks.acquired, isEmpty);
    expect(serialized, isEmpty, reason: "a read invalidated the user's loaded ratings to protect itself");
  });

  test('the bytes handed to the dialog are the file, read under the lock', () async {
    final locks = _RecordingLocks();
    Uint8List? handed;
    final container = containerWith(
      locks,
      save: ({required dialogTitle, required fileName, required bytes}) async {
        handed = bytes;
        return '${tempRoot.path}/saved.json';
      },
    );
    final file = (layout.charaDetailActiveDir / 'rec-1').filePath('record.json');
    write(file, '{"id":"rec-1"}');

    await downloadStorageFile(
      refOf(container),
      file,
      group: storageGroupOf(StorageGroupId.activeRecords),
      silent: true,
    );

    expect(utf8.decode(handed ?? Uint8List(0)), '{"id":"rec-1"}');
  });
}
