// The storage view's *operations* during a store outage.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_outage_operations_test.dart
//
// The screen exists to repair a store the app could not open, so the outage is
// the condition it is built for and not an edge of it. `storage_tree_test.dart`
// and `settings_store_outage_reach_test.dart` already hold the two halves that
// come before an operation — the tree still enumerates, and the entry point is
// still reachable — and neither of them presses a button. This file presses the
// buttons: a delete, a download and an extraction, one per lock scope that
// resolves differently, all in a container where `pathInfoLoader` has failed.
//
// The failure this is written against is not a wrong answer but an unhandled
// one: `pathInfoProvider` is `pathInfoLoader.value!`, so *reading* it during an
// outage throws a `TypeError`, and `deleteStorageEntry` catches only the two
// lock exceptions. The user got a red screen instead of the repair the view was
// opened for.
//
// The outage fixture is asserted to be an outage (`_container` really does make
// `pathInfoProvider` throw), so a case passing because the fixture stopped
// reproducing the condition is not possible.
//
// WHAT THIS SUITE DOES NOT REACH. The real zip encoder and the real save
// dialog: both are seams here, because what an outage changes is which provider
// the exclusion reads and not what the encoder writes (`storage_zip_export_test.dart`
// drives the production encoder). The web legs, since this runs on the VM. And
// the *layout* failing, which is a different and worse outage — the app then
// does not know where its own directories are, and no operation can be asked
// for a path it cannot resolve.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock_shared.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/fs/record_store_unavailable.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/file_download.dart';
import 'package:umacapture/src/core/storage/storage_delete.dart';
import 'package:umacapture/src/core/storage/storage_delete_invalidation.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/storage/zip_export.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';

late Directory _tempRoot;
late PathInfo _layout;

/// What the save seam was handed, so a download case can tell "the bytes were
/// read" from "the call was never made".
late List<String> _savedNames;

StorageGroup _groupOf(StorageGroupId id) => storageGroups.firstWhere((e) => e.id == id);

