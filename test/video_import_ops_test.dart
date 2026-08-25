// Tests for `video_import_ops.dart`, the pure decisions of the video-import front end.
// Run: .fvm/flutter_sdk/bin/flutter test test/video_import_ops_test.dart
//
// Everything that actually runs an import is web-only Dart (`dart:js_interop`,
// `package:web`, `WasmWorkerClient`) and cannot be compiled by the VM test runner at
// all, so this file is where the rules that decide an import's behaviour are held: which
// blocker forbids one, how the worker's terminal reason becomes an outcome, and what the
// progress bar may claim.
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/video_import_ops.dart';

VideoImportBlocker? blocker({
  bool available = true,
  bool supported = true,
  bool controllerReady = true,
  CaptureActivity activity = CaptureActivity.idle,
  bool regenerating = false,
}) {
  return resolveVideoImportBlocker(
    available: available,
    supported: supported,
    controllerReady: controllerReady,
    activity: activity,
    regenerating: regenerating,
  );
}

/// The blocker this gate answers for [activity], for every activity there is.
///
/// An exhaustive switch, not a table, and it is the point of this stage: a fifth thing that can run
/// is a compile error here as well as in the resolver, so it cannot be added without someone
/// deciding what an import should do about it.
VideoImportBlocker? _expectedFor(CaptureActivity activity) => switch (activity) {
  CaptureActivity.idle => null,
  CaptureActivity.capturing => VideoImportBlocker.capturing,
  CaptureActivity.pickingClip => VideoImportBlocker.picking,
  CaptureActivity.importing => VideoImportBlocker.importing,
};

