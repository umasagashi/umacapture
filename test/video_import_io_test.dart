// The Windows video-import front end (`video_import_io.dart`) and the two method-channel calls it
// posts, driven end to end on the VM: the wire format going out, the runner's three notifications
// coming back, and the one rule that is the whole of this layer's correctness — the terminal
// outcome settles exactly once, and always settles.
// Run: .fvm/flutter_sdk/bin/flutter test test/video_import_io_test.dart
//
// This file reaches the io leg directly rather than through the `video_import.dart` facade. The
// facade resolves to exactly this file on the VM, so the two are the same code — but naming it
// makes the file's subject unambiguous, and it is what lets the picker seam and the reset below be
// touched without exporting them into the shared surface's spelling.
//
// WHAT IT CANNOT COVER, stated here rather than left to be discovered: nothing below the method
// channel exists on the VM. Every assertion about `startVideoImport` stops at the encoded argument
// handed to a mock handler; that the Windows runner decodes it, that the notifications this file
// synthesises are byte-identical to the ones `native_api_messages.h` builds, and that the real file
// dialog yields a path the runner can open are all on-device facts. The dialog in particular is not
// merely uncovered but uncoverable here — see the note in "the file dialog" below.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/platform_channel_io.dart';
// The facade, under a prefix, for the one case that is about the conditional export itself rather
// than about this leg: everything the app imports goes through it, so "the io leg is correct" is
// only worth anything if the export actually selects it.
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/video_import.dart' as facade;
import 'package:umacapture/src/core/video_import_io.dart';
import 'package:umacapture/src/core/video_import_ops.dart';

const _path = r'C:\clips\2026-08-08 race.mkv';

/// One `videoImportDone` with every field the runner actually sends, so a case that varies a field
/// varies exactly one thing.
Map<String, dynamic> _done({
  String reason = 'completed',
  String reasonKind = '',
  int decoded = 121,
  int supplied = 119,
  int rejected = 2,
}) => <String, dynamic>{
  'type': 'videoImportDone',
  'reason': reason,
  'reasonKind': reasonKind,
  'decoded': decoded,
  'supplied': supplied,
  'rejected': rejected,
  'durationMs': 10000,
  'matrixConverted': '',
  'message': '',
};

