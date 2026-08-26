/// The platform-agnostic contract for the live capture preview: the persisted on/off
/// preference, the single [ui.Image] the tile renders, and the backpressure sink every
/// producer pushes through.
///
/// Deliberately in `core/` rather than `gui/`: `platformControllerLoader` has to
/// `ref.listen` the preference so a toggle reaches the frame producer, exactly as it does
/// for `forceResizeModeStateProvider`.
///
/// There is only ONE producer: `LivePreviewPolicy` in the shared core
/// (`native/src/core/native_api.h`) decides whether a captured frame becomes a preview, how
/// big it is and how often one may be emitted. Both platforms transport its output and add
/// nothing, and NEITHER encodes anything — each transport carries raw BGRA natively:
///  * **web** — the worker pulls `Module.takePreviewFrame()` and posts the bytes on a
///    transferred `ArrayBuffer`.
///  * **desktop** — the runner's preview sink forwards the same bytes on the platform
///    channel's own `previewFrame` method.
///
/// Both transports then hand their bytes to the ONE [decodePreview] below. It used to be two
/// byte-identical copies in `capture_preview_decoder_io.dart` / `_web.dart`, from the days when web
/// received a browser-built `ImageBitmap` and desktop received pixels; once the web worker started
/// forwarding the core's own bytes there was nothing platform-specific left in either copy — neither
/// touches anything outside `dart:ui` — so they are a single platform-neutral implementation here.
///
/// Both end at [publishCapturePreviewImage], which is the only way a frame reaches the UI.
///
/// **Nothing here restates the preview's size.** A front end is not told the preview box in
/// advance and does not need to be: every frame carries its own width and height, and the tile
/// lays out from the aspect ratio it actually received. The 576x320 pair used to be written a
/// third time in this file, next to the copies in C++ and in JavaScript.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/utils.dart';
import '/src/preference/notifier.dart';
import '/src/preference/settings_state.dart';

/// The shape used before the first preview frame arrives.
const double capturePreviewDefaultAspectRatio = 9 / 16;

/// Whether the live capture preview is shown (and therefore produced at all).
///
/// Defaults to **on**: the preview is the one thing that answers "is it actually seeing my
/// game?" at a glance, which is the question a first-time user has. Turning it off is what
/// stops the producer from doing any work at all (see the OFF guarantee in `web/worker.js`).
final capturePreviewEnabledProvider = BooleanNotifierProvider(() {
  return BooleanNotifier(entryKey: SettingsEntryKey.capturePreview.name, defaultValue: true);
});

/// Everything the tile needs to lay itself out and paint.
///
/// The shape deliberately outlives the image: an off or idle placeholder has no frame to
/// measure, and must not snap the tile back to portrait after a landscape frame.
@immutable
class CapturePreviewFrame {
  final ui.Image? image;
  final double aspectRatio;

  const CapturePreviewFrame({required this.image, required this.aspectRatio});

  const CapturePreviewFrame.empty({this.aspectRatio = capturePreviewDefaultAspectRatio}) : image = null;
}

/// The most recent preview frame and its last displayed shape, or an empty frame when no image
/// is available.
///
/// **At most one [ui.Image] is ever held.** Every path that replaces or drops the image
/// disposes the previous one immediately, so the preview costs one small texture and not a
/// growing pile of them — including across a hot restart, which tears down the
/// `ProviderContainer` and disposes the notifier (a hot reload does not; it keeps the
/// existing container, so this `dispose` does not run).
class CapturePreviewFrameNotifier extends Notifier<CapturePreviewFrame> {
  /// Mirrors [state] so the disposal paths never have to read `state` off a disposed
  /// notifier (which throws, and would leak the very texture it was meant to release).
  ui.Image? _current;

