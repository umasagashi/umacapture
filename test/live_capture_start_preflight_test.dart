// The live-capture start preflight -- the second evaluation of the capture gate, made at the moment
// the browser's source picker resolves.
//
//   .fvm/flutter_sdk/bin/flutter test test/live_capture_start_preflight_test.dart
//
// WHAT THESE CASES ARE TRYING TO FALSIFY, in one sentence: *a web live capture begins writing
// records into a store that another job took while the share picker was open.*
//
// WHY IT HAS TO EXIST AT ALL. The toggle's own gate is resolved in `build`
// (`capture_toggle_reason_test.dart` owns that half) and the session's claim is taken when the core
// reports it capturing (`live_capture_long_read_claim_test.dart` owns that one). Between the two
// sits `getDisplayMedia`, which is open for as long as the user takes to choose a window, and
// nothing was asking the question across it. An enhancement merge is exactly the job that can start
// there: it owns the record root for its snapshot, rewrite and delete.
//
// WHAT THIS FILE DOES NOT REACH, and it is the larger half:
//  * The browser. `startCapture` on the web leg is the caller, and under `flutter test`
//    `platform_channel.dart` resolves to the io leg on the VM, so no case here executes the guard
//    that consumes this answer, the refusal it relays, or the track teardown beside it. Verifying
//    that is a manual browser run -- see the commit message.
//  * The press. It would open a real picker, which no test may do, so this asks the function
//    directly, exactly as `VideoImportButton.preflight` is asked by `video_import_gate_test.dart`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/gui/capture.dart';

/// A data root the preflight can ask about. Nothing is written to it: the gate is a question about
/// paths, and no file has to exist for a path to be covered.
final _layout = PathInfo(
  documentDir: DirectoryPath('/tmp/uma_capture_preflight/documents'),
  supportDir: DirectoryPath('/tmp/uma_capture_preflight/support'),
  executableDir: DirectoryPath('/tmp/uma_capture_preflight/exe'),
  downloadDir: DirectoryPath('/tmp/uma_capture_preflight/downloads'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // A real controller pushes its initial config from its constructor; answer it so the
    // fire-and-forget call does not surface as a failure.
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

  /// A container in the state the press left behind: a data root, a controller, nothing held.
  ProviderContainer pressed({bool withController = true}) {
    final container = ProviderContainer.test(
      overrides: [
        // The *layout* and not `pathInfoProvider`, the same reading the control and the session's
        // listener both take: this needs to know where the store is, not that it was prepared.
        pathLayoutProvider.overrideWithValue(_layout),
        if (withController)
          platformControllerProvider.overrideWith((ref) {
            final controller = PlatformController(ref, const {});
            ref.onDispose(controller.dispose);
            return controller;
          })
        else
          platformControllerProvider.overrideWithValue(null),
      ],
    );
    return container;
  }

  test('nothing is in the way once the picker closes, so the session may start', () {
    expect(liveCaptureStartPreflight(pressed()), isNull, reason: 'the arrangement itself must refuse nothing');
  });

  test('a long reader that arrived WHILE THE PICKER WAS OPEN refuses the session', () {
    final container = pressed();
    expect(liveCaptureStartPreflight(container), isNull);

    // Taken after the control was already gated and answered null above -- which is the whole
    // window this function exists for. `merge` and not an arbitrary kind: it is the job the
    // finding was raised about, and it owns the record root for its snapshot, rewrite and delete.
    //
    // The path is READ OFF the session's own derivation rather than written out here: the check and
    // the claim are one list (`liveCaptureLongReadPaths`), and a literal copied into a test would
    // be the one thing that keeps agreeing after that list changes.
    container
        .read(longReadRegistryProvider.notifier)
        .claimUntilReleased(kind: LongReadKind.merge, paths: [liveCaptureLongReadPaths(_layout).first]);

    expect(
      liveCaptureStartPreflight(container),
      CaptureToggleBlocker.longRead,
      reason: 'the session would write records into a tree a merge is rewriting',
    );
  });

  test('a long read elsewhere in the data root leaves the start alone', () {
    final container = pressed();
    // Self-checking: the point of the case is that this path is NOT one the session writes, and a
    // layout change that pulled it in would otherwise turn this into a silent tautology.
    expect(liveCaptureLongReadPaths(_layout), isNot(contains(_layout.downloadDir)));

    container
        .read(longReadRegistryProvider.notifier)
        .claimUntilReleased(kind: LongReadKind.zip, paths: [_layout.downloadDir]);

    expect(liveCaptureStartPreflight(container), isNull, reason: 'a claim anywhere must not refuse a capture');
  });

  test('the hold ending puts the start back, so a slow picker is not fatal', () {
    final container = pressed();
    final token = container
        .read(longReadRegistryProvider.notifier)
        .claimUntilReleased(kind: LongReadKind.merge, paths: [liveCaptureLongReadPaths(_layout).first]);
    expect(liveCaptureStartPreflight(container), CaptureToggleBlocker.longRead);

    container.read(longReadRegistryProvider.notifier).release(token);

    expect(liveCaptureStartPreflight(container), isNull);
  });

  test('a controller that went away while the picker was open refuses too', () {
    expect(liveCaptureStartPreflight(pressed(withController: false)), CaptureToggleBlocker.controllerUnavailable);
  });
}
