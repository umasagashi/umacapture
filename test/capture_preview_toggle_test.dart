// The live capture preview preference: its default, its persistence, and the wiring that pushes it to the
// frame producer.
// Run: .fvm/flutter_sdk/bin/flutter test test/capture_preview_toggle_test.dart
//
// The default is not cosmetic. The preview is what answers "is it actually seeing my game?", and the
// producer only emits while it is on, so shipping it off would mean a first-time user never sees the one
// thing that would tell them their window pick was wrong.
//
// The push matters just as much and in the opposite direction: the preference is persisted and defaults to
// on, so a session that only reacted to CHANGES would start with the producer's own (off) state and stay
// blank until the user toggled the switch twice.
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/core/capture_preview.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/video_import_ops.dart';

import 'support/hive.dart';
import 'support/settling.dart';

/// A controller that records the preview pushes instead of sending them to a platform.
///
/// Subclassed rather than mocked so everything above the platform call -- the loader's `ref.read` +
/// `ref.listen`, and the controller's own signature -- is the real code under test.
class _RecordingController extends PlatformController {
  final pushes = <(bool, bool)>[];

  _RecordingController(Ref ref) : super(ref, const {});

  @override
  Future<void> setCapturePreview(bool enable, bool cropped) async {
    pushes.add((enable, cropped));
  }
}

const _importing = VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv');
const _importFinished = VideoImportState(
  phase: VideoImportPhase.finished,
  fileName: 'clip.mkv',
  outcome: VideoImportOutcome(kind: VideoImportOutcomeKind.completed),
);
const _latchedReport = DetailCropReport(defaultRect: _previewTestRect, correctedRect: _previewTestRect, latched: true);

const _previewTestRect = DetailCropRect(left: 10, top: 20, width: 300, height: 500);

/// Exposes a plain [Ref] from the container, exactly as `platformControllerLoader` hands one over.
final _refProvider = Provider<Ref>((ref) => ref);

/// A 1x1 image standing in for a decoded preview frame.
Future<ui.Image> _tinyImage() {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder);
  return recorder.endRecording().toImage(1, 1);
}

/// Delivers one `previewFrame` method call to the app exactly as the Windows runner does: through the
/// real channel, encoded with the real [StandardMethodCodec].
Future<void> _sendPreviewFrame(Object? arguments) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
    PlatformChannel.channel.name,
    const StandardMethodCodec().encodeMethodCall(MethodCall('previewFrame', arguments)),
    (_) {},
  );
}