FilePath _seedFile(String relative, String contents) {
  final file = File('${_tempRoot.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
  return FilePath(file.path);
}

/// A container in which the layout resolved and the store preparation on top of
/// it did not — the split the outage requirement is about (path resolution
/// survives, the startup maintenance on top of it does not), and the same one
/// `settings_store_outage_reach_test.dart` builds for the entry point.
///
/// `pathInfoProvider` is deliberately **not** overridden: it is the provider
/// under examination, and pinning it to a value would remove the very condition
/// this file exists to exercise.
ProviderContainer _container() {
  final gate = RecordRecoveryGate(mutationLock: RecordMutationLock(InProcessNamedLocks().run));
  final container = ProviderContainer(
    // Riverpod retries a failed build, which would let the outage flicker.
    retry: (_, _) => null,
    overrides: [
      pathLayoutLoader.overrideWith((ref) async => _layout),
      pathInfoLoader.overrideWith(
        (ref) async =>
            throw RecordStoreUnavailable(StateError('the record store could not be opened'), transient: false),
      ),
      storageLockGateProvider.overrideWithValue(gate),
      storageSaveFileProvider.overrideWithValue(({required dialogTitle, required fileName, required bytes}) async {
        _savedNames.add(fileName);
        return '${_tempRoot.path}/saved-$fileName';
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUpAll(loadAppTranslations);

  setUp(() {
    _savedNames = [];
    _tempRoot = Directory.systemTemp.createTempSync('uma_storage_outage_ops');
    _layout = PathInfo(
      documentDir: DirectoryPath('${_tempRoot.path}/documents'),
      supportDir: DirectoryPath('${_tempRoot.path}/support'),
      executableDir: DirectoryPath('${_tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${_tempRoot.path}/downloads'),
    );
  });

  tearDown(() {
    if (_tempRoot.existsSync()) {
      _tempRoot.deleteSync(recursive: true);
    }
  });

  group('during a store outage', () {
    test('the fixture is an outage: pathInfoProvider itself throws', () async {
      final container = _container();
      // Awaited first, so the loader has actually settled into its error state:
      // read synchronously it is merely `AsyncLoading`, and `value!` throws for
      // that reason instead of for the outage's.
      await expectLater(container.read(pathInfoLoader.future), throwsA(isA<RecordStoreUnavailable>()));
      // The negative control for every case below. If this ever stops throwing,
      // the cases are no longer measuring an outage and would pass for a reason
      // that has nothing to do with the defect.
      //
      // Matched loosely on purpose: riverpod 3 wraps the `value!` failure in its
      // own `ProviderException`, which the package does not export, so the type
      // cannot be named here. What the case is about is that the read throws at
      // all — the outage's identity is asserted on the line below.
      expect(() => container.read(pathInfoProvider), throwsA(anything));
      expect(container.read(pathInfoOutageProvider), isA<RecordStoreUnavailable>());
    });

    test('an unlocked delete removes the file', () async {
      final container = _container();
      final target = _seedFile('documents/storage/unclassified/scratch.bin', 'x');

      final report = await deleteStorageEntry(
        container.read(refBaseProvider),
        group: _groupOf(StorageGroupId.unclassified),
        target: target,
      );

      expect(report.failed, isEmpty);
      expect(File(target.path).existsSync(), isFalse);
    });

    test('a per-record delete takes its lock and removes the record', () async {
      final container = _container();
      final record = _layout.charaDetailActiveDir / 'record-1';
      _seedFile('documents/storage/chara_detail/active/record-1/record.json', '{}');

      final report = await deleteStorageEntry(
        container.read(refBaseProvider),
        group: _groupOf(StorageGroupId.activeRecords),
        target: record,
      );

      expect(report.failed, isEmpty);
      expect(Directory(record.path).existsSync(), isFalse);
    });

    test('a metadata delete goes through its serializer and removes the file', () async {
      final container = _container();
      final target = _seedFile('documents/storage/chara_detail/metadata/rating/default.json', '{}');

      final report = await deleteStorageEntry(
        container.read(refBaseProvider),
        group: _groupOf(StorageGroupId.metadata),
        target: target,
      );

      expect(report.failed, isEmpty);
      expect(File(target.path).existsSync(), isFalse);
    });

    test('the post-delete invalidate runs', () async {
      final container = _container();
      final target = _seedFile('documents/storage/chara_detail/metadata/rating/default.json', '{}');

      // Called from `runStorageDelete` right after the report arrives, and it
      // resolves the provider-invalidate table against the layout. Throwing here would leave the
      // delete done and the screen still showing what is gone.
      //
      // Wrapped in `Future.sync` rather than awaited directly so this case reads
      // the same whether the function answers `void` or a future: what is under
      // test is that it does not throw, not which of the two it returns.
      await Future<void>.sync(
        () => invalidateAfterStorageDelete(
          container.read(refBaseProvider),
          group: _groupOf(StorageGroupId.metadata),
          targets: [target],
        ),
      );
    });

    test('a download reads the file and reaches the save seam', () async {
      final container = _container();
      final target = _seedFile('documents/storage/unclassified/notes.json', '{}');

      final outcome = await downloadStorageFile(
        container.read(refBaseProvider),
        target,
        group: _groupOf(StorageGroupId.unclassified),
        silent: true,
      );

      expect(outcome, StorageDownloadOutcome.saved);
      expect(_savedNames, ['notes.json']);
    });

    test('an extraction reaches its runner under the exclusion', () async {
      _seedFile('documents/storage/unclassified/bundle/a.bin', 'a');
      var guarded = false;
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          pathLayoutLoader.overrideWith((ref) async => _layout),
          pathInfoLoader.overrideWith(
            (ref) async =>
                throw RecordStoreUnavailable(StateError('the record store could not be opened'), transient: false),
          ),
          storageLockGateProvider.overrideWithValue(
            RecordRecoveryGate(mutationLock: RecordMutationLock(InProcessNamedLocks().run)),
          ),
          storageZipPreflightProvider.overrideWithValue((ref, directory) async => null),
          // The encoder is a seam: what an outage changes is which provider the
          // exclusion reads, and the guard is where that read happens.
          storageZipRunnerProvider.overrideWithValue((ref, directory, onProgress, guard) async {
            await guard(() async => guarded = true);
            return StorageZipDelivery.written;
          }),
        ],
      );
      addTearDown(container.dispose);

      final outcome = await exportDirectoryAsZip(
        container.read(refBaseProvider),
        DirectoryPath('${_tempRoot.path}/documents/storage/unclassified/bundle'),
        group: _groupOf(StorageGroupId.unclassified),
        silent: true,
      );

      expect(outcome, StorageZipOutcome.written);
      expect(guarded, isTrue, reason: 'the guarded body never ran, so the exclusion refused before the work');
    });
  });
}
