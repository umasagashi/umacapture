// Who is allowed to write the capture page's 画面サイズ / フレームレート badges.
// Run: .fvm/flutter_sdk/bin/flutter test test/capture_badges_during_import_test.dart
//
// A video import drives the same shared recognition core a live capture does, so it emits the same
// `onFrameSizeReported` / `onFrameRateReported` notifications. They used to land in the live-capture
// providers, and the capture area then showed a size and an fps badge next to "capture is stopped" --
// and kept showing them after the import ended, because only a capture session's teardown clears
// them. The badges are graded for live capture (the fps chip goes red below 15 to say "the share is
// too slow"), while an import is deliberately decoupled from playback speed, so the numbers were not
// merely misplaced but wrong.
//
// `PlatformController.debugVideoImportState` is what makes this reachable from the VM at all: the
// `video_import.dart` facade resolves to the desktop stub here, whose notifier is a constant idle.
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/video_import_ops.dart';

import 'support/hive.dart';

const _sizeReport = {
  'type': 'onFrameSizeReported',
  'size': {'width': 640, 'height': 360},
};
const _rateReport = {'type': 'onFrameRateReported', 'fps': 30.0};

/// The import state the harness below hands the controller, set by each case before it reads.
ValueNotifier<VideoImportState> _importState = ValueNotifier<VideoImportState>(VideoImportState.idle);

/// Stands in for `platformControllerLoader`, which reaches the module version, the asset bundle and
/// the record store; this test needs none of that, only a controller holding a real [Ref].
final _controllerHarness = Provider<PlatformController>((ref) {
  final controller = PlatformController(ref, const {})..debugVideoImportState = _importState;
  ref.onDispose(controller.dispose);
  return controller;
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  useHiveForTest(['settings']);

  setUp(() async {
    await Hive.box('settings').clear();
    // The controller pushes its initial config from its constructor; answer it so the
    // fire-and-forget call does not surface as a failure toast.
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
  });

  /// Drives both frame reports through a controller whose import state is [state].
  ProviderContainer report(VideoImportState state) {
    _importState = ValueNotifier<VideoImportState>(state);
    addTearDown(_importState.dispose);
    final container = ProviderContainer.test();
    final controller = container.read(_controllerHarness);
    controller.handleNativeMessage(jsonEncode(_sizeReport));
    controller.handleNativeMessage(jsonEncode(_rateReport));
    return container;
  }

  test('a live capture writes both badges', () {
    final container = report(VideoImportState.idle);

    expect(container.read(capturingFrameSizeProvider), const ui.Size(640, 360));
    expect(container.read(capturingFrameRateProvider), 30.0);
  });

  test('a running import writes neither', () {
    final container = report(const VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv'));

    expect(container.read(capturingFrameSizeProvider), isNull, reason: 'the clip sized a stopped capture');
    expect(container.read(capturingFrameRateProvider), isNull, reason: 'a decode rate was graded as a share rate');
  });

  test('a finished import stops holding the reports back', () {
    // The gate is the import, not "anything that is not a capture": once it has ended, the next
    // live session must be able to describe itself again.
    final container = report(
      const VideoImportState(
        phase: VideoImportPhase.finished,
        outcome: VideoImportOutcome(kind: VideoImportOutcomeKind.completed),
      ),
    );

    expect(container.read(capturingFrameSizeProvider), const ui.Size(640, 360));
    expect(container.read(capturingFrameRateProvider), 30.0);
  });
}
