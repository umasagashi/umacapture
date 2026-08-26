// What happens to the shared capture state when a capture session is ended by *tearing the controller
// down* instead of by the stop button.
// Run: .fvm/flutter_sdk/bin/flutter test test/platform_controller_dispose_test.dart
//
// This is the regression guard for a defect that wedged web live capture: a controller rebuild (a module
// install invalidates `moduleVersionLoader`, which `platformControllerLoader` watches) disposed the
// platform channel, which on web *is* the session — and nothing announced the end. `capturingStateProvider`
// stayed true for the rest of the page load, so the button was stuck on "stop", the preview tile froze on
// its last frame, and the stop press went to a freshly built channel with no session to end. Only a page
// reload recovered.
//
// The reaction is deliberately in shared code (`PlatformController.dispose`) rather than in the web
// channel, for two reasons. It is the only place both platforms pass through, so they cannot drift; and it
// is the only place a test can reach at all — `platform_channel_web.dart` imports `dart:js_interop` and
// cannot be compiled on the VM. `debugDisposeEndsCaptureSession` stands in for the answer that channel
// gives, so the reaction is driven through the real `ref.onDispose` life-cycle rather than by hand. That
// life-cycle is the whole difficulty: riverpod forbids reading another provider from inside it.
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/core/capture_preview.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';

import 'support/hive.dart';

/// Stands in for `platformControllerLoader`: it builds a controller and, exactly as the real loader does,
/// hands `dispose` to `ref.onDispose`. Invalidating it reproduces the module-install rebuild without the
/// loader's module-version / asset-bundle / storage dependencies.
///
/// [_disposeEndsSession] is what the web channel would answer; the desktop default is false.
bool _disposeEndsSession = true;

final _controllerHarness = Provider<PlatformController>((ref) {
  final controller = PlatformController(ref, const {})..debugDisposeEndsCaptureSession = _disposeEndsSession;
  ref.onDispose(controller.dispose);
  return controller;
});

/// A 1x1 image standing in for a decoded preview frame.
Future<ui.Image> _tinyImage() {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder);
  return recorder.endRecording().toImage(1, 1);
}

/// Lets the module-level capture event stream (broadcast, asynchronous delivery), the disposal microtask
/// and riverpod's own timer-scheduled rebuild all settle.
Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Future<void> Function() closeHive;

  setUpAll(() async {
    closeHive = await initHiveForTest(['settings']);
  });

  tearDownAll(() async {
    await closeHive();
  });

  setUp(() async {
    await Hive.box('settings').clear();
    _disposeEndsSession = true;
    // The controller pushes its initial config over the method channel from its constructor; answer it so
    // the fire-and-forget call does not surface as a failure toast.
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

  group('a capture session ended by disposing the controller', () {
    test('returns the capture state to idle and accepts a new start', () async {
      final container = ProviderContainer.test();
      // Subscribe before the first event: the capture flag travels on a broadcast stream with no
      // buffering, exactly as it does in the app, where the capture page is mounted throughout.
      container.listen(capturingStateProvider, (_, _) {});
      final controller = container.read(_controllerHarness);
      container.listen(_controllerHarness, (_, _) {});

      controller.handleNativeMessage(jsonEncode({'type': 'onCaptureStarted'}));
      await _settle();
      expect(container.read(capturingStateProvider), isTrue, reason: 'precondition: a session is running');

      // The rebuild. `ref.onDispose` runs the controller's dispose from inside riverpod's life-cycle.
      container.invalidate(_controllerHarness);
      await _settle();

      expect(
        container.read(capturingStateProvider),
        isFalse,
        reason: 'a session the teardown ended must not leave the button stuck on "stop"',
      );

      // ...and the state accepts a start again, from the controller that replaced the disposed one.
      final rebuilt = container.read(_controllerHarness);
      expect(identical(rebuilt, controller), isFalse, reason: 'precondition: the provider really rebuilt');
      rebuilt.handleNativeMessage(jsonEncode({'type': 'onCaptureStarted'}));
      await _settle();
      expect(container.read(capturingStateProvider), isTrue, reason: 'a subsequent start must be possible');
    });

    test('releases the session-scoped state the stop button releases', () async {
      final container = ProviderContainer.test();
      container.listen(capturingStateProvider, (_, _) {});
      container.listen(capturePreviewFrameProvider, (_, _) {});
      // Mounts the notifier in the module-level slot the frame producers publish through.
      container.read(capturePreviewFrameProvider.notifier);
      final controller = container.read(_controllerHarness);
      container.listen(_controllerHarness, (_, _) {});

      controller.handleNativeMessage(jsonEncode({'type': 'onCaptureStarted'}));
      controller.handleNativeMessage(
        jsonEncode({
          'type': 'onFrameSizeReported',
          'size': {'width': 640, 'height': 360},
        }),
      );
      controller.handleNativeMessage(jsonEncode({'type': 'onFrameRateReported', 'fps': 30.0}));
      publishCapturePreviewImage(await _tinyImage());
      await _settle();
      expect(container.read(capturePreviewFrameProvider).image, isNotNull, reason: 'precondition: a frame is shown');

      container.invalidate(_controllerHarness);
      await _settle();

      expect(
        container.read(capturePreviewFrameProvider).image,
        isNull,
        reason: 'the tile must not freeze on the last frame of a session that ended',
      );
      expect(container.read(capturingFrameSizeProvider), isNull);
      expect(container.read(capturingFrameRateProvider), isNull);
    });

    test('is not announced on desktop, where the native session outlives the channel', () async {
      _disposeEndsSession = false;
      final container = ProviderContainer.test();
      container.listen(capturingStateProvider, (_, _) {});
      final controller = container.read(_controllerHarness);
      container.listen(_controllerHarness, (_, _) {});

      controller.handleNativeMessage(jsonEncode({'type': 'onCaptureStarted'}));
      await _settle();
      expect(container.read(capturingStateProvider), isTrue);

      container.invalidate(_controllerHarness);
      await _settle();

      expect(
        container.read(capturingStateProvider),
        isTrue,
        reason: 'the desktop runner keeps capturing across a controller rebuild, so the flag is still true',
      );
    });
  });
}
