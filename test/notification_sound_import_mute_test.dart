// A video import plays NO notification sound, on any of the four cues; live capture is unchanged.
// Run: .fvm/flutter_sdk/bin/flutter test test/notification_sound_import_mute_test.dart
//
// The four chimes all reach the same sink but they do NOT share a dispatch: standby, success and the
// capture-time error come out of `platform_controller.dart`'s `handleNativeMessage`, while the
// duplicate-character cue is emitted by the record store. That is why the gate is at the sink -- a
// gate in the controller's switch would silence three of the four and leave the fourth chiming.
//
// The events themselves must keep flowing: the progress rings, the status line and the record harvest
// all read them, and an import drives every one of those. Only the audio is muted, so these tests
// assert on the sound sink and never on the events.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/notification_controller.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/sound_player.dart';
import 'package:umacapture/src/core/video_import_ops.dart';

import 'support/localization.dart';

const _importing = VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv');
const _cancelling = VideoImportState(phase: VideoImportPhase.cancelling, fileName: 'clip.mkv');
const _refused = VideoImportState(
  phase: VideoImportPhase.finished,
  fileName: 'clip.mkv',
  outcome: VideoImportOutcome(kind: VideoImportOutcomeKind.refused, blocker: VideoImportBlocker.regenerating),
);
const _failed = VideoImportState(
  phase: VideoImportPhase.finished,
  fileName: 'clip.mkv',
  outcome: VideoImportOutcome(kind: VideoImportOutcomeKind.failed, message: 'boom'),
);

/// Drives the four sound-triggering event streams through the real [NotificationLayer].
class _Harness {
  final scrollReady = StreamController<int>.broadcast();
  final pageReady = StreamController<int>.broadcast();
  final error = StreamController<int>.broadcast();
  final duplicated = StreamController<int>.broadcast();
  final played = <SoundType>[];
  final imports = ValueNotifier<VideoImportState>(VideoImportState.idle);
  int _sequence = 0;

  Future<void> pump(WidgetTester tester) {
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          scrollReadyEventProvider.overrideWith((ref) => scrollReady.stream),
          pageReadyEventProvider.overrideWith((ref) => pageReady.stream),
          errorEventProvider.overrideWith((ref) => error.stream),
          duplicatedCharaEventProvider.overrideWith((ref) => duplicated.stream),
        ],
        child: MaterialApp(
          home: NotificationLayer(debugVideoImportState: imports, debugPlaySound: played.add),
        ),
      ),
    );
  }

  /// Fires every cue once. The payload is a fresh id each time because `ref.listen` skips an equal
  /// consecutive `AsyncData`, exactly as `_soundEventSequence` exists to prevent in production.
  Future<void> fireEveryCue(WidgetTester tester) async {
    for (final sink in [scrollReady, pageReady, error, duplicated]) {
      sink.add(++_sequence);
      await tester.pump();
    }
  }

  void dispose() {
    scrollReady.close();
    pageReady.close();
    error.close();
    duplicated.close();
    imports.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  late _Harness harness;

  setUp(() => harness = _Harness());
  tearDown(() => harness.dispose());

  testWidgets('live capture plays all four cues', (tester) async {
    // The control. Without it a mute that silenced everything unconditionally would pass every
    // assertion below.
    await harness.pump(tester);
    await harness.fireEveryCue(tester);

    expect(harness.played, [SoundType.standby, SoundType.success, SoundType.error, SoundType.error]);
  });

  testWidgets('a running import plays none of them', (tester) async {
    await harness.pump(tester);
    harness.imports.value = _importing;
    await harness.fireEveryCue(tester);

    expect(harness.played, isEmpty, reason: 'an import is an unattended bulk pass; nobody is waiting for a chime');
  });

  testWidgets('a cancelling import is still an import', (tester) async {
    // The producer keeps pushing frames until it reaches a frame boundary, so cues keep arriving
    // after the user pressed cancel.
    await harness.pump(tester);
    harness.imports.value = _cancelling;
    await harness.fireEveryCue(tester);

    expect(harness.played, isEmpty);
  });

  testWidgets('every ending releases the mute', (tester) async {
    // THE WORST OUTCOME THIS GUARDS is a mute that outlives its import and silences live capture for
    // the rest of the session -- with no control anywhere to lift it. The mute is derived from the
    // import state rather than latched, so every ending lifts it; this pins each of them anyway,
    // because "derived" is a property of the code and not of the outcome.
    await harness.pump(tester);
    for (final ending in [VideoImportState.idle, _refused, _failed]) {
      harness.imports.value = _importing;
      await harness.fireEveryCue(tester);
      expect(harness.played, isEmpty, reason: 'muted while running');

      harness.imports.value = ending;
      await harness.fireEveryCue(tester);
      expect(harness.played, [
        SoundType.standby,
        SoundType.success,
        SoundType.error,
        SoundType.error,
      ], reason: 'the mute must not outlive ${ending.phase}/${ending.outcome?.kind}');
      harness.played.clear();
    }
  });
}
