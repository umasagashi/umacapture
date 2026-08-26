// A record merged AFTER a video import has finished is still silent; the identical merge for a
// live capture still chimes.
// Run: .fvm/flutter_sdk/bin/flutter test test/notification_sound_harvest_boundary_test.dart
//
// WHY THIS EXISTS, when notification_sound_import_mute_test.dart already covers the mute.
//
// That test drives `VideoImportState` directly and fires the cues while it holds a value. It can
// therefore never observe the one moment the mute does not cover: the import's records are merged
// on `PlatformController`'s unawaited `_liveMergeChain`, and the LAST batch of a clip is enqueued
// while the import is still running but *executed* after `startVideoImport` has returned and the
// state has settled. Measured in Chrome 151, the last record of an import merged ~0.9 s after
// "video import completed" and, being a duplicate, played error.wav -- one stray chime per import,
// on every import that ended with a duplicate.
//
// So this test crosses that boundary rather than modelling it: the merge is driven through the real
// `PlatformController.handleNativeMessage` dispatch and the real `CharaDetailRecordStorage` over
// real directories, so the duplicate cue is raised by the store exactly as it is in production,
// with the import state already settled on `finished`.
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

import 'support/localization.dart';
import 'support/records.dart';
import 'support/settling.dart';

/// An import that has already ended: the state the stray chime was measured against.
const _finished = VideoImportState(
  phase: VideoImportPhase.finished,
  fileName: 'clip.mp4',
  outcome: VideoImportOutcome(kind: VideoImportOutcomeKind.completed),
);

