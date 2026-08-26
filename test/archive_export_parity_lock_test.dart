// Pins S09-07: the *desktop* ZIP export reads its record directories under the
// same record mutation lock every desktop writer takes, and the web leg keeps
// taking it too. Before this, `ZipExporter._export` handed raw paths to
// `compute` with no gate at all, so an inheritance write-back or a regeneration
// batch could rewrite `record.json` and the images while `addDirectory` walked
// them -- a torn file in the zip, or a throw on a file that moved.
//
// Nothing in the UI prevents that overlap: the export button is disabled only
// while another export runs, and the capture card's mutual exclusion covers the
// four capture features, not exporting. So the guarantee has to be a lock, not
// an invariant, and the first test asserts it as exclusion (the export cannot
// even begin writing while a record's lock is held elsewhere) rather than as
// "some lock was requested" -- an implementation that acquired and released the
// lock before `compute` would satisfy the latter and still tear.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/archive_export_parity_lock_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/exporter.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/utils.dart';

import 'support/records.dart';
import 'support/web_like_fs_backend.dart';

final _refProvider = Provider<RefBase>((ref) => ref.base);

/// The lock name [RecordMutationLock] derives for a record id.
String _recordLockName(String recordId) {
  return 'umacapture:v1:record:${base64Url.encode(utf8.encode(recordId)).replaceAll('=', '')}';
}