  /// Whether a capture session is running, as told by [setCapturing].
  ///
  /// The preview pipeline is asynchronous end to end — the producer emits, the payload
  /// crosses a sink, the decode completes a few milliseconds later — so a frame can finish
  /// decoding *after* the session that produced it ended. Without this gate that frame is
  /// stored and shown, which freezes a stale image over an idle tile and holds its texture
  /// until the next session. Kept as a plain field, set synchronously from the
  /// `onCaptureStarted` / `onCaptureStopped` dispatch, because the observable capture state
  /// travels through a stream and therefore lands a microtask too late to be authoritative
  /// here.
  bool _capturing = false;

  @override
  CapturePreviewFrame build() {
    // Turning the preview off must not leave the last frame on screen: it is both stale and
    // a retained texture. Listening here (rather than in the toggle button) means every
    // route to the preference -- the button, a settings reset, a restored value -- clears it.
    ref.listen<bool>(capturePreviewEnabledProvider, (_, enabled) {
      if (!enabled) {
        clear();
      }
    });
    ref.onDispose(() {
      if (identical(_mountedPreviewNotifier, this)) {
        _mountedPreviewNotifier = null;
      }
      _current?.dispose();
      _current = null;
    });
    _mountedPreviewNotifier = this;
    return const CapturePreviewFrame.empty();
  }

  /// Marks a capture session as running ([capturing] true) or finished.
  ///
  /// Ending a session also [clear]s: the last frame of a finished session is stale, and the
  /// tile must return to its idle placeholder rather than freeze on it.
  ///
  /// Platform-agnostic on purpose — both producers reach the UI through this notifier, so
  /// desktop gets the same guarantee the web path does without a `kIsWeb` branch anywhere.
  void setCapturing(bool capturing) {
    _capturing = capturing;
    if (!capturing) {
      clear();
    }
  }

  /// Shows [image], disposing whatever was shown before it.
  ///
  /// A frame that arrives after the preference was turned off, or after the session that
  /// produced it stopped (both of which a frame can outlive: the producer stops within one
  /// throttle window and the decode finishes later still), is disposed and dropped rather
  /// than shown.
  void setImage(ui.Image image) {
    if (!_capturing || !ref.read(capturePreviewEnabledProvider)) {
      image.dispose();
      return;
    }
    final previous = _current;
    if (identical(previous, image)) {
      // The very instance already on screen, handed in again. Unreachable today -- every producer
      // decodes a fresh image per frame -- but falling through would store it and then dispose
      // `previous`, i.e. destroy the texture just published and leave the tile painting a disposed
      // image. There is nothing to replace and nothing to release, so there is nothing to do.
      return;
    }
    _current = image;
    state = CapturePreviewFrame(
      image: image,
      aspectRatio: image.height > 0 ? image.width / image.height : state.aspectRatio,
    );
    previous?.dispose();
  }

  /// Drops the current frame (capture stopped, or the preview was turned off), keeping the shape.
  void clear() {
    final previous = _current;
    if (previous == null) {
      return;
    }
    _current = null;
    state = CapturePreviewFrame.empty(aspectRatio: state.aspectRatio);
    previous.dispose();
  }
}

final capturePreviewFrameProvider = NotifierProvider<CapturePreviewFrameNotifier, CapturePreviewFrame>(
  CapturePreviewFrameNotifier.new,
);

/// The mounted [CapturePreviewFrameNotifier], or null when nothing is holding the provider.
///
/// The producers run where there is no Riverpod `Ref` -- the web platform channel is
/// constructed by `PlatformChannel()` with no container in sight -- so the notifier
/// publishes itself here on build. This is the same shape the capture page already uses for
/// the worker's `ValueListenable` signals (`capture_capability.dart`).
CapturePreviewFrameNotifier? _mountedPreviewNotifier;

/// Hands one decoded preview frame to the UI, or disposes it when nothing is listening.
///
/// **Never drop an image on the floor here.** A `ui.Image` on web wraps a GPU surface, so an
/// un-disposed frame that reaches no notifier is a leak, not garbage.
void publishCapturePreviewImage(ui.Image image) {
  final target = _mountedPreviewNotifier;
  if (target == null) {
    image.dispose();
    return;
  }
  target.setImage(image);
}