final _refProvider = Provider<Ref>((ref) => ref);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeMappers);
  setUpAll(loadAppTranslations);

  late Directory tempRoot;
  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_harvest_boundary');
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
    tempRoot.deleteSync(recursive: true);
  });

  PathInfo pathInfoFor(DirectoryPath root) => PathInfo(
    documentDir: root,
    supportDir: root,
    executableDir: root / 'exe',
    downloadDir: root / 'dl',
    dataRoot: root,
  );

  DirectoryPath tempRootActiveDir(String id) => pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailActiveDir / id;

  /// Writes [record] as `<store>/<id>/record.json`, as the harvest's OPFS commit would.
  void writeRecord(DirectoryPath storeDir, CharaDetailRecord record) {
    File('${(storeDir / record.id).path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(record.toMap()));
  }

  /// Boots the real notification layer over the real store and controller.
  ///
  /// Returns the sound sink, the import-state seam, the controller the harvest message is
  /// dispatched through, and the active store's directory.
  ///
  /// Everything that touches the store runs inside [WidgetTester.runAsync]: the record scan is real
  /// file I/O, and a continuation started under the widget binding's fake clock would only resume
  /// on a pump, which is not something the unawaited merge chain gets.
  Future<
    ({
      List<SoundType> played,
      ValueNotifier<VideoImportState> imports,
      PlatformController controller,
      DirectoryPath activeDir,
    })
  >
  boot(WidgetTester tester) async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    // One stored record for the imported ones to duplicate.
    writeRecord(activeDir, makeRecord(id: 'stored', card: 1));

    late final ProviderContainer container;
    late final PlatformController controller;
    await tester.runAsync(() async {
      container = ProviderContainer(
        overrides: [
          pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
          moduleVersionLoader.overrideWith((ref) async => null),
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
    return (played: played, imports: imports, controller: controller, activeDir: activeDir);
  }

  /// Relays one harvest exactly as `platform_channel_web` does, waits for the unawaited merge
  /// chain to actually finish, then pumps so any cue reaches the sound sink.
  ///
  /// The merge's completion is observed rather than assumed: a rejected duplicate has its
  /// just-written directory discarded, so the directory disappearing is the merge having run.
  ///
  /// TWO ARRIVALS, NOT ONE. The discard and the cue are separate: the store deletes the rejected
  /// directory on the merge chain, and the cue only reaches [chiming] on a later pump, once the
  /// notification layer has seen the store's event. Waiting on the directory alone left the second
  /// one to a fixed `pumpEventQueue` window, and on a contended host that window expired first --
  /// the case then read `Expected: [SoundType.error] / Actual: []`, i.e. a timeout wearing the
  /// costume of a lost chime. Reproduced on this machine under 16 spinners with
  /// `flutter test --concurrency=32`, both before and after the directory wait was made to fail
  /// loudly, which is what told the two arrivals apart.
  ///
  /// A case that expects a cue passes its sink as [chiming] and the arrival is polled. A case that
  /// expects SILENCE passes nothing: there is nothing to poll for, so its window stays a window --
  /// a slow host can only make that negative weaker, never falsely red (`support/settling.dart`).
  Future<void> harvest(
    WidgetTester tester,
    PlatformController controller,
    String id, {
    String? origin,
    List<SoundType>? chiming,
  }) async {
    final merged = Directory((tempRootActiveDir(id)).path);
    await tester.runAsync(() async {
      controller.handleNativeMessage(
        jsonEncode({
          'type': 'onLiveRecordsHarvested',
          'ids': [id],
          'origin': ?origin,
        }),
      );
      // The deadline used to be the loop's own condition, so expiry fell out of the loop in
      // silence and surfaced three lines later in whichever case called this.
      await waitUntil(
        () => !merged.existsSync(),
        describe: 'the unawaited merge chain to run and discard the duplicate record "$id"',
      );
      await pumpEventQueue(times: 20);
    });
    await tester.pump();
    if (chiming != null) {
      await settleUntil(
        tester,
        () => chiming.isNotEmpty,
        describe: 'the cue for the merged record "$id" to reach the sound sink',
      );
    }
  }

  testWidgets('the last record of a finished import is merged silently', (tester) async {
    final env = await boot(tester);
    // THE BOUNDARY: the import is over. Nothing about the state can tell the merge apart from a
    // live capture's any more, so if the origin did not travel with the batch this chimes.
    env.imports.value = _finished;
    writeRecord(env.activeDir, makeRecord(id: 'import-tail', card: 1));

    await harvest(tester, env.controller, 'import-tail', origin: harvestOriginVideoImport);

    expect(env.played, isEmpty, reason: 'an import plays no cue, including for the record it merges after it ends');
    // The record really was rejected as a duplicate -- otherwise "silent" would be vacuous.
    expect(Directory((env.activeDir / 'import-tail').path).existsSync(), isFalse);
  });

  testWidgets('the same merge for a live capture still chimes', (tester) async {
    // THE POSITIVE CONTROL. A fix that silenced the merge outright would pass the test above.
    final env = await boot(tester);
    writeRecord(env.activeDir, makeRecord(id: 'live-record', card: 1));

    await harvest(tester, env.controller, 'live-record', chiming: env.played);

    expect(env.played, [SoundType.error], reason: 'live capture must not lose a single chime');
  });

  testWidgets('a harvest with no origin field is treated as live', (tester) async {
    // Absence means live, on purpose: a relay that loses the field costs an import an extra cue,
    // never a live capture a missing one. Pinned so the default can never be flipped quietly.
    final env = await boot(tester);
    env.imports.value = _finished;
    writeRecord(env.activeDir, makeRecord(id: 'unlabelled', card: 1));

    await harvest(tester, env.controller, 'unlabelled', chiming: env.played);

    expect(env.played, [SoundType.error]);
  });

  testWidgets('an import merged while it is still running is silent too', (tester) async {
    // The body of an import, which the state-derived gate already covered. Kept so the two
    // mechanisms are pinned together: the record's origin and the running state must agree.
    final env = await boot(tester);
    env.imports.value = const VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mp4');
    writeRecord(env.activeDir, makeRecord(id: 'import-body', card: 1));

    await harvest(tester, env.controller, 'import-body', origin: harvestOriginVideoImport);

    expect(env.played, isEmpty);
    // The merge really ran -- otherwise "silent" is vacuous. An implementation that skipped
    // merging altogether while an import is running plays nothing either. `harvest`'s `waitUntil`
    // now names that case at its deadline rather than falling out of the loop in silence, and this
    // line is the assertion it used to be left to. Every other case in this file carries it; this
    // one did not.
    expect(Directory((env.activeDir / 'import-body').path).existsSync(), isFalse);
  });
}