void main() {
  setUpAll(initializeMappers);

  late Directory tempRoot;
  late FsBackend originalBackend;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_export_lock');
    originalBackend = fsBackend;
  });

  tearDown(() {
    fsBackend = originalBackend;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  PathInfo pathInfoFor(DirectoryPath root) => PathInfo(
    documentDir: root,
    supportDir: root,
    executableDir: root / 'exe',
    downloadDir: root / 'dl',
    dataRoot: root,
  );

  /// Seeds `active/<id>` the way a captured record looks on disk.
  void seed(PathInfo info, CharaDetailRecord record) {
    final dir = Directory((info.charaDetailActiveDir / record.id).path)..createSync(recursive: true);
    File('${dir.path}/record.json').writeAsStringSync(const JsonEncoder.withIndent('    ').convert(record.toMap()));
    File('${dir.path}/trainee.jpg').writeAsBytesSync([9, 8, 7]);
    final labels = File(info.modulesDir.filePath('labels.json').path)..createSync(recursive: true);
    labels.writeAsStringSync(jsonEncode({'character': <String>[]}));
  }

  ProviderContainer containerFor(PathInfo info, List<CharaDetailRecord> records, File output, RecordRecoveryGate gate) {
    final container = ProviderContainer.test(
      overrides: [
        exportIsWebProvider.overrideWithValue(false),
        exportInitialDirectoryProvider.overrideWithValue(() async => tempRoot.path),
        exportSaveFileProvider.overrideWithValue(
          ({
            required String dialogTitle,
            required String fileName,
            String? initialDirectory,
            required Uint8List bytes,
            required bool lockParentWindow,
          }) async => output.path,
        ),
        pathInfoProvider.overrideWithValue(info),
        charaDetailRecordStorageProvider.overrideWithValue(records),
        labelMapProvider.overrideWithValue(const {}),
        exportRecoveryGateProvider.overrideWithValue(gate),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('the desktop zip export cannot start writing while a record lock is held elsewhere', () async {
    final root = DirectoryPath(tempRoot.path);
    final info = pathInfoFor(root);
    final record = makeRecord(id: 'record-1', card: 7);
    seed(info, record);
    final output = File('${tempRoot.path}/export.zip');

    // A real lock, not a spy: the point is exclusion, and only the real grant
    // algorithm can park the export behind the holder below.
    final gate = RecordRecoveryGate(mutationLock: RecordMutationLock(InProcessNamedLocks().run));
    final container = containerFor(info, [record], output, gate);

    // Stand in for the concurrent writer (inheritance write-back / regeneration):
    // hold record-1's lock, exactly as those writers do, and never let go until
    // this test says so.
    final entered = Completer<void>();
    final release = Completer<void>();
    final holder = gate.runForRecord(info.storageDir, 'record-1', () async {
      entered.complete();
      await release.future;
    });
    await entered.future;

    var exportSettled = false;
    final results = <ExportResult>[];
    final exporting = ZipExporter('Export records', 'records.zip', container.read(_refProvider), const {
      'record-1',
    }, RecordSource.active).export(onSuccess: results.add).whenComplete(() => exportSettled = true);

    // Give the export every chance to run to completion. It must not: an
    // implementation without the gate reaches `compute` here and writes the zip.
    // A turn count, not a time budget, and deliberately not one of the `test/support/settling.dart`
    // helpers: this waits on something that must *not* arrive, the case that file's header excludes
    // ("no arrival to poll for ... only a weaker negative"). `release` below is the only thing that
    // can free the export, so no number of turns changes the verdict -- 1 and 5000 both pass.
    await pumpEventQueue(times: 200);
    expect(exportSettled, isFalse, reason: 'the export must wait for the exported record\'s mutation lock');
    expect(output.existsSync(), isFalse, reason: 'not one byte of the zip may be written under a foreign lock');

    release.complete();
    await holder;
    await exporting;

    expect(results, hasLength(1), reason: 'once the lock is free the export completes normally');
    expect(output.existsSync(), isTrue);
  });

  test('a solo desktop export takes one exclusive lock per record and nothing broader', () async {
    // Negative control: with no contention the export behaves exactly as before,
    // and the acquisitions are scoped to the exported ids.
    final root = DirectoryPath(tempRoot.path);
    final info = pathInfoFor(root);
    final records = [makeRecord(id: 'record-1', card: 7), makeRecord(id: 'record-2', card: 8)];
    for (final record in records) {
      seed(info, record);
    }
    final output = File('${tempRoot.path}/export.zip');

    final calls = <(String, RecordMutationLockMode)>[];
    final gate = RecordRecoveryGate(
      mutationLock: RecordMutationLock((name, mode, action) {
        calls.add((name, mode));
        return action();
      }),
    );
    final container = containerFor(info, records, output, gate);

    final results = <ExportResult>[];
    await ZipExporter('Export records', 'records.zip', container.read(_refProvider), const {
      'record-1',
      'record-2',
    }, RecordSource.active).export(onSuccess: results.add);

    expect(results, hasLength(1));
    expect(output.existsSync(), isTrue);
    expect(calls.first.$2, RecordMutationLockMode.shared, reason: 'the shared root gate is taken first');
    expect(
      calls.where((call) => call.$2 == RecordMutationLockMode.exclusive).map((call) => call.$1).toSet(),
      {_recordLockName('record-1'), _recordLockName('record-2')},
      reason: 'one exclusive acquisition per exported record, and nothing broader',
    );
  });

  test('the web zip export locks the same records through the same seam', () async {
    // Parity half: both legs read the gate from one provider, so they cannot
    // drift into locking differently again.
    fsBackend = WebLikeFsBackend(originalBackend);
    final root = DirectoryPath(tempRoot.path);
    final info = pathInfoFor(root);
    final record = makeRecord(id: 'record-1', card: 7);
    seed(info, record);
    final output = File('${tempRoot.path}/unused.zip');

    final exclusiveNames = <String>[];
    final gate = RecordRecoveryGate(
      mutationLock: RecordMutationLock((name, mode, action) {
        if (mode == RecordMutationLockMode.exclusive) exclusiveNames.add(name);
        return action();
      }),
    );
    final container = containerFor(info, [record], output, gate);

    final bytes = await ZipExporter('Export records', 'records.zip', container.read(_refProvider), const {
      'record-1',
    }, RecordSource.active).exportBytes();

    expect(bytes, isNotEmpty);
    expect(exclusiveNames, [_recordLockName('record-1')]);
  });
}
