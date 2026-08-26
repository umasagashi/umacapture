// Tests for the video-import gate on [CharaDetailRecordRegenerationController.start].
// Run: .fvm/flutter_sdk/bin/flutter test test/regeneration_import_gate_test.dart
//
// The defect this pins: two of the five ways into a regeneration batch are not controls and
// therefore could not be disabled — a manual module install auto-starts a batch from its own
// success path, and every store build re-checks record versions, which an import's own
// forceRebuild reaches. Both reached the worker while an import owned the event loop, which
// refuses each record and turns a whole store into error-level failures. The refusal now lives
// where all five funnel, and it must decline *before* touching the pipeline — which is what
// this asserts, since a headless container has no platform controller either way.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/video_import_ops.dart';

/// Runs `start()` with [importState] injected and reports whether it reached the pipeline.
///
/// "Reached the pipeline" is read off [platformControllerLoader] being resolved: it is the first
/// thing an accepted batch does, and the only observable that separates a declined batch from one
/// that a headless container merely could not run (both leave progress at none).
Future<bool> _startReachesTheController(VideoImportState importState) async {
  var loaderRead = false;
  final container = ProviderContainer(
    overrides: [
      platformControllerLoader.overrideWith((ref) async {
        loaderRead = true;
        return null;
      }),
    ],
  );
  addTearDown(container.dispose);
  final notifier = container.read(charaDetailRecordRegenerationControllerProvider.notifier);
  final imports = ValueNotifier<VideoImportState>(importState);
  addTearDown(imports.dispose);
  notifier.debugVideoImportState = imports;
  await notifier.start(const []);
  return loaderRead;
}

void main() {
  setUpAll(initializeMappers);

  test('declines a batch while a video import owns the event loop', () async {
    final reached = await _startReachesTheController(
      const VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv'),
    );
    expect(reached, isFalse, reason: 'the batch would have been refused record by record by the worker');
  });

  test('declines while an import is still starting or cancelling', () async {
    for (final phase in [VideoImportPhase.starting, VideoImportPhase.cancelling]) {
      expect(await _startReachesTheController(VideoImportState(phase: phase)), isFalse, reason: '$phase');
    }
  });

  test('an open file dialog alone does not decline a batch', () async {
    // `picking` owns nothing — the import may never start — so it must not block regeneration,
    // exactly as it does not block live capture (see VideoImportState.isRunning).
    expect(await _startReachesTheController(const VideoImportState(phase: VideoImportPhase.picking)), isTrue);
  });

  test('runs normally when no import is running', () async {
    expect(await _startReachesTheController(VideoImportState.idle), isTrue);
  });
}
