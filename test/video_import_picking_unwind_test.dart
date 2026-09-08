// THE ONE INVARIANT THIS FILE EXISTS FOR: when `startVideoImport` returns or throws, the import is
// over — `VideoImportState.isBusy` is false — whatever happened in between.
// Run: .fvm/flutter_sdk/bin/flutter test test/video_import_picking_unwind_test.dart
//
// Why it is worth its own file rather than another case in `video_import_io_test.dart`: that file is
// about the wire and the outcome vocabulary, and every case in it drives a stretch that behaves. This
// one drives the stretch that does not. Between the `picking` write and the terminal one,
// `startVideoImport` awaits a plugin dialog, reads a file name, asks the gate again and posts to a
// channel; `_state` is a process-wide singleton, so a throw that escaped that stretch used to leave the
// front end busy for the rest of the app's life. And `picking` is not an inert waiting room: it answers
// `CaptureActivity.pickingClip`, which withdraws live capture, the import control and **both**
// error-report links — so the stranded state took all four features of the capture card with it, and the
// only reset in the code (`debugResetVideoImport`) is `@visibleForTesting`.
//
// The web leg carries the same `finally` and cannot be reached from here (it imports `package:web`, so
// the VM cannot compile it). What holds it to this shape is review and the twin comment, not this file.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/platform_channel_io.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/video_import_io.dart';
import 'package:umacapture/src/core/video_import_ops.dart';

const _path = r'C:\clips\2026-08-08 race.mkv';

/// The gate's own failure, chosen because it is the trigger that is actually reachable: `preflight`
/// reads through a `ProviderContainer` (`gui/video_import.dart`), and a read against a disposed
/// container throws. That second call is made *after* the dialog has closed and is outside every `try`
/// in the function, which is precisely the shape this file pins.
class _DisposedContainer implements Exception {
  const _DisposedContainer();

  @override
  String toString() => 'Bad state: Tried to read a provider from a ProviderContainer that was disposed';
}

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

  final defaultPicker = videoImportPathPicker;
  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    videoImportPathPicker = () async => _path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      (call) async {
        calls.add(call);
        return null;
      },
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      null,
    );
    videoImportPathPicker = defaultPicker;
    // Twice with the queue drained in between, for the reason `video_import_io_test.dart` states: the
    // first release settles a terminal slot a pending `startVideoImport` is awaiting, and that
    // continuation writes into the state after this line.
    debugResetVideoImport();
    await pumpEventQueue();
    debugResetVideoImport();
  });

  group('a throw in the picking stretch cannot strand the front end', () {
    test('the gate throwing after the dialog closed returns the front end to idle', () async {
      // The first call is the one the button already made; the second is the re-check immediately
      // before the path is posted — the one with no `try` around it.
      var asked = 0;

      await expectLater(
        startVideoImport(
          declaration: _declaresNothing,
          preflight: () {
            if (asked++ == 0) {
              return null;
            }
            throw const _DisposedContainer();
          },
        ),
        // THE THROW STILL ESCAPES. The unwind returns the app to a usable state; it must not also
        // swallow the defect, or the developer learns nothing and the user is left with a button that
        // silently does nothing.
        throwsA(isA<_DisposedContainer>()),
      );

      expect(asked, 2, reason: 'the case did not reach the gate re-check it is about');
      expect(calls, isEmpty, reason: 'nothing may be posted for an import that never passed the gate');
      expect(videoImportState.value.phase, VideoImportPhase.idle);
      expect(videoImportState.value.isBusy, isFalse);
    });

    test('and with it every one of the four capture features', () async {
      // The state's phase is the mechanism; this is the consequence, asserted where the user meets it.
      // `pickingClip` is what `gui/capture.dart` turns into `CaptureToggleBlocker.clipPicking` and what
      // withdraws the import button and both report links, so "stuck in picking" and "the capture card
      // is dead" are the same sentence.
      // The gate again, and again on its SECOND call: a `preflight` that throws on the first is refused
      // before `picking` is ever written, so it would prove nothing about the unwind.
      var asked = 0;
      await expectLater(
        startVideoImport(
          declaration: _declaresNothing,
          preflight: () => asked++ == 0 ? null : throw const _DisposedContainer(),
        ),
        throwsA(isA<_DisposedContainer>()),
      );
      expect(asked, 2);
      // A control, in the same run and with the same measuring instrument: the activity this asserts
      // the absence of is one this call can actually produce, and the line below shows it doing so.
      expect(
        resolveCaptureActivity(capturing: false, importState: const VideoImportState(phase: VideoImportPhase.picking)),
        CaptureActivity.pickingClip,
      );

      expect(resolveCaptureActivity(capturing: false, importState: videoImportState.value), CaptureActivity.idle);
    });

    test('a throw the layer already handles keeps its own terminal state, not the unwind\'s', () async {
      // The negative side of the guard: the dialog failing to open is an anticipated failure with its
      // own sentence, and the `finally` must not overwrite it with a silent idle. If this goes green
      // only because the unwind never runs, the first case in this group goes red.
      videoImportPathPicker = () async => throw MissingPluginException('No implementation found for pickFile');

      await startVideoImport(declaration: _declaresNothing, preflight: () => null);

      expect(videoImportState.value.phase, VideoImportPhase.finished);
      expect(videoImportState.value.outcome?.kind, VideoImportOutcomeKind.failed);
      expect(videoImportState.value.outcome?.message, contains('pickFile'));
    });
  });

  group('the negative control: a picker that behaves is untouched by the unwind', () {
    test('a whole import still reaches its outcome', () async {
      final running = startVideoImport(declaration: _declaresNothing, preflight: () => null);
      await pumpEventQueue();

      expect(videoImportState.value.phase, VideoImportPhase.starting);
      expect(calls.single.method, 'startVideoImport');

      videoImportHandleNativeEvent(<String, dynamic>{'type': 'videoImportStarted'});
      videoImportHandleNativeEvent(<String, dynamic>{
        'type': 'videoImportDone',
        'reason': 'completed',
        'decoded': 3,
        'supplied': 3,
      });
      await running;

      expect(videoImportState.value.phase, VideoImportPhase.finished);
      expect(videoImportState.value.outcome?.kind, VideoImportOutcomeKind.completed);
      expect(videoImportState.value.outcome?.supplied, 3);
    });

    test('a dismissed dialog is still a silent return to idle', () async {
      videoImportPathPicker = () async => null;

      await startVideoImport(declaration: _declaresNothing, preflight: () => null);

      expect(videoImportState.value.phase, VideoImportPhase.idle);
      expect(videoImportState.value.outcome, isNull, reason: 'a cancel earns no result line');
    });
  });
}
