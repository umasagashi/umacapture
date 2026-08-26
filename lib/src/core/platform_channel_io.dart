import 'dart:convert';

import 'package:flutter/services.dart';

import '/src/core/callback.dart';
import '/src/core/capture_preview.dart';
import '/src/core/path_entity.dart';
import '/src/core/raw_frame_probe.dart';
import '/src/core/utils.dart';

typedef PlatformCallback = StringCallback;

class PlatformChannel {
  static const channel = MethodChannel('dev.flutter.umasagashi/capturing_channel');
  PlatformCallback? callbackMethod;

  /// Turns the core's raw preview pixels into the single `ui.Image` the tile renders.
  ///
  /// Owned here rather than by [PlatformController] because the frames arrive on this channel's own
  /// `previewFrame` method, never through the notify JSON — exactly as the web twin owns its own sink over
  /// the same payload and the same platform-neutral [decodePreview].
  /// The sink is what keeps an arrival rate the engine cannot match from piling up: at most one frame is
  /// being uploaded at a time and at most one waits behind it, latest-wins. No `disposePayload`: the
  /// payload is plain bytes, which the collector handles.
  late final CapturePreviewSink<CapturePreviewPixels> _previewSink = CapturePreviewSink<CapturePreviewPixels>(
    decode: decodePreview,
    onImage: publishCapturePreviewImage,
  );

  PlatformChannel() {
    channel.setMethodCallHandler(callbackFromPlatform);
  }

  void setCallback(PlatformCallback method) {
    callbackMethod = method;
  }

  /// Releases what this channel owns beyond Dart's collector: the preview sink, so a frame still being
  /// uploaded when the controller is superseded disposes its image instead of publishing it. Called from
  /// [PlatformController.dispose].
  ///
  /// Always returns false, i.e. "no capture session ended here". The platform constraint is that a
  /// desktop session lives in the native runner, not in this object: it keeps capturing across a
  /// controller rebuild and keeps reporting through the method-channel handler the freshly built
  /// channel re-registers on the same `static const` channel, so `capturingStateProvider` stays true
  /// because it is still true. Web answers the opposite for the opposite reason (see
  /// `platform_channel_web.dart`).
  bool dispose() {
    _previewSink.close();
    return false;
  }

  Future<void> setConfig(String config) {
    return channel.invokeMethod('setConfig', config);
  }

  Future<void> setPlatformConfig(String config) {
    return channel.invokeMethod('setPlatformConfig', config);
  }

  /// Drops the auto-calibrated detail crop and its latch in the core, so it is measured again from scratch.
  ///
  /// Deliberately its own method rather than a config delta: the delta path only takes effect at the next
  /// session start, while this acts on a live lock-free flag and is meant to work mid-session.
  Future<void> resetDetailCropCalibration() {
    return channel.invokeMethod('resetDetailCropCalibration');
  }

  /// Turns the live capture preview on or off in the core.
  ///
  /// Deliberately its own method rather than a config delta, for the same reason as
  /// [resetDetailCropCalibration]: the delta path only takes effect at the next session start,
  /// while this flips a live lock-free flag and must work mid-capture.
  ///
  /// The state travels as a JSON string, not as a map: the Windows runner's method dispatcher reads every
  /// argument as a `std::string`. JSON is the simplest strict representation of both booleans without a
  /// custom delimiter grammar.
  Future<void> setCapturePreview(bool enabled, bool cropped) {
    return channel.invokeMethod('setCapturePreview', jsonEncode({'enabled': enabled, 'cropped': cropped}));
  }

  /// Asks the native runner to decode the clip at [path] into the recognition pipeline.
  ///
  /// The argument travels as a JSON object encoded to a string for the same reason
  /// [setCapturePreview]'s does: the Windows runner's method dispatcher reads every argument as a
  /// `std::string`. A bare path would also have worked, but the object is what
  /// `windows/runner/native_controller.h` already parses, and it leaves room for a second field
  /// without inventing a delimiter grammar.
  ///
  /// **Static, unlike the instance methods that make up this class's cross-platform surface, and
  /// that asymmetry has a cause.** (It is no longer the only static member — [probeVideoFrames] and
  /// [grabVideoFrame] followed, for this same reason restated there.)
  /// The caller is the `video_import.dart` facade, which owns no [PlatformChannel]: the only
  /// instance in the app is `PlatformController`'s private field, and constructing a second one
  /// would re-register the method-call handler on the shared [channel] and take every `notify` away
  /// from the controller. Nothing on this class needs an instance for a `Dart -> native` call
  /// anyway — [channel] is `static const` and every one of them invokes on it.
  ///
  /// It is also what marks these two as **outside the class's cross-platform contract**, and that is
  /// the more important half. `platform_channel.dart` declares the io and web files to expose one
  /// identical instance surface, because `PlatformController` calls it without knowing which leg it
  /// holds; web's `PlatformChannel` has no import method at all, since a browser import runs through
  /// `WasmWorkerClient` and never touches the channel. Making these instance methods would put two
  /// members into that shared surface with nothing behind them on the other side — trading an
  /// asymmetry confined to one class for one between the platforms. Each front end reaching its own
  /// process-wide transport (the `static const` [channel] here, the worker-client singleton there)
  /// is the symmetry that actually holds.
  static Future<void> startVideoImport(String path) {
    return channel.invokeMethod('startVideoImport', jsonEncode({'path': path}));
  }