/// Gives the preview sink's unawaited decode a bounded number of event-loop turns, for the case that
/// asserts nothing was published. A window is the right shape there: it has no arrival to wait for, and
/// a slow host can only make the negative weaker, never wrong. The case that DOES expect a frame waits
/// on the frame with [waitUntil] instead -- the decode completes on the engine, off this isolate, so no
/// number of turns here is a bound on it.
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

  group('capturePreviewEnabledProvider', () {
    test('defaults to on', () {
      final container = ProviderContainer.test();

      expect(container.read(capturePreviewEnabledProvider), isTrue);
    });

    test('persists a turn-off across containers', () {
      final container = ProviderContainer.test();
      container.read(capturePreviewEnabledProvider.notifier).set(false);

      final reopened = ProviderContainer.test();
      expect(reopened.read(capturePreviewEnabledProvider), isFalse);
    });
  });

  group('listenCapturePreview', () {
    test('pushes the current value once, then every change', () {
      final container = ProviderContainer.test();
      final controller = _RecordingController(container.read(_refProvider));

      listenCapturePreview(container.read(_refProvider), controller);
      expect(controller.pushes, [(true, false)], reason: 'the current pair must reach the producer at startup');

      container.read(capturePreviewEnabledProvider.notifier).toggle();
      container.read(capturePreviewEnabledProvider.notifier).toggle();

      expect(controller.pushes, [(true, false), (false, false), (true, false)]);
    });

    test('pushes a persisted off state at startup', () {
      // The producer's own default is off, so this push is redundant -- but the same call site is what
      // makes the ON case work, and a startup that pushed nothing would be indistinguishable from a
      // startup whose push was lost.
      ProviderContainer.test().read(capturePreviewEnabledProvider.notifier).set(false);

      final container = ProviderContainer.test();
      final controller = _RecordingController(container.read(_refProvider));

      listenCapturePreview(container.read(_refProvider), controller);

      expect(controller.pushes, [(false, false)]);
    });

    test('pushes latch transitions but deduplicates reports with the same latch state', () {
      final container = ProviderContainer.test();
      final controller = _RecordingController(container.read(_refProvider));

      listenCapturePreview(container.read(_refProvider), controller);
      final reports = container.read(detailCropReportProvider.notifier);
      reports.set(
        const DetailCropReport(defaultRect: _previewTestRect, correctedRect: _previewTestRect, latched: false),
      );
      reports.set(
        const DetailCropReport(defaultRect: _previewTestRect, correctedRect: _previewTestRect, latched: true),
      );
      reports.set(
        const DetailCropReport(
          defaultRect: _previewTestRect,
          correctedRect: DetailCropRect(left: 11, top: 20, width: 299, height: 500),
          latched: true,
        ),
      );
      reports.set(null);

      expect(controller.pushes, [(true, false), (true, true), (true, false)]);
    });

    test('mounts the image notifier, so a frame arriving before the tile is built is not dropped', () {
      // The producers publish through a module-level slot rather than a `ref` (they run in the platform
      // channel, which has no container), so the notifier has to exist before the first frame -- not when
      // the user happens to open the capture page.
      final container = ProviderContainer.test();
      final controller = _RecordingController(container.read(_refProvider));

      listenCapturePreview(container.read(_refProvider), controller);

      expect(container.exists(capturePreviewFrameProvider), isTrue);
    });
  });

  group('a video import previews exactly as a live capture does', () {
    // An import that fails has to be able to show WHERE it failed, which is the same thing the preview
    // answers for live capture -- so it rides the same preference, the same producer and the same tile.
    // `debugVideoImportState` is what makes any of it reachable from the VM: `video_import.dart`
    // resolves to the desktop stub here, whose notifier is a constant idle.
    (ProviderContainer, _RecordingController, ValueNotifier<VideoImportState>) wire({
      VideoImportState initial = VideoImportState.idle,
    }) {
      final container = ProviderContainer.test();
      final imports = ValueNotifier<VideoImportState>(initial);
      addTearDown(imports.dispose);
      final controller = _RecordingController(container.read(_refProvider))..debugVideoImportState = imports;
      listenCapturePreview(container.read(_refProvider), controller);
      return (container, controller, imports);
    }

    test('an import expects the UNCROPPED pane state its own frames actually carry', () {
      // THE DEFECT THIS PINS is silent and total. `Module.pushOfflineFrame` shapes AnchorOnly with no pane
      // snapshot, so LivePreviewPolicy sees `actual_cropped == false` for every imported frame -- while the
      // pipeline goes on latching a pane on the consumer side and reporting it. Push the live capture's
      // `latched` during an import and the agreement gate stops publishing from the first latch onwards:
      // the tile simply goes blank, with nothing anywhere saying why.
      final (container, controller, imports) = wire();
      container.read(detailCropReportProvider.notifier).set(_latchedReport);
      expect(controller.pushes, [(true, false), (true, true)]);

      imports.value = _importing;
      expect(controller.pushes.last, (true, false), reason: 'an offline producer never crops');

      // A latch reported *during* the import must not move the expected bit back.
      container.read(detailCropReportProvider.notifier).set(null);
      container.read(detailCropReportProvider.notifier).set(_latchedReport);
      expect(controller.pushes.last, (true, false));

      imports.value = _importFinished;
      expect(controller.pushes.last, (true, true), reason: 'the live producer crops again once the import ends');
    });

    test('the import opens the preview session gate, and closes it when the import ends', () async {
      final (container, _, imports) = wire();

      final orphan = await _tinyImage();
      publishCapturePreviewImage(orphan);
      expect(container.read(capturePreviewFrameProvider).image, isNull, reason: 'no session, no preview');
      expect(orphan.debugDisposed, isTrue);

      imports.value = _importing;
      final shown = await _tinyImage();
      publishCapturePreviewImage(shown);
      expect(container.read(capturePreviewFrameProvider).image, same(shown));

      imports.value = _importFinished;
      expect(container.read(capturePreviewFrameProvider).image, isNull, reason: 'the last frame is stale');
      expect(shown.debugDisposed, isTrue);
    });

    test('a controller built while an import is already running opens the gate at once', () async {
      // The rebuild is routine, not exotic: `platformControllerLoader` watches `moduleVersionLoader` and
      // `platformConfigLoader`, and on Windows the import is a runner-side session that outlives the
      // rebuild. Wiring up from a RUNNING import used to state the pane correctly (the push already reads
      // `isRunning`) while leaving the session gate shut, so every remaining frame of that import was
      // disposed on arrival and the tile sat on its idle placeholder to the end, with no reason shown.
      final (container, controller, _) = wire(initial: _importing);

      expect(controller.pushes, [(true, false)], reason: 'an offline producer never crops');

      final shown = await _tinyImage();
      publishCapturePreviewImage(shown);

      expect(container.read(capturePreviewFrameProvider).image, same(shown));
      expect(shown.debugDisposed, isFalse);
    });

    test('the preview preference is honoured for an import too, with no forced-on exception', () async {
      ProviderContainer.test().read(capturePreviewEnabledProvider.notifier).set(false);
      final (container, controller, imports) = wire();

      imports.value = _importing;
      expect(controller.pushes, [(false, false)], reason: 'a disabled preview must never be turned on by an import');

      final refused = await _tinyImage();
      publishCapturePreviewImage(refused);
      expect(container.read(capturePreviewFrameProvider).image, isNull);
      expect(refused.debugDisposed, isTrue);
    });

    test('an import ending does not close a live session that is still running', () async {
      // The two gates are OR'd rather than sharing one slot. They are mutually exclusive in the core today,
      // so this is insurance -- but a preview closed by somebody else's teardown is silent and permanent,
      // and the only way back is a full session restart.
      final (container, controller, imports) = wire();
      controller.handleNativeMessage(jsonEncode({'type': 'onCaptureStarted'}));
      imports.value = _importing;
      imports.value = _importFinished;

      final live = await _tinyImage();
      publishCapturePreviewImage(live);
      expect(container.read(capturePreviewFrameProvider).image, same(live));
    });
  });

  group('capture-session gating', () {
    // Driven through the REAL `handleNativeMessage` dispatch, because the guarantee is a property of the
    // session lifecycle, not of the notifier in isolation -- and it has to hold on desktop too, where the
    // very same `onCaptureStarted` / `onCaptureStopped` messages come out of the C++ core.
    test('a frame decoded after onCaptureStopped is dropped and disposed', () async {
      final container = ProviderContainer.test();
      final controller = PlatformController(container.read(_refProvider), const {});
      // Mounts the notifier, which is what `publishCapturePreviewImage` resolves against.
      container.read(capturePreviewFrameProvider.notifier);

      controller.handleNativeMessage(jsonEncode({'type': 'onCaptureStarted'}));
      final live = await _tinyImage();
      publishCapturePreviewImage(live);
      expect(container.read(capturePreviewFrameProvider).image, same(live), reason: 'a running session shows frames');

      controller.handleNativeMessage(jsonEncode({'type': 'onCaptureStopped'}));
      expect(container.read(capturePreviewFrameProvider).image, isNull);
      expect(live.debugDisposed, isTrue);

      // The frame that was already decoding when the session ended. `clear()` alone would let it back in.
      final straggler = await _tinyImage();
      publishCapturePreviewImage(straggler);

      expect(container.read(capturePreviewFrameProvider).image, isNull, reason: 'stop means clear, never freeze');
      expect(straggler.debugDisposed, isTrue, reason: 'the dropped frame owns a texture');
    });

    test('a frame arriving before any session ever started is dropped', () async {
      // Nothing produces frames outside a session, so one arriving here is a bug somewhere upstream -- and
      // showing it would strand a texture the stop path will never be told about.
      final container = ProviderContainer.test();
      container.read(capturePreviewFrameProvider.notifier);
      final orphan = await _tinyImage();

      publishCapturePreviewImage(orphan);

      expect(container.read(capturePreviewFrameProvider).image, isNull);
      expect(orphan.debugDisposed, isTrue);
    });
  });

  group('the desktop previewFrame transport', () {
    // Pins the whole desktop wire format in one place: the METHOD name, the three map keys, and the fact
    // that the pixels cross as raw BGRA rather than as anything encoded. Every one of those is agreed with
    // windows/runner/platform_channel.h and nothing else checks it -- a rename on either side would simply
    // leave the tile blank forever, with no error anywhere to say why.
    test('a previewFrame call reaches the tile as an image', () async {
      final container = ProviderContainer.test();
      PlatformController(container.read(_refProvider), const {});
      container.read(capturePreviewFrameProvider.notifier).setCapturing(true);

      const width = 3;
      const height = 2;
      // Opaque white: alpha 255 is what makes the premultiplied bgra8888 format equal straight bytes.
      final bgra = Uint8List(width * height * 4)..fillRange(0, width * height * 4, 0xFF);
      await _sendPreviewFrame({'width': width, 'height': height, 'bytes': bgra});
      await waitUntil(
        () => container.read(capturePreviewFrameProvider).image != null,
        describe: 'the pushed BGRA frame to be decoded and published to the tile',
      );

      final image = container.read(capturePreviewFrameProvider).image;
      expect(image, isNotNull, reason: 'the raw frame must reach the tile with no decode step');
      expect(image?.width, width);
      expect(image?.height, height);
    });

    // The payload is untyped by the time it reaches Dart, and it arrives on the capture path: a malformed
    // one must be dropped, never thrown back into the method-channel handler.
    test('a malformed previewFrame payload is dropped without throwing', () async {
      final container = ProviderContainer.test();
      PlatformController(container.read(_refProvider), const {});
      container.read(capturePreviewFrameProvider.notifier).setCapturing(true);

      await _sendPreviewFrame('not a map');
      await _sendPreviewFrame({'width': 3, 'height': 2, 'bytes': 'not bytes'});
      // Right shape, wrong length: caught by the decoder, logged and dropped inside the sink.
      await _sendPreviewFrame({'width': 3, 'height': 2, 'bytes': Uint8List(4)});
      await _settle();

      expect(container.read(capturePreviewFrameProvider).image, isNull);
    });
  });

  group('every previewFrame transport uploads the same BGRA payload', () {
    // Both platforms are fed by ONE producer -- LivePreviewPolicy in the shared core -- so both receive the
    // same thing: tightly packed BGRA, already at its final size, with the size stated by the frame itself.
    // The web side used to receive a browser-built ImageBitmap instead, and under the even-crop fallback that
    // bitmap showed a different rectangle than the recognizer had seen.
    //
    // There is now ONE decoder for both, so "web equals desktop" is no longer a statement that can fail --
    // and, more to the point, it never caught a drift that moved BOTH sides. What can still fail is the
    // channel order itself, so it is pinned against a hand-written expectation: swap bgra8888 for rgba8888 in
    // `decodePreview` and this test goes red for every platform at once, which is exactly the blast radius
    // that edit has.
    //
    // Deliberately not a widget test: the transport above it (`dart:js_interop`, a Worker message) cannot run
    // on the VM, but the payload contract and the upload can, and they are what a drift would break.
    test('BGRA bytes upload with blue and red exchanged, alpha untouched', () async {
      const width = 3;
      const height = 2;
      // Distinct per channel and per pixel, so a transposed channel cannot coincide with the right answer.
      final bgra = Uint8List.fromList(List<int>.generate(width * height * 4, (i) => (i * 7 + 3) & 0xFF));
      // Opaque, so premultiplied bgra8888 equals the straight bytes and the expectation below is exact.
      for (var i = 3; i < bgra.length; i += 4) {
        bgra[i] = 0xFF;
      }
      // What `rawRgba` must read back: B and R swapped in place, G and A where they were.
      final expectedRgba = Uint8List.fromList(bgra);
      for (var i = 0; i + 3 < expectedRgba.length; i += 4) {
        expectedRgba[i] = bgra[i + 2];
        expectedRgba[i + 2] = bgra[i];
      }

      final image = await decodePreview(CapturePreviewPixels(width: width, height: height, bgra: bgra));
      try {
        expect(image.width, width);
        expect(image.height, height);
        final actual = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        expect(actual?.buffer.asUint8List(), expectedRgba);
      } finally {
        image.dispose();
      }
    });

    // A short buffer must be refused rather than uploaded: the sink turns the throw into a rate-limited log
    // and drops the frame, which is the only failure mode a preview is allowed to have.
    test('a payload whose length disagrees with its size is refused', () {
      expect(() => decodePreview(CapturePreviewPixels(width: 3, height: 2, bgra: Uint8List(4))), throwsArgumentError);
      expect(() => decodePreview(CapturePreviewPixels(width: 0, height: 0, bgra: Uint8List(0))), throwsArgumentError);
    });
  });

  group('PlatformController.setCapturePreview', () {
    test('reaches the platform as setCapturePreview with both flags in a JSON string', () async {
      // The desktop producer is driven by this one call, so a wrong method name or a payload the runner
      // cannot read means the preview is simply never produced -- with no error anywhere to say so.
      //
      // The argument is deliberately a JSON STRING, not a map: the Windows runner's dispatcher reads every
      // argument as a std::string. This pins the outer string and the two strict boolean fields.
      final invoked = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformChannel.channel,
        (call) async {
          invoked.add(call);
          return null;
        },
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          PlatformChannel.channel,
          null,
        );
      });
      final container = ProviderContainer.test();
      final controller = PlatformController(container.read(_refProvider), const {});
      // The constructor pushes the initial config over the same channel; only the toggles matter here.
      invoked.clear();

      // Must not throw: a MissingPluginException here would surface on every toggle and on startup, where
      // the persisted preference is pushed once.
      await controller.setCapturePreview(true, false);
      await controller.setCapturePreview(false, true);

      expect(invoked.map((call) => call.method), ['setCapturePreview', 'setCapturePreview']);
      expect(invoked.map((call) => jsonDecode(call.arguments! as String)), [
        {'enabled': true, 'cropped': false},
        {'enabled': false, 'cropped': true},
      ]);
    });
  });
}