/// One preview frame exactly as the core produced it: tightly packed BGRA pixels, already downscaled
/// to their final size by `LivePreviewPolicy` (`native/src/core/native_api.h`, which is the only
/// place that size is decided — see the note at the top of this library).
///
/// **The same payload on every platform**, because it is the same producer: the web worker forwards
/// the bytes `Module.takePreviewFrame()` handed it, exactly as the Windows runner forwards the bytes
/// its preview sink was handed. Web used to receive a browser-built `ImageBitmap` instead, which
/// meant the two platforms differed in what a preview frame *is* — and, under the even-crop
/// fallback, in what it showed.
///
/// **No encoding is involved anywhere on this path.** The core used to JPEG- and base64-encode each
/// frame into the notify JSON, which cost the capture thread ~2.7 ms per emit only for Dart to undo
/// both steps; both transports carry binary natively, so the pixels now travel as pixels. On web the
/// bytes arrive on a transferred `ArrayBuffer`, so nothing is copied on the worker → main hop.
///
/// [bgra] is `width * height * 4` bytes with **no row padding** — the producer guarantees a
/// continuous buffer rather than carrying a stride (see `NativeApi::emitPreviewFrame`), which is why
/// nothing here has to deal with `rowBytes`.
@immutable
class CapturePreviewPixels {
  final int width;
  final int height;
  final Uint8List bgra;

  const CapturePreviewPixels({required this.width, required this.height, required this.bgra});
}

/// Uploads one raw preview frame as a [ui.Image], with no decode step at all.
///
/// The frame is already at its final size, so no `targetWidth` / `targetHeight` is passed: re-scaling
/// here would only cost a second resample.
///
/// **[ui.PixelFormat.bgra8888] is not negotiable and not a platform choice.** It is the order the
/// shared core emits, so both transports deliver it; swapping it for `rgba8888` would silently paint
/// every preview with red and blue exchanged on BOTH platforms at once. `capture_preview_toggle_test`
/// pins the channel order against a hand-written expectation for exactly that reason.
///
/// **`bgra8888` is premultiplied.** The producer fills alpha with a constant 255, and at full alpha
/// premultiplied and straight bytes are identical, so the frames are correct as-is. A future source
/// carrying real transparency would have to premultiply on the producer side — nothing here would
/// report the mismatch, it would just render wrong.
///
/// The returned image is owned by the caller and must be disposed exactly once. Throws on a malformed
/// payload, which [CapturePreviewSink] logs and drops.
Future<ui.Image> decodePreview(CapturePreviewPixels frame) {
  final expected = frame.width * frame.height * 4;
  if (frame.width <= 0 || frame.height <= 0 || frame.bgra.length != expected) {
    throw ArgumentError(
      'preview frame is ${frame.bgra.length} B for ${frame.width}x${frame.height} (expected $expected B)',
    );
  }
  // decodeImageFromPixels is callback-based and has no Future variant, so adapt it here rather than at
  // every call site. It never reports failure through an error channel: a bad size is rejected above.
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(frame.bgra, frame.width, frame.height, ui.PixelFormat.bgra8888, completer.complete);
  return completer.future;
}

/// Serializes preview decoding with a **latest-wins** single pending slot.
///
/// Frames arrive at the producer's pace and decode at the engine's; a queue would grow
/// without bound the moment the second is slower than the first. So at most one decode is in
/// flight and at most one payload waits behind it — a third arrival replaces (and releases)
/// the waiting one. Dropping is the correct behaviour for a preview: the newest frame is the
/// only one worth showing.
///
/// Generic over the payload so the backpressure policy can be stated once and tested without a
/// producer. Both transports now push the same thing — the core's raw BGRA frame — but the
/// parameter is kept because the policy is about arrival rates, not about pixels: a payload that
/// owns a releasable handle plugs in through [disposePayload] without changing anything here.
class CapturePreviewSink<T extends Object> {
  /// Turns one payload into an image. Failures are logged and dropped, never surfaced.
  final Future<ui.Image> Function(T payload) decode;