/// What these cases announce to the long-read registry: nothing, and why.
///
/// They drive the front end's own state machine over a method channel, with no provider
/// container anywhere in reach; what the session holds is asserted in
/// `video_import_long_read_claim_test.dart`, which builds a real claim instead.
const _declaresNothing = LongReadDeclaration.none(
  reason: 'this suite drives the import front end directly; the registry is another suite\'s subject',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Captured before the first test replaces it, purely so `tearDown` can put the real dialog back
  // rather than leaving one test's fake installed for the rest of the process. It is never *called*:
  // the default opens a modal Win32 dialog (see "the file dialog" below).
  final defaultPicker = videoImportPathPicker;

  late List<MethodCall> calls;
  Future<Object?> Function(MethodCall call)? answer;

  setUp(() {
    calls = <MethodCall>[];
    answer = null;
    videoImportPathPicker = () async => _path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      (call) async {
        calls.add(call);
        return answer == null ? null : await answer!(call);
      },
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      null,
    );
    videoImportPathPicker = defaultPicker;
    // Twice, with the queue drained in between: the first release settles a terminal slot a pending
    // `startVideoImport` is awaiting, and that continuation writes `finished` into the state after
    // this line — so the second call is what actually leaves the next test at idle.
    debugResetVideoImport();
    await pumpEventQueue();
    debugResetVideoImport();
  });

  /// Starts an import and lets the picker future and the channel post settle, leaving the front end
  /// in `starting` with the runner's acknowledgement still outstanding.
  /// The pending call is returned inside a record, not bare: an `async` helper that returned it
  /// directly would await it, which is the one thing this must not do.
  Future<({Future<void> running})> startAndSettle() async {
    final running = startVideoImport(declaration: _declaresNothing, preflight: () => null);
    await pumpEventQueue();
    return (running: running);
  }

  group('the capability answers', () {
    test('the import path is Windows-only, not "any non-web build"', () {
      // The conditional export sends macOS, Linux, Android and iOS here too, and none of them has a
      // native import session. Asserted against the host rather than hard-coded so this states the
      // rule instead of the machine it happens to run on.
      expect(videoImportAvailable, Platform.isWindows);
    });

    test('the conditional export selects this leg, not the stub', () {
      // The whole app reads the facade, never this file. The stub answers a constant `false` and the
      // io leg answers `Platform.isWindows`, so on a Windows host the two are distinguishable — and
      // this is the assertion that fails if the export condition is ever written wrong. On any other
      // host both legs answer `false` and this can only state that much.
      expect(facade.videoImportAvailable, videoImportAvailable);
      if (Platform.isWindows) {
        expect(facade.videoImportAvailable, isTrue, reason: 'the facade still resolved to the stub');
      }
      // Reached through the facade so the sixth member is part of the *shared* surface stage ε will
      // call, not just of this file's.
      facade.videoImportHandleNativeEvent(<String, dynamic>{'type': 'videoImportStarted'});
    });

    test('a front end with an import path can also decode', () {
      // Unlike web, where the second question is a genuine runtime probe: the runner links its
      // decoder statically, so there is nothing left to feature-test.
      expect(videoImportSupported, videoImportAvailable);
    });
  });

  group('the wire format going out', () {
    test('startVideoImport posts the path as a JSON object', () async {
      await PlatformChannel.startVideoImport(_path);

      expect(calls.single.method, 'startVideoImport');
      // A JSON *string*, because the runner's dispatcher reads every argument as a std::string.
      expect(calls.single.arguments, isA<String>());
      expect(jsonDecode(calls.single.arguments as String), <String, dynamic>{'path': _path});
    });

    test('cancelVideoImport posts no argument at all', () async {
      await PlatformChannel.cancelVideoImport();

      expect(calls.single.method, 'cancelVideoImport');
      expect(calls.single.arguments, isNull);
    });
  });

  group('one whole import', () {
    test('the runner\'s three messages drive the state through to an outcome', () async {
      final running = (await startAndSettle()).running;

      expect(jsonDecode(calls.single.arguments as String), <String, dynamic>{'path': _path});
      expect(videoImportState.value.phase, VideoImportPhase.starting);
      // The label is the file's name, not the whole path.
      expect(videoImportState.value.fileName, '2026-08-08 race.mkv');

      videoImportHandleNativeEvent(<String, dynamic>{'type': 'videoImportStarted'});
      videoImportHandleNativeEvent(<String, dynamic>{
        'type': 'videoImportProgress',
        'decoded': 120,
        'supplied': 118,
        'mediaTimeMs': 5000,
        'durationMs': 10000,
      });

      expect(videoImportState.value.phase, VideoImportPhase.importing);
      expect(videoImportState.value.progress?.supplied, 118);
      expect(videoImportState.value.fraction, 0.5);

      videoImportHandleNativeEvent(_done());
      await running;

      final outcome = videoImportState.value.outcome;
      expect(videoImportState.value.phase, VideoImportPhase.finished);
      expect(outcome?.kind, VideoImportOutcomeKind.completed);
      expect(outcome?.decoded, 121);
      expect(outcome?.supplied, 119);
      expect(outcome?.rejected, 2);
      // The progress bar is not left behind by the ending.
      expect(videoImportState.value.progress, isNull);
    });

    test('a cancel is posted and keeps its own phase until the terminal message', () async {
      final running = (await startAndSettle()).running;
      videoImportHandleNativeEvent(<String, dynamic>{'type': 'videoImportStarted'});

      cancelVideoImport();
      await pumpEventQueue();

      expect(videoImportState.value.phase, VideoImportPhase.cancelling);
      expect(calls.map((call) => call.method), contains('cancelVideoImport'));

      // Frames still trickle through while the decode loop reaches its next boundary; the phase must
      // not fall back to `importing` under them.
      videoImportHandleNativeEvent(<String, dynamic>{
        'type': 'videoImportProgress',
        'decoded': 130,
        'supplied': 128,
        'mediaTimeMs': 6000,
        'durationMs': 10000,
      });
      expect(videoImportState.value.phase, VideoImportPhase.cancelling);

      videoImportHandleNativeEvent(_done(reason: 'cancelled'));
      await running;

      expect(videoImportState.value.phase, VideoImportPhase.finished);
      expect(videoImportState.value.outcome?.kind, VideoImportOutcomeKind.cancelled);
    });
  });

  group('the terminal outcome settles exactly once, and always settles', () {
    test('a second videoImportDone cannot rewrite the first', () async {
      final running = (await startAndSettle()).running;
      videoImportHandleNativeEvent(_done(decoded: 10, supplied: 10, rejected: 0));
      await running;
      final settled = videoImportState.value.outcome;

      videoImportHandleNativeEvent(_done(reason: 'failed', decoded: 999, supplied: 0, rejected: 999));

      expect(videoImportState.value.outcome, same(settled));
      expect(videoImportState.value.outcome?.decoded, 10);
      expect(videoImportState.value.outcome?.kind, VideoImportOutcomeKind.completed);
    });

    test('a terminal message with no import awaiting it changes nothing', () async {
      // The two sides disagreeing about whether an import is running is reported, not acted on: a
      // stray ending must not put the front end into `finished` and claim counts it did not produce.
      videoImportHandleNativeEvent(_done());

      expect(videoImportState.value.phase, VideoImportPhase.idle);
      expect(videoImportState.value.outcome, isNull);
    });

    test('a post that throws ends the import instead of leaving it running forever', () async {
      // No handler, a runner that threw before it could answer: nothing else would ever settle the
      // terminal slot, and the capture button would stay disabled for the life of the process.
      answer = (call) => throw PlatformException(code: 'no_runner', message: 'boom');

      await startVideoImport(declaration: _declaresNothing, preflight: () => null);

      final outcome = videoImportState.value.outcome;
      expect(videoImportState.value.phase, VideoImportPhase.finished);
      expect(outcome?.kind, VideoImportOutcomeKind.refused);
      expect(outcome?.reason, VideoImportReason.neverStarted);
    });

    test('the producer\'s own sentence survives a post that threw, instead of a restated reason', () async {
      // WHAT THE ERROR REPORT'S ONE FREE-TEXT FIELD SAYS. `VideoImportOutcome.message` is published to
      // Sentry verbatim as `import.message` (`buildImportErrorReportScope`), and this path used to settle
      // `VideoImportSlots.release()`'s constant — 'the import never started' — which only restates
      // `reason: neverStarted`. The text that is actually diagnostic is the runner's:
      // `windows/runner/video_import_session.h` answers `"startVideoImport failed: " + e.what()`, and the
      // developer reading that issue has nothing else to go on but the breadcrumb.
      answer = (call) => throw PlatformException(code: 'no_runner', message: 'CreateFile: access denied');

      await startVideoImport(declaration: _declaresNothing, preflight: () => null);

      final message = videoImportState.value.outcome?.message;
      expect(message, contains('CreateFile: access denied'));
      // Not merely "the cause is in there somewhere": the constant must be gone, or an implementation
      // that appends the cause to it would pass while still spending the field on a restated reason.
      expect(message, isNot(contains('the import never started')));
      // The classification is unchanged — this is about the message, not about the outcome's vocabulary.
      expect(videoImportState.value.outcome?.reason, VideoImportReason.neverStarted);
      expect(videoImportState.value.outcome?.kind, VideoImportOutcomeKind.refused);
    });
  });

  group('the terminal message is parsed tolerantly', () {
    test('a videoImportDone with no fields at all still ends the import', () async {
      // This is the message the front end stops waiting on: a malformed one must end the import
      // rather than throw out of the dispatch and leave it running.
      final running = (await startAndSettle()).running;
      videoImportHandleNativeEvent(<String, dynamic>{'type': 'videoImportDone'});
      await running;

      final outcome = videoImportState.value.outcome;
      expect(outcome?.kind, VideoImportOutcomeKind.failed);
      expect(outcome?.reason, isNull);
      expect(outcome?.decoded, 0);
      expect(outcome?.supplied, 0);
    });

    test('a named reason is carried through to the front end', () async {
      final running = (await startAndSettle()).running;
      videoImportHandleNativeEvent(_done(reason: 'refused', reasonKind: 'not_a_video', decoded: 0, supplied: 0));
      await running;

      expect(videoImportState.value.outcome?.kind, VideoImportOutcomeKind.refused);
      expect(videoImportState.value.outcome?.reason, VideoImportReason.notAVideo);
    });

    test('a reason kind this build does not know degrades to the generic line', () async {
      // A runner newer than this build. Null rather than a throw or an enum name on screen.
      final running = (await startAndSettle()).running;
      videoImportHandleNativeEvent(_done(reason: 'refused', reasonKind: 'invented_next_year'));
      await running;

      expect(videoImportState.value.outcome?.kind, VideoImportOutcomeKind.refused);
      expect(videoImportState.value.outcome?.reason, isNull);
    });

    test('a progress report with a garbled payload does not throw', () async {
      final running = (await startAndSettle()).running;
      videoImportHandleNativeEvent(<String, dynamic>{
        'type': 'videoImportProgress',
        'decoded': 'twelve',
        'durationMs': null,
      });

      expect(videoImportState.value.progress?.decoded, 0);
      expect(videoImportState.value.fraction, isNull, reason: 'an unknown denominator is an indeterminate bar');

      videoImportHandleNativeEvent(_done());
      await running;
    });
  });

  group('the preflight gate', () {
    test('a blocker before the dialog posts nothing and says nothing', () async {
      // The button was already disabled for this; there is nothing to explain that the page is not
      // showing one line higher.
      await startVideoImport(declaration: _declaresNothing, preflight: () => VideoImportBlocker.capturing);

      expect(calls, isEmpty);
      expect(videoImportState.value.phase, VideoImportPhase.idle);
    });

    test('a blocker that arrives while the dialog is open refuses the import by name', () async {
      // THE GATE THE CORE CANNOT HOLD. A regeneration batch auto-starts after a module update, which
      // is exactly the kind of thing that begins while the user is standing in the file dialog.
      var asked = 0;
      await startVideoImport(
        declaration: _declaresNothing,
        preflight: () => asked++ == 0 ? null : VideoImportBlocker.regenerating,
      );

      expect(asked, 2, reason: 'the gate is re-evaluated immediately before the path is posted');
      expect(calls, isEmpty, reason: 'the path reached the runner despite the gate');
      final outcome = videoImportState.value.outcome;
      expect(outcome?.kind, VideoImportOutcomeKind.refused);
      expect(outcome?.blocker, VideoImportBlocker.regenerating);
    });

    test('a dialog the user dismissed returns to idle without a result line', () async {
      videoImportPathPicker = () async => null;

      await startVideoImport(declaration: _declaresNothing, preflight: () => null);

      expect(calls, isEmpty);
      expect(videoImportState.value.phase, VideoImportPhase.idle);
      expect(videoImportState.value.outcome, isNull);
    });
  });

  group('the file dialog', () {
    // THE REAL PICKER IS NEVER CALLED IN THIS FILE, and that is a constraint rather than an omission.
    // `package:file_picker`'s Windows backend spawns an isolate and calls `GetOpenFileNameW`, so
    // invoking the default would open a modal dialog on whatever machine is running the suite and
    // wait for a human — a hung run, not a failed one. What is pinnable on the VM is everything on
    // this side of the seam: the three answers a picker can give and what each does to the state.
    // That the dialog filters `.mkv`, that it returns an absolute path, and that the path it returns
    // is one `cv::VideoCapture` can open are on-device facts (design 8.0, stage ι).
    test('a dialog that failed to open ends as a failed import rather than a silent no-op', () async {
      // The Windows dialog is a plugin call — an unregistered platform instance, a spawn that fails,
      // a `comdlg32.dll` that will not load — and every one of those leaves no window on screen. Web
      // returns to idle for its own dialog because a throw there means a broken document; here a
      // silent idle is indistinguishable from a button that does nothing, so it is reported.
      videoImportPathPicker = () async => throw MissingPluginException('No implementation found for pickFile');

      await startVideoImport(declaration: _declaresNothing, preflight: () => null);

      expect(calls, isEmpty);
      expect(videoImportState.value.phase, VideoImportPhase.finished);
      expect(videoImportState.value.outcome?.kind, VideoImportOutcomeKind.failed);
      expect(videoImportState.value.outcome?.message, contains('pickFile'));
    });

    test('a picked path is handed to the runner exactly as the dialog gave it', () async {
      // Verbatim, with its backslashes and its spaces: the runner opens this string with
      // `cv::VideoCapture`, so anything this side normalised would be a different file — and nothing
      // but the path crosses, because a recording is routinely gigabytes.
      videoImportPathPicker = () async => _path;

      final running = (await startAndSettle()).running;

      expect(jsonDecode(calls.single.arguments as String), <String, dynamic>{'path': _path});
      videoImportHandleNativeEvent(_done());
      await running;
    });
  });
}