void main() {
  group('resolveVideoImportBlocker', () {
    test('nothing blocks a ready front end', () {
      expect(blocker(), isNull);
    });

    test('a desktop build reports the feature as unavailable, not merely unsupported', () {
      // The two are different answers with different UI: `unavailable` renders no control at all,
      // `unsupported` renders a disabled one with a reason.
      expect(blocker(available: false), VideoImportBlocker.unavailable);
      expect(blocker(supported: false), VideoImportBlocker.unsupported);
    });

    test('a live capture blocks an import', () {
      // Courtesy only -- the core refuses the cross-kind start under its own mutex -- but a user must
      // not be able to walk into that refusal.
      expect(blocker(activity: CaptureActivity.capturing), VideoImportBlocker.capturing);
    });

    test('every running feature names ITSELF as the reason, and never another one', () {
      // THE POINT OF THIS STAGE. Before it, "what is running" reached this gate as two booleans read
      // a second time from the same providers `resolveCaptureActivity` reads, and one of them
      // (`isBusy`) had already merged an open file dialog into "an import is running" -- so the
      // control refused a user standing in the file picker with 「動画の取り込み中です。」, a
      // sentence about a decode that had not begun. A gate that stops refusing is caught by the case
      // above; a gate that refuses under the WRONG NAME is caught only here, so this asserts the
      // whole mapping rather than the presence of a blocker.
      for (final activity in CaptureActivity.values) {
        expect(blocker(activity: activity), _expectedFor(activity), reason: '$activity');
      }
    });

    test('an open file dialog is told apart from a running decode', () {
      // The two are one rule and two sentences, exactly as `CaptureActivity` splits them. Written
      // out separately from the loop above so that collapsing the two arms back into one value
      // fails by name here as well as inside the loop.
      expect(blocker(activity: CaptureActivity.pickingClip), VideoImportBlocker.picking);
      expect(blocker(activity: CaptureActivity.importing), VideoImportBlocker.importing);
      expect(VideoImportBlocker.picking, isNot(VideoImportBlocker.importing));
    });

    test('a regeneration batch blocks an import', () {
      // THE GATE THE CORE CANNOT HOLD. `NativeApi::updateRecord` is fire-and-forget with no completion
      // tracking, and the worker's `updateState` is null between two records of one batch, so neither
      // can refuse on the batch's behalf. Starting an import rebuilds the pipeline the regeneration is
      // riding and the regeneration silently loses its work; this predicate is the only thing that
      // stops it, which is why it is tested here rather than trusted to a disabled button.
      expect(blocker(regenerating: true), VideoImportBlocker.regenerating);
    });

    test('an import blocks a second import', () {
      expect(blocker(activity: CaptureActivity.importing), VideoImportBlocker.importing);
    });

    test('the reason shown is the most fundamental one', () {
      // Precedence matters because the UI explains exactly one: telling a user on an unsupported
      // browser to "wait for the regeneration" would send them to wait for nothing.
      expect(
        blocker(
          available: false,
          supported: false,
          controllerReady: false,
          activity: CaptureActivity.capturing,
          regenerating: true,
        ),
        VideoImportBlocker.unavailable,
      );
      expect(
        blocker(supported: false, controllerReady: false, activity: CaptureActivity.capturing, regenerating: true),
        VideoImportBlocker.unsupported,
      );
      expect(
        blocker(controllerReady: false, activity: CaptureActivity.capturing, regenerating: true),
        VideoImportBlocker.notReady,
      );
      // A live capture outranks a regeneration, as it did before the activity became one value: the
      // one overlap of the two that is reachable at all, and its answer is unchanged.
      expect(blocker(activity: CaptureActivity.capturing, regenerating: true), VideoImportBlocker.capturing);
      expect(blocker(regenerating: true), VideoImportBlocker.regenerating);
    });

    test('a regeneration is still refused while nothing else is running -- the gate the core cannot hold', () {
      // What `VideoImportButton._preflight` asks after the file dialog closes, spelled as the
      // activity it actually passes: its OWN picking state left out, everything else in. The
      // regeneration this gate exists for must survive that exclusion -- an import that started
      // anyway would rebuild the pipeline underneath a running batch.
      expect(blocker(activity: CaptureActivity.idle, regenerating: true), VideoImportBlocker.regenerating);
      expect(blocker(activity: CaptureActivity.capturing, regenerating: false), VideoImportBlocker.capturing);
      expect(blocker(activity: CaptureActivity.idle, regenerating: false), isNull);
    });
  });

  group('videoImportOutcomeKind', () {
    test('maps the worker reasons the protocol defines', () {
      expect(videoImportOutcomeKind('completed'), VideoImportOutcomeKind.completed);
      expect(videoImportOutcomeKind('cancelled'), VideoImportOutcomeKind.cancelled);
      expect(videoImportOutcomeKind('refused'), VideoImportOutcomeKind.refused);
      expect(videoImportOutcomeKind('failed'), VideoImportOutcomeKind.failed);
    });

    test('an unbraked import is a failure, not a refusal', () {
      // The session had already started, so it is not a request that could not be served; and there is
      // nothing the user can do about it that differs from any other failure.
      expect(videoImportOutcomeKind('unbraked'), VideoImportOutcomeKind.failed);
    });

    test('an unknown reason is a failure rather than a crash', () {
      expect(videoImportOutcomeKind('something-new'), VideoImportOutcomeKind.failed);
    });
  });

  group('videoImportFraction', () {
    test('is media time over duration, both from the container', () {
      expect(videoImportFraction((decoded: 120, supplied: 120, mediaTimeMs: 5000, durationMs: 20000)), 0.25);
    });

    test('is indeterminate while the clip declares no duration', () {
      // A clip can report its duration late (or never). Reporting a fraction from the frame counts
      // instead would invent a denominator: nothing knows how many frames a clip has until it ends.
      //
      // `durationMs: 0` is the real shape: the worker always sends both fields as numbers and sends
      // 0 for a duration the container does not declare. The nulls are parse tolerance for a field
      // that arrives absent or non-numeric, and mean exactly the same thing here.
      expect(videoImportFraction((decoded: 0, supplied: 0, mediaTimeMs: 0, durationMs: 0)), isNull);
      expect(videoImportFraction((decoded: 120, supplied: 120, mediaTimeMs: 5000, durationMs: 0)), isNull);
      expect(videoImportFraction((decoded: 120, supplied: 120, mediaTimeMs: 5000, durationMs: null)), isNull);
      expect(videoImportFraction((decoded: 120, supplied: 120, mediaTimeMs: null, durationMs: 20000)), isNull);
      expect(videoImportFraction(null), isNull);
    });

    test('tolerates a denominator that changes once, mid-import', () {
      // A clip that declares no duration reports 0 until a background scan lands one, so the bar
      // goes from indeterminate to determinate while the same import runs. Nothing here is
      // cumulative, so each report is answered on its own terms.
      expect(videoImportFraction((decoded: 30, supplied: 30, mediaTimeMs: 1000, durationMs: 0)), isNull);
      expect(videoImportFraction((decoded: 60, supplied: 60, mediaTimeMs: 2000, durationMs: 8000)), 0.25);
    });

    test('clamps a last frame that runs past the declared duration', () {
      // Not defensive: mediabunny documents a container's declared duration as possibly approximate,
      // so an under-declaring clip really does report a last frame past its own end.
      expect(videoImportFraction((decoded: 1, supplied: 1, mediaTimeMs: 21000, durationMs: 20000)), 1.0);
      expect(videoImportFraction((decoded: 1, supplied: 1, mediaTimeMs: -500, durationMs: 20000)), 0.0);
    });
  });

  group('videoImportBlockerKey', () {
    test('translates the camelCase enum into the snake_case the translation file uses', () {
      // The two vocabularies do not agree, and easy_localization renders a missing key AS THE KEY:
      // `blocker.name` looked up `blocked.notReady`, which does not exist, so the tile and the
      // button tooltip showed `pages.capture.video_import.blocked.notReady` to every user for the
      // seconds-long window in which the pipeline is still starting -- an ordinary path on every web
      // page load. Nothing warns; only a rendered-string assertion catches it.
      expect(videoImportBlockerKey(VideoImportBlocker.notReady), 'not_ready');
    });

    test('gives every blocker a key, so a new one cannot ship without a line', () {
      final keys = {for (final blocker in VideoImportBlocker.values) videoImportBlockerKey(blocker)};
      expect(keys, hasLength(VideoImportBlocker.values.length));
      expect(keys.every((key) => key == key.toLowerCase()), isTrue);
    });
  });

  group('VideoImportState', () {
    test('an open file dialog is busy but does not own the pipeline', () {
      // The dialog is modal to the user and not to the app: treating it as a running session would
      // disable live capture for as long as a user stands in it, for a session that may never start.
      const picking = VideoImportState(phase: VideoImportPhase.picking);
      expect(picking.isBusy, isTrue);
      expect(picking.isRunning, isFalse);
      expect(picking.isCancellable, isFalse);
    });

    test('a running import owns the pipeline and can be cancelled', () {
      for (final phase in [VideoImportPhase.starting, VideoImportPhase.importing]) {
        final state = VideoImportState(phase: phase);
        expect(state.isRunning, isTrue);
        expect(state.isBusy, isTrue);
        expect(state.isCancellable, isTrue);
      }
    });

    test('a cancel in flight still owns the pipeline but cannot be cancelled twice', () {
      const cancelling = VideoImportState(phase: VideoImportPhase.cancelling);
      expect(cancelling.isRunning, isTrue);
      expect(cancelling.isCancellable, isFalse);
    });

    test('a finished import releases every gate', () {
      const finished = VideoImportState(
        phase: VideoImportPhase.finished,
        outcome: VideoImportOutcome(kind: VideoImportOutcomeKind.completed),
      );
      expect(finished.isRunning, isFalse);
      expect(finished.isBusy, isFalse);
      expect(finished.isCancellable, isFalse);
      expect(VideoImportState.idle.isBusy, isFalse);
    });

    test('the state carries the fraction the progress bar renders', () {
      const state = VideoImportState(
        phase: VideoImportPhase.importing,
        progress: (decoded: 10, supplied: 9, mediaTimeMs: 1000, durationMs: 4000),
      );
      expect(state.fraction, 0.25);
      expect(const VideoImportState(phase: VideoImportPhase.importing).fraction, isNull);
    });
  });
}