  /// Where a successfully decoded frame goes (production: [publishCapturePreviewImage]).
  final void Function(ui.Image image) onImage;

  /// Releases a payload this sink will never decode (a dropped pending frame, or anything
  /// still held at [close]). Null for both production transports today, whose payloads are plain
  /// bytes the collector handles; required for any payload that owns a handle instead.
  final void Function(T payload)? disposePayload;

  /// Human-readable tag for the rate-limited failure log.
  final String label;

  bool _decoding = false;
  T? _pending;
  bool _closed = false;

  /// How many payloads were dropped because a newer one arrived first. Diagnostics only
  /// (and the assertion the backpressure test makes).
  int droppedCount = 0;

  /// How many decodes have failed. Drives the rate limit on the failure log.
  int errorCount = 0;

  CapturePreviewSink({
    required this.decode,
    required this.onImage,
    this.disposePayload,
    this.label = 'capture preview',
  });

  /// Offers one payload. Returns immediately: the decode runs in the background, and a
  /// payload offered while one is decoding waits in the single pending slot (replacing, and
  /// releasing, whatever was already waiting there).
  void push(T payload) {
    if (_closed) {
      _release(payload);
      return;
    }
    if (_decoding) {
      final dropped = _pending;
      _pending = payload;
      if (dropped != null) {
        droppedCount++;
        _release(dropped);
      }
      return;
    }
    _decoding = true;
    unawaited(_drain(payload));
  }

  /// Releases anything still held and refuses further payloads.
  void close() {
    _closed = true;
    final pending = _pending;
    _pending = null;
    if (pending != null) {
      _release(pending);
    }
  }

  Future<void> _drain(T first) async {
    var current = first;
    // The whole loop runs under one `finally` rather than resetting `_decoding` at each exit
    // point: an exit point that itself throws (e.g. `_release` below) would otherwise skip its
    // reset and leave `_decoding` stuck `true` forever, jamming the sink -- and silently, since
    // `push` is the only call site and its caller (`_drain` itself) is `unawaited`.
    try {
      while (true) {
        // Which of the two things in play the catch below still owns. Up to a successful decode it
        // is the payload; from then on the payload is the decoder's and the image is ours.
        var payloadConsumed = false;
        try {
          final image = await decode(current);
          payloadConsumed = true;
          if (_closed) {
            image.dispose();
          } else {
            try {
              onImage(image);
            } catch (_) {
              // [onImage] takes ownership only by returning normally; a throw leaves the image with
              // no owner at all, and on web that is a leaked GPU surface. The production sink
              // (`publishCapturePreviewImage`) does not throw, so this is insurance against a future
              // one that does -- rethrown into the shared handler below so it is still counted and
              // logged like any other preview failure.
              image.dispose();
              rethrow;
            }
          }
        } catch (error, stackTrace) {
          // The decoder owns the payload only when it succeeds. A failure hands it back, and for a
          // payload holding a handle nothing else would ever release it — a persistently failing
          // decoder would strand one every throttle window while the rate-limited log below hides
          // the fact. [_release] is a no-op for the byte payloads both platforms send today, so
          // releasing here is the safe side of the ambiguity rather than a cost.
          // A throw from `onImage` arrives here too, and there the payload is already the decoder's:
          // releasing it again would be a double free of somebody else's handle.
          if (!payloadConsumed) {
            _release(current);
          }
          errorCount++;
          // Rate-limited, and a log line only: a preview failure must never reach `onError`, a
          // toast or a chime, and must never touch the capture state. It is a refinement.
          if (errorCount == 1 || errorCount % 30 == 0) {
            logger.w('Failed to decode a $label frame (#$errorCount)', error, stackTrace);
          }
        }
        final next = _pending;
        _pending = null;
        if (next == null) {
          return;
        }
        if (_closed) {
          _release(next);
          return;
        }
        current = next;
      }
    } finally {
      _decoding = false;
    }
  }

  void _release(T payload) => disposePayload?.call(payload);
}
