// A record a VIDEO IMPORT produced is merged silently; the identical merge for a live capture
// still chimes.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/notification_sound_capture_origin_test.dart
//
// This is the desktop twin of notification_sound_harvest_boundary_test.dart, and it is the same
// property reached over the other transport. Web relays an import's records in batches on
// `onLiveRecordsHarvested`; Windows announces them one at a time on `onCharaDetailFinished`,
// because its recognizer writes each record straight into the live store instead of sweeping a
// scratch root. Both carry the same `origin` marker, and both hand it to the merge as
// `notifyDuplicate` -- so this file asks the same three questions of the desktop route.
//
// WHY THE MUTE IN notification_controller.dart DOES NOT MAKE THIS REDUNDANT.
// That mute is derived from `VideoImportState.isRunning`, i.e. from *when* a merge happens rather
// than from what produced the record. Every test here therefore runs with the import state already
// settled on `finished`, which switches that mute off completely: whatever silence is observed is
// the record's own origin doing the work, and nothing else can be mistaken for it. The mute stays
// in the code as defence in depth, and the last case pins that the two agree.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/notification_controller.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/sound_player.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/core/video_import_ops.dart';

import 'support/hive.dart';
import 'support/localization.dart';
import 'support/records.dart';

/// An import that has already ended, so the state-derived mute is off for every case below.
const _finished = VideoImportState(
  phase: VideoImportPhase.finished,
  fileName: 'clip.mkv',
  outcome: VideoImportOutcome(kind: VideoImportOutcomeKind.completed),
);