  /// Asks a running import to stop at its next frame boundary.
  ///
  /// No argument: the runner holds at most one import, so there is nothing to name. Static for the
  /// same reason as [startVideoImport].
  static Future<void> cancelVideoImport() {
    return channel.invokeMethod('cancelVideoImport');
  }

  /// Asks the runner what time axis the clip at `path` has, for the video-import error report's
  /// frame selector. Answers the JSON `video_frame_grab_ops.dart` parses.
  ///
  /// **The first two methods on this channel that RETURN a value**, and the reason is that they are
  /// the first queries: every other `Dart -> native` call here is a command whose effect is reported
  /// later through `notify`. A query answered by a notification would need a correlation id and a
  /// pending-request table on both sides to say *which* question it answers — machinery the method
  /// channel already has, since `invokeMethod`'s future is exactly that correlation. The runner
  /// answers off the platform thread (`windows/runner/video_frame_grab_service.h`), so the seconds a
  /// pathological clip can cost do not freeze the UI while the future is outstanding.
  ///
  /// Static, and outside the class's cross-platform contract, for the reason [startVideoImport]
  /// states at length: web's `PlatformChannel` has no counterpart, because a browser grab runs
  /// through mediabunny and never touches a channel.
  static Future<String?> probeVideoFrames(String request) {
    return channel.invokeMethod<String>('probeVideoFrames', request);
  }

  /// Asks the runner to write the frame displayed at a given time to a PNG the **caller** named.
  ///
  /// Only the path crosses back, never the pixels — the shape [takeScreenshot] already has, and for
  /// a stronger reason here: a decoded game-screen frame is several megabytes, and the encoded PNG
  /// would have to be copied through the standard codec on the platform thread. See
  /// [probeVideoFrames] for why this returns a value at all.
  static Future<String?> grabVideoFrame(String request) {
    return channel.invokeMethod<String>('grabVideoFrame', request);
  }

  Future<void> startCapture() {
    return channel.invokeMethod('startCapture');
  }

  Future<void> stopCapture() {
    return channel.invokeMethod('stopCapture');
  }

  Future<void> updateRecord(String id) {
    return channel.invokeMethod('updateRecord', id);
  }

  Future<void> finishUpdate() {
    return channel.invokeMethod('finishUpdate');
  }

  Future<void> copyToClipboardFromFile(FilePath path) {
    return channel.invokeMethod('copyToClipboardFromFile', path.path);
  }

  Future<void> takeScreenshot(FilePath path) {
    return channel.invokeMethod('takeScreenshot', path.path);
  }

  /// No-op counterpart of the web raw-frame probe.
  ///
  /// The probe collects frames that still carry the window's title bar, and the desktop
  /// producer captures through `GetClientRect` (`windows/runner/window_capturer.h`), so such
  /// a frame cannot exist here. Its UI entry is gated on `?rawframe=1`, which only a browser
  /// URL can carry, so this is unreachable in practice and exists to keep the two channels
  /// API-identical.
  Future<RawFrameBundle?> buildRawFrameBundle() async => null;

  Future<dynamic> callbackFromPlatform(MethodCall call) {
    switch (call.method) {
      case 'notify':
        final callback = callbackMethod;
        if (callback == null) {
          logger.d('Dropped platform notify before callback was registered');
        } else {
          callback(call.arguments.toString());
        }
        return Future.value('called from platform!');
      case 'previewFrame':
        // A live preview frame, as RAW BGRA on its own method rather than inside the notify JSON above
        // (whose payload `call.arguments.toString()` assumes a String). It is a separate method precisely
        // so the pixels stay binary: the standard codec carries them as a Uint8List with no encoding at
        // either end.
        _handlePreviewFrame(call.arguments);
        return Future.value(null);
      default:
        logger.d('Unknowm method ${call.method}');
        throw MissingPluginException();
    }
  }

  /// Pushes one `previewFrame` payload into the sink, or drops it.
  ///
  /// Nothing here may cost the capture anything, and nothing here may throw back across the method-channel
  /// handler: a payload that does not match the contract is simply not pushed, and a failed upload is logged
  /// and dropped inside the sink. The map keys mirror `windows/runner/platform_channel.h`.
  void _handlePreviewFrame(Object? arguments) {
    if (arguments is! Map) {
      logger.d('Dropped a preview frame with a non-map payload');
      return;
    }
    final width = arguments['width'];
    final height = arguments['height'];
    final bytes = arguments['bytes'];
    if (width is! int || height is! int || bytes is! Uint8List) {
      logger.d('Dropped a preview frame with an unexpected payload shape');
      return;
    }
    _previewSink.push(CapturePreviewPixels(width: width, height: height, bgra: bytes));
  }
}
