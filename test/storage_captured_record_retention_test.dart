// Verifies that a capture announced while the record store has no listener
// attached is not lost.
//
// The captured-record event is an unbuffered broadcast stream, and the store's
// `ref.listen` on it lives inside build(): it is dropped when a rebuild starts
// and re-attached only after that build's awaits. A capture that finishes in
// that window used to reach nobody, leaving the record on disk but out of the
// list until some later full scan. Web never had the hole (its harvest is read
// after awaiting the store, and the worker retains an unacknowledged record), so
// the desktop producer now retains the id until the store acknowledges it.
//
// The window is reproduced through the `scanRecords` seam: the capture lands
// after the scan has already listed the directory, which is exactly the ordering
// that loses the record. kIsWeb is false on the VM, so this exercises the
// desktop branch directly.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/storage_captured_record_retention_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/version_check.dart';

import 'support/hive.dart';
import 'support/records.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    initializeMappers();
  });
  // add() reads the auto-copy setting, which is Hive-backed.
  useHiveForTest(['settings']);

  late Directory tempRoot;
  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_capture_retention');
    capturedRecordRetention.clear();
  });
  tearDown(() {
    capturedRecordRetention.clear();
    tempRoot.deleteSync(recursive: true);
  });

  PathInfo pathInfoFor(DirectoryPath root) => PathInfo(
    documentDir: root,
    supportDir: root,
    executableDir: root / 'exe',
    downloadDir: root / 'dl',
    dataRoot: root,
  );

  void writeRecord(DirectoryPath storeDir, CharaDetailRecord record) {
    File('${(storeDir / record.id).path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent('    ').convert(record.toMap()));
  }

  ProviderContainer makeContainer(DirectoryPath root, {void Function()? afterScan}) {
    return ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        // Skip the (network/version) module check so build() returns immediately.
        moduleVersionLoader.overrideWith((ref) async => null),
        if (afterScan != null)
          charaDetailRecordStorageLoaderProvider.overrideWith(() => _LateCaptureStorage(afterScan)),
      ],
    );
  }

  test('a capture announced while no listener is attached is ingested by the next build', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir, makeRecord(id: 'existing', card: 1));

    // The capture finishes after the scan listed the store: the recognizer has
    // written the record and announced its id, and no listener exists yet.
    final container = makeContainer(
      root,
      afterScan: () {
        writeRecord(activeDir, makeRecord(id: 'late', card: 2));
        capturedRecordRetention.retain('late');
      },
    );
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);

    await pumpEventQueue();

    // The scan could not have listed it -- it was written after the listing --
    // so the drain is the only way it can be here.
    expect(active.getBy(id: 'late'), isNotNull, reason: 'the retained capture must not be lost');
    expect(active.length, 2);
    expect(container.read(charaDetailRecordStorageLoaderProvider).hasError, isFalse);
  });

  test('an ingested capture is acknowledged, so a later build does not re-run it', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir, makeRecord(id: 'existing', card: 1));

    var landed = false;
    final container = makeContainer(
      root,
      afterScan: () {
        writeRecord(activeDir, makeRecord(id: 'late', card: 2));
        capturedRecordRetention.retain('late');
        landed = true;
      },
    );
    addTearDown(container.dispose);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    await pumpEventQueue();

    expect(landed, isTrue, reason: 'the window this test is about has to have been reached');
    expect(capturedRecordRetention.pending, isEmpty, reason: 'the store has taken responsibility for the id');
  });

  test('the drain leaves an ordinary build untouched', () async {
    // Nothing outstanding must mean nothing scheduled: the retention is a
    // recovery path, not a second ingest path every build runs.
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir, makeRecord(id: 'existing', card: 1));

    final container = makeContainer(root);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await pumpEventQueue();

    expect(active.length, 1);
    expect(capturedRecordRetention.pending, isEmpty);
  });

  test('the producer retains every id it announces over the wire', () async {
    // The other tests retain by hand; this one pins the wiring, through the real
    // `onCharaDetailFinished` dispatch, so the retention cannot silently stop
    // being fed.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      (call) async => null,
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformChannel.channel,
        null,
      ),
    );
    final root = DirectoryPath(tempRoot.path);
    final container = makeContainer(root);
    addTearDown(container.dispose);
    final controller = PlatformController(container.read(_refProvider), const {});
    addTearDown(controller.dispose);

    controller.handleNativeMessage(jsonEncode({'type': 'onCharaDetailFinished', 'success': true, 'id': 'wired'}));

    expect(capturedRecordRetention.pending, ['wired']);
  });

  test('a retained id whose record cannot be decoded is quarantined, not retried forever', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir, makeRecord(id: 'existing', card: 1));

    var landed = false;
    final container = makeContainer(
      root,
      afterScan: () {
        File('${(activeDir / 'broken').path}/record.json')
          ..createSync(recursive: true)
          ..writeAsStringSync('{ this is not a record }');
        capturedRecordRetention.retain('broken');
        landed = true;
      },
    );
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    await pumpEventQueue();

    expect(landed, isTrue, reason: 'the window this test is about has to have been reached');
    expect(active.getBy(id: 'broken'), isNull);
    expect(active.length, 1, reason: 'the good record is untouched');
    expect(capturedRecordRetention.pending, isEmpty, reason: 'a handled id is acknowledged even when quarantined');
    // Quarantined, i.e. moved aside out of active/ (where it lands is the
    // quarantine tests' subject, not this one).
    expect(Directory((activeDir / 'broken').path).existsSync(), isFalse);
    expect(container.read(charaDetailRecordStorageLoaderProvider).hasError, isFalse);
  });
}

/// Hands the controller the same [Ref] its own provider would.
final _refProvider = Provider<Ref>((ref) => ref);

/// A store whose scan is followed by a capture landing in the listener-attach
/// window, reproducing the ordering that used to lose the record.
class _LateCaptureStorage extends CharaDetailRecordStorage {
  _LateCaptureStorage(this.afterScan);

  final void Function() afterScan;

  @override
  Future<RecordScanResult> scanRecords(DirectoryPath directory) async {
    final result = await super.scanRecords(directory);
    afterScan();
    return result;
  }
}