final _refProvider = Provider<Ref>((ref) => ref);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeMappers);
  setUpAll(loadAppTranslations);

  late Future<void> Function() closeHive;
  setUpAll(() async {
    // add() reads the auto-copy setting, which is Hive-backed.
    closeHive = await initHiveForTest(['settings']);
  });
  tearDownAll(() => closeHive());

  late Directory tempRoot;
  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_capture_origin');
    capturedRecordRetention.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      (call) async => null,
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      null,
    );
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

  /// Writes [record] as `<store>/<id>/record.json`, as the desktop recognizer does before it
  /// announces the id.
  void writeRecord(DirectoryPath storeDir, CharaDetailRecord record) {
    File('${(storeDir / record.id).path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(record.toMap()));
  }

  /// Boots the real notification layer over the real store and the real controller.
  Future<
    ({
      List<SoundType> played,
      ValueNotifier<VideoImportState> imports,
      PlatformController controller,
      ProviderContainer container,
      DirectoryPath activeDir,
    })
  >
  boot(WidgetTester tester, {void Function()? afterScan}) async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    // One stored record for the captured ones to duplicate.
    writeRecord(activeDir, makeRecord(id: 'stored', card: 1));

    late final ProviderContainer container;
    late final PlatformController controller;
    await tester.runAsync(() async {
      container = ProviderContainer(
        overrides: [
          pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
          moduleVersionLoader.overrideWith((ref) async => null),
          if (afterScan != null)
            charaDetailRecordStorageLoaderProvider.overrideWith(() => _LateCaptureStorage(afterScan)),
        ],
      );
      controller = PlatformController(container.read(_refProvider), const {});
      await container.read(charaDetailRecordStorageLoaderProvider.future);
      await container.read(charaDetailArchiveStorageLoaderProvider.future);
    });
    addTearDown(container.dispose);
    addTearDown(controller.dispose);

    final played = <SoundType>[];
    final imports = ValueNotifier<VideoImportState>(VideoImportState.idle);
    addTearDown(imports.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: NotificationLayer(debugVideoImportState: imports, debugPlaySound: played.add),
        ),
      ),
    );
    // The store's capture listener lives inside its build, so it only exists while something
    // listens to the store. Mounting the notification layer is not enough -- it listens to the cue
    // streams, not to the store -- and in the app the record table holds it. Without this the merge
    // under test would simply never run, and every silence assertion would be vacuous.
    addTearDown(container.listen(charaDetailRecordStorageLoaderProvider, (_, _) {}).close);
    return (played: played, imports: imports, controller: controller, container: container, activeDir: activeDir);
  }

  /// Announces one finished record exactly as the core does, then lets the merge and its cue land.
  ///
  /// [origin] is omitted from the payload when null, which is what a live capture sends.
  Future<void> capture(WidgetTester tester, PlatformController controller, String id, {String? origin}) async {
    await tester.runAsync(() async {
      controller.handleNativeMessage(
        jsonEncode({'type': 'onCharaDetailFinished', 'success': true, 'id': id, 'origin': ?origin}),
      );
      await pumpEventQueue(times: 20);
    });
    await tester.pump();
  }

  testWidgets('a record produced by a video import is merged silently', (tester) async {
    final env = await boot(tester);
    // The import is over, so the state-derived mute is off. If the origin did not travel with the
    // record, this chimes.
    env.imports.value = _finished;
    writeRecord(env.activeDir, makeRecord(id: 'import-record', card: 1));

    await capture(tester, env.controller, 'import-record', origin: harvestOriginVideoImport);

    expect(env.played, isEmpty, reason: 'an import merges its records without asking anyone to come and look');
    // The record really was rejected as a duplicate -- otherwise "silent" would be vacuous.
    expect(Directory((env.activeDir / 'import-record').path).existsSync(), isFalse);
  });

  testWidgets('the same merge for a live capture still chimes', (tester) async {
    // THE POSITIVE CONTROL. A change that silenced the desktop duplicate cue outright, or a test
    // rig whose cue sink was simply never wired, would pass the case above. This is what tells the
    // two apart, over the same code path and the same duplicate.
    final env = await boot(tester);
    env.imports.value = _finished;
    writeRecord(env.activeDir, makeRecord(id: 'live-record', card: 1));

    await capture(tester, env.controller, 'live-record');

    expect(env.played, [SoundType.error], reason: 'live capture must not lose a single chime');
    expect(Directory((env.activeDir / 'live-record').path).existsSync(), isFalse);
  });

  testWidgets('a finished record with no origin field is treated as live', (tester) async {
    // Absence means live, on purpose, and this pins the direction so it cannot be flipped quietly:
    // a core or a relay that loses the field costs an import one extra cue, never a live capture a
    // missing one. It is also what every core built before the field sends.
    final env = await boot(tester);
    env.imports.value = _finished;
    writeRecord(env.activeDir, makeRecord(id: 'unlabelled', card: 1));

    await capture(tester, env.controller, 'unlabelled');

    expect(env.played, [SoundType.error]);
  });

  testWidgets('an unrecognised origin is treated as live too', (tester) async {
    // The same fail-open rule stated against a value rather than against absence: only the import's
    // own marker silences a record. A future origin nobody here knows about is a live capture until
    // this file says otherwise.
    final env = await boot(tester);
    env.imports.value = _finished;
    writeRecord(env.activeDir, makeRecord(id: 'unknown-origin', card: 1));

    await capture(tester, env.controller, 'unknown-origin', origin: 'some_future_session_kind');

    expect(env.played, [SoundType.error]);
  });

  testWidgets('a record merged while the import is still running is silent too', (tester) async {
    // The body of an import, which the state-derived mute already covered. Kept so the two
    // mechanisms are pinned together: the record's origin and the running state must agree, and
    // neither may be removed on the grounds that the other one happens to cover this case.
    final env = await boot(tester);
    env.imports.value = const VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv');
    writeRecord(env.activeDir, makeRecord(id: 'import-body', card: 1));

    await capture(tester, env.controller, 'import-body', origin: harvestOriginVideoImport);

    expect(env.played, isEmpty);
    // The merge really ran. Without this the case cannot tell "merged in silence" from "not merged
    // at all", and a change that skipped merging while an import runs would leave the duplicate on
    // disk and still read as a pass. The other cases in this file all carry the same line.
    expect(Directory((env.activeDir / 'import-body').path).existsSync(), isFalse);
  });

  testWidgets('a record retained across the listener-attach window keeps its origin', (tester) async {
    // THE DEFERRED MERGE, and the longest wait the marker has to survive. A capture announced while
    // the store is mid-build reaches no listener; `capturedRecordRetention` holds the id and the
    // build drains it once its state is published. That merge is later than every other one here --
    // later than the import can plausibly still be running -- so the origin has to be stored with
    // the id rather than looked up again when the drain finally gets to it.
    //
    // The window is reproduced through the `scanRecords` seam, exactly as
    // storage_captured_record_retention_test.dart does: both records land after the scan has already
    // listed the store, which is the only ordering in which the retention is the merge path.
    final activeDir = pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailActiveDir;
    // Armed only for the rebuild below: the first build has to complete, and the notification layer
    // has to be mounted on it, before the drain is allowed to raise anything.
    var arm = false;
    final env = await boot(
      tester,
      afterScan: () {
        if (!arm) {
          return;
        }
        arm = false;
        writeRecord(activeDir, makeRecord(id: 'r-a', card: 1));
        writeRecord(activeDir, makeRecord(id: 'r-b', card: 1));
        capturedRecordRetention.retain('r-a', fromVideoImport: true);
        capturedRecordRetention.retain('r-b');
      },
    );
    // The import has already ended by the time the drain runs, which is the point.
    env.imports.value = _finished;
    arm = true;

    await tester.runAsync(() async {
      env.container.invalidate(charaDetailRecordStorageLoaderProvider);
      await env.container.read(charaDetailRecordStorageLoaderProvider.future);
      await pumpEventQueue(times: 20);
    });
    await tester.pump();

    expect(arm, isFalse, reason: 'the window this test is about has to have been reached');

    expect(capturedRecordRetention.pending, isEmpty, reason: 'the drain has to have run for this to mean anything');
    // Both duplicate `stored`; only the live-origin one is allowed to say so out loud.
    expect(Directory((env.activeDir / 'r-a').path).existsSync(), isFalse);
    expect(Directory((env.activeDir / 'r-b').path).existsSync(), isFalse);
    expect(env.played, [SoundType.error], reason: 'exactly the live one of the two drained records chimes');
  });
}

/// A store whose scan is followed by two captures landing in the listener-attach window, so they
/// reach the store through [capturedRecordRetention] instead of through the capture listener.
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
