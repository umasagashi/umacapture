/// The platform-neutral half of the video-frame grab facade (`video_frame_grab.dart`): the value
/// types both front ends answer in, and the parsing of the one wire format they both speak.
///
/// It lives outside the conditional export for the reason `video_import_ops.dart` does: these types
/// are what the *shared* UI holds, so they must exist on every leg, and the parsing is the part of
/// the feature that can be tested on the VM. Nothing here imports `dart:io` or `dart:js_interop`.
///
/// **THE CONTRACT, and it does not vary by platform.** A grab at time `T` returns *the frame a
/// player would be showing at `T`* — the last frame whose media timestamp is at or before `T`. Not
/// the nearest frame, not the next one. Windows reaches that answer through
/// `native/src/cv/video_frame_grabber.h` (`cv::VideoCapture`, seek-behind-then-decode-forward) and
/// web reaches it through mediabunny's random access (`web/video_import.mjs`, `grabClipFramePng`),
/// because those are the decoders the two front ends' *imports* already run — so the reported pixels
/// are the pixels that front end's recogniser saw. Only the demuxer differs; the sentence above is
/// the same on both.
///
/// **THE CONTRACT IS ASYMMETRIC ABOUT NEIGHBOURING FRAMES, and that is why the reply carries
/// [GrabbedVideoFrame.nextMediaTsMs] and deliberately carries no `prevMediaTsMs`.** Times here are
/// integer milliseconds, so given an answer stamped `M`, *the frame before it* is exactly
/// `grabAt(M - 1)`: the last frame at or before `M - 1` is the last frame strictly before `M`. That is
/// a derivation from the sentence above — no epsilon, no frame rate, no extra wire field, and it is
/// exact on a 1 ms frame and on a 1305 ms variable-frame-rate frame alike. There is **no such
/// expression for the frame after it**: "the last frame at or before `T`" is monotone in `T` and can
/// never name a frame that starts after `T`, for any `T` derivable from the answer. So the successor
/// is the one neighbour a caller cannot compute and the producer has to *state*. Adding a
/// `prevMediaTsMs` "for symmetry" would be a second, redundant spelling of `M - 1` that a later edit
/// could let drift away from the subtraction; the asymmetry is a property of the contract, not an
/// oversight.
///
/// **Times are milliseconds, and there is no frame ordinal anywhere in this API.** That is measured,
/// not stylistic: `CAP_PROP_FRAME_COUNT` is not merely absent but *wrong* on this app's own FFV1
/// recordings (426 reported against 376 decoded; 1344 against 1258), so a frame number would be a
/// number neither side can honour. See the class comment in `video_frame_grabber.h`.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '/src/core/path_entity.dart';

/// A clip's time axis, as the decoder that will be asked for its frames actually reports it.
///
/// Every field is read off decoded frames or container metadata by the producer; none of it is
/// assumed. In particular [firstFrameMs] is **not** 0 for every clip.
@immutable
class VideoFrameTimeline {
  const VideoFrameTimeline({
    required this.firstFrameMs,
    required this.durationMs,
    required this.fps,
    required this.width,
    required this.height,
    required this.hasMediaTimeline,
  });

  /// Media time of the clip's first decoded frame.
  ///
  /// **A time selector's minimum, and it is not zero.** `.notes/player_standard*.mp4` starts at
  /// 50.033 ms, so a control that began at 0 would spend its first positions addressing nothing.
  final int firstFrameMs;

  /// The clip's duration as the container states it, or **0 meaning indeterminate**.
  ///
  /// The same convention the import's progress bar already uses (`VideoLoader::durationMsOf`), and
  /// the same number, deliberately: the selector's maximum and the progress bar cannot disagree
  /// about the same file. A front end that gets 0 must render an unbounded control rather than a
  /// wrong one — see [selectableEndMsExclusive].
  final int durationMs;

  /// The container's nominal frame rate, or 0 when it does not state a usable one.
  ///
  /// **Diagnostic only — nothing in this app steps by it, and nothing may.** It is neither a way to
  /// turn a time into a frame number nor a way to size a "one frame" step: both are the same
  /// conversion, and it is exactly the bug this API exists to avoid (a variable-frame-rate recording
  /// drifts away from its average rate, and every phone / game-screen capture here is VFR — a single
  /// frame lasting 1305 ms is measured on this app's own material). Moving by one frame is
  /// [GrabbedVideoFrame.nextMediaTsMs] forward and `mediaTsMs - 1` back, both exact on such a clip
  /// where `1 / fps` lands on the same frame forty presses in a row. Report it, do not compute with
  /// it.
  final double fps;

  /// The size of the **decoded** frame, not the size the container declares.
  final int width;

  /// See [width].
  final int height;

  /// False when the clip's frames carry no advancing media time, so "the frame displayed at T" is
  /// not a question the file can answer.
  ///
  /// A front end must refuse to offer a selector for such a clip rather than let the user scrub
  /// through a timeline that addresses one frame — refusing with a reason is the whole point, since
  /// answering every `T` with the same arbitrary frame is the "wrong frame was sent" outcome.
  final bool hasMediaTimeline;

  /// First selectable time. Identical to [firstFrameMs]; named so a selector reads as a range.
  int get selectableStartMs => firstFrameMs;

  /// **Exclusive** upper end of the selectable range, or null when [durationMs] is indeterminate.
  ///
  /// Exclusive because the range a selector may offer is `[firstFrameMs, durationMs)`: the duration
  /// itself is the instant *after* the last frame, and a request for exactly the final stamp puts a
  /// backoff seek past end-of-stream, where the read simply fails (measured on three containers,
  /// `video_frame_grabber.h`'s `grabAt`). The producer clamps as well, so this bound is what keeps a
  /// selector honest rather than the only thing standing between the user and a failed read.
  int? get selectableEndMsExclusive => durationMs > 0 ? durationMs : null;

  /// Last selectable time, or null when the range is unbounded above.
  ///
  /// Never below [firstFrameMs]: a container that reports a duration at or before its own first
  /// frame still has that frame, and it is the only truthful answer to every `T`.
  int? get lastSelectableMs {
    final end = selectableEndMsExclusive;
    if (end == null) {
      return null;
    }
    final last = end - 1;
    return last < firstFrameMs ? firstFrameMs : last;
  }

  /// [timeMs] moved into the selectable range.
  ///
  /// Both ends are load-bearing rather than defensive. Below [firstFrameMs] nothing is displayed at
  /// all, so the first frame is the truthful answer; above the range an unclamped request costs the
  /// producer a full sequential decode to reach the same last frame this reaches directly.
  int clampToSelectable(int timeMs) {
    if (timeMs < firstFrameMs) {
      return firstFrameMs;
    }
    final last = lastSelectableMs;
    if (last == null) {
      return timeMs;
    }
    return timeMs > last ? last : timeMs;
  }

  @override
  String toString() =>
      'VideoFrameTimeline(firstFrameMs: $firstFrameMs, durationMs: $durationMs, fps: $fps, '
      'size: ${width}x$height, hasMediaTimeline: $hasMediaTimeline)';
}

/// One frame, already written to disk as a PNG, and the record of which frame it actually is.
@immutable
class GrabbedVideoFrame {
  const GrabbedVideoFrame({
    required this.png,
    required this.requestedMs,
    required this.mediaTsMs,
    required this.seekBackoffMs,
    required this.decodedFrames,
    this.nextMediaTsMs,
    this.width,
    this.height,
    this.format,
    this.rotation,
    this.matrixConverted,
  });

  /// Where the PNG was written — **the destination the caller passed in**, unchanged.
  ///
  /// The producer writes the file and the caller names it, which is the shape `takeScreenshot`
  /// already has on both front ends: the pixels never cross the channel, and the caller owns the
  /// file (and its deletion) from the moment it chose the name.
  final FilePath png;

  /// The time that was asked for, after the caller's own clamping.
  final int requestedMs;

  /// The media time of the frame that actually came back, which is at or before [requestedMs].
  ///
  /// **A report that says "the frame at T" must quote this, not [requestedMs].** They differ by up
  /// to one frame interval by construction, and for an out-of-range request they can differ by more.
  final int mediaTsMs;

  /// The media time of the frame that **follows** [mediaTsMs] in this clip, or null when there is
  /// none — i.e. when the grabbed frame is the clip's last addressable frame.
  ///
  /// **This is the only neighbour the grab contract cannot express, which is the whole reason it is
  /// on the wire** (see the library comment): the *previous* frame is `grabAt(mediaTsMs - 1)` and
  /// needs nothing, while no time derivable from an answer can name the frame after it. A caller that
  /// wants a "next frame" button therefore issues an ordinary `grabAt(nextMediaTsMs)` — stepping is
  /// not a new operation, only the existing grab aimed at a time the producer says is a frame.
  ///
  /// **It is a decoded stamp, not container metadata.** Windows reads it off the frame its forward
  /// pass had already decoded and used to discard (`native/src/cv/video_frame_grabber.h`), and null
  /// means that pass ran out of frames. Neither end is inferred from `durationMs` or from a frame
  /// count — those are exactly the numbers this API refuses to identify frames by.
  ///
  /// **Null means exactly one thing: the grabbed frame is the clip's last addressable frame.** Both
  /// producers of this wire state the field unconditionally — Windows omits the key only at end of
  /// stream (`windows/runner/video_frame_grab_service.h`), and web omits it only when
  /// `firstTwoSamplesAt` found no successor sample (`web/worker.js`, `web/video_import.mjs`) — so
  /// there is no third leg and no "does not state it yet" case for a caller to guard against. Strictly
  /// greater than [mediaTsMs] when present, so a step always lands on a different frame; frames
  /// sharing a rounded millisecond are one addressable frame on both legs, so a step skips same-stamp
  /// siblings (measured 1199 distinct stamps for 1208 frames on a 540p clip,
  /// `native/src/cv/video_frame_grabber.h`) — a "next frame" step can therefore advance past more than
  /// one raw decoded frame.
  final int? nextMediaTsMs;

  /// Diagnostic: which rung of the producer's seek ladder answered, in ms behind the target; 0 means
  /// the pass that starts at the beginning of the clip, and **null means the producer has no ladder
  /// to report** — it is not a rung.
  ///
  /// Nullable for the same reason [width] is, and the case is not hypothetical: mediabunny seeks
  /// internally and hands back one sample, so `web/worker.js` states neither this nor
  /// [decodedFrames] and every web report used to publish `seek_backoff_ms: 0, decoded_frames: 0`
  /// as if they had been measured — a reader would conclude the grab had seeked to the head of the
  /// clip and decoded nothing, which is a claim about the attached pixels and it is false. There is
  /// no web equivalent to supply in their place: the numbers describe a seek ladder that only the
  /// `cv::VideoCapture` producer has (`native/src/cv/video_frame_grabber.h`), and inventing one
  /// from mediabunny's internals would be a different measurement under the same name.
  final int? seekBackoffMs;

  /// Diagnostic: how many frames the successful pass had to decode. The cost of the grab. Null on a
  /// producer that does not state one — see [seekBackoffMs].
  final int? decodedFrames;

  /// The width of the decoded frame the PNG was written from, or **null for "the producer did not
  /// state one"**.
  ///
  /// Nullable rather than 0-defaulted because the two answers are different statements and only one
  /// of them is a measurement: the web grab reply carries a size (`web/worker.js`,
  /// `handleVideoFrameGrabRequest`) and the Windows one does not
  /// (`windows/runner/video_frame_grab_service.h` answers `mediaTsMs` / `nextMediaTsMs` /
  /// `seekBackoffMs` / `decodedFrames`, and no size). A 0 here would read as "a zero-wide frame", which is a claim about the
  /// pixels a report attaches, and wrong metadata on a report is worse than absent metadata.
  final int? width;

  /// See [width].
  final int? height;

  /// The pixel layout the decoder handed back for this frame, in the producer's own words
  /// (`'I420'`, `'NV12'`, `'BGRA'`, …), or null for a producer that does not state one.
  ///
  /// Web-only in practice, and it is the frame-level counterpart of the reason
  /// `VideoImportReason.pixelFormatUnsupported` exists: a browser decoder chooses the layout, so the
  /// layout is evidence about *this* clip in *this* browser rather than a property of the app.
  final String? format;

  /// The clip's clockwise rotation in degrees as the container declares it, or null when the
  /// producer does not state one. **Already applied** to [width] / [height] and to the PNG.
  final int? rotation;

  /// The colour conversion that was accepted for **this one frame** before the PNG was encoded, in
  /// the producer's own words, or null for a producer that reports none.
  ///
  /// **Three states, and they are three different facts**: null is "this producer does not report
  /// conversions" (Windows — the shared core decodes and converts there, so no third party can have
  /// converted behind the app's back and there is nothing to report), `''` is "this producer reports
  /// them and converted nothing", and any other string names what was done. Collapsing the first two
  /// would make an unreported conversion indistinguishable from a clean one, which is exactly the
  /// distinction `native_api_messages.h` states the import wire's field exists to preserve.
  ///
  /// **Not to be confused with `VideoImportOutcome.matrixConverted`**, which is the conversion
  /// accepted during the whole import *run*. That one describes every frame the recogniser saw; this
  /// one describes the single frame the report attaches, grabbed later and separately. They are
  /// different measurements of different pixels, and the report keeps them in different blocks
  /// (`frame.matrix_converted` against `import.matrix_converted`) for that reason.
  final String? matrixConverted;

  @override
  String toString() =>
      'GrabbedVideoFrame(png: ${png.name}, requestedMs: $requestedMs, mediaTsMs: $mediaTsMs, '
      'nextMediaTsMs: $nextMediaTsMs, '
      'seekBackoffMs: $seekBackoffMs, decodedFrames: $decodedFrames, size: ${width}x$height, '
      'format: $format, rotation: $rotation, matrixConverted: $matrixConverted)';
}

/// The one failure type both legs of `video_frame_grab.dart` throw.
///
/// One type rather than a per-cause enumeration on purpose. The causes live where they are decided —
/// the producer's own status text, the decoder's own open failure — and a Dart-side table of them
/// would be a second list that silently stops matching the first the next time a cause is added.
/// What a caller needs from this layer is "it failed, and here is what the side that knows says";
/// the *class* of failure a front end has to branch on before it ever gets here is
/// [VideoFrameTimeline.hasMediaTimeline], which is data rather than a message.
class VideoFrameGrabException implements Exception {
  const VideoFrameGrabException(this.message);

  final String message;

  @override
  String toString() => 'VideoFrameGrabException: $message';
}

/// Reads a probe reply.
///
/// Tolerant about *shape* (a field of the wrong type is read as absent, as `VideoImportSlots` reads
/// the import's three messages) and strict about *substance*: a reply that cannot state a frame size
/// is refused rather than turned into a 0x0 timeline, because a selector built on 0x0 would offer
/// the user a scrub bar over a clip nothing can be grabbed from and say nothing about why.
VideoFrameTimeline videoFrameTimelineFromWire(Object? reply) {
  final wire = _decodeWire(reply, 'probe');
  final timeline = VideoFrameTimeline(
    firstFrameMs: _intAt(wire, 'firstFrameMs') ?? 0,
    durationMs: _intAt(wire, 'durationMs') ?? 0,
    fps: _doubleAt(wire, 'fps') ?? 0.0,
    width: _intAt(wire, 'width') ?? 0,
    height: _intAt(wire, 'height') ?? 0,
    // Absent means "the producer did not say", and the only safe reading of that is the refusing
    // one: a missing field must not be able to turn an unusable clip into a scrubable one.
    hasMediaTimeline: _boolAt(wire, 'hasMediaTimeline') ?? false,
  );
  if (timeline.width <= 0 || timeline.height <= 0) {
    throw VideoFrameGrabException('the clip reported no frame size (${timeline.width}x${timeline.height})');
  }
  return timeline;
}

/// Reads a grab reply, pairing it with the destination and the time the caller asked for.
///
/// [png] and [requestedMs] come from this side rather than from the wire deliberately: the caller
/// chose the file name, so echoing it back would only create a second copy that could disagree.
///
/// **Every field the reply states is read, including the ones only one leg sends.** The two
/// producers answer overlapping but different sets — Windows states the seek ladder's cost, web
/// states the decoded frame's shape and the colour conversion it had to accept — and the fields only
/// web sends are precisely the ones that describe *the pixels a report attaches*. Dropping them here
/// would leave a browser-side colour conversion with no trace anywhere, which is the same defect
/// `videoImportOutcomeOf` had for the import wire's own two fields. A field the reply does not carry
/// stays **null**, which is how the report says "not reported" rather than inventing a zero.
GrabbedVideoFrame grabbedVideoFrameFromWire(Object? reply, {required FilePath png, required int requestedMs}) {
  final wire = _decodeWire(reply, 'grab');
  final mediaTsMs = _intAt(wire, 'mediaTsMs');
  if (mediaTsMs == null) {
    // The one field a report is not allowed to guess: without it there is no honest way to say
    // which frame was sent, and quoting the requested time instead is the "wrong frame" outcome.
    throw const VideoFrameGrabException('the grab reply carried no media timestamp');
  }
  return GrabbedVideoFrame(
    png: png,
    requestedMs: requestedMs,
    mediaTsMs: mediaTsMs,
    // Absent means "no next frame" — the tail of a clip — on both legs: Windows omits the key there
    // and so does web; see the field's own comment for why there is no other reading of absence left.
    nextMediaTsMs: _intAt(wire, 'nextMediaTsMs'),
    // Null, like the five below, and for the identical reason: `web/worker.js` states these two are
    // deliberately ABSENT on its leg, and reading an absent diagnostic as 0 published two zeroes on
    // every web report as though they had been measured. The producer's comment was changed in the
    // same commit as this line, because a convention that only one side keeps is not one.
    seekBackoffMs: _intAt(wire, 'seekBackoffMs'),
    decodedFrames: _intAt(wire, 'decodedFrames'),
    width: _intAt(wire, 'width'),
    height: _intAt(wire, 'height'),
    format: _stringAt(wire, 'format'),
    rotation: _intAt(wire, 'rotation'),
    matrixConverted: _stringAt(wire, 'matrixConverted'),
  );
}

/// The request a probe posts. Built here so both legs encode the identical wire.
String encodeVideoFrameProbeRequest(String path) => jsonEncode(<String, dynamic>{'path': path});

/// The request a grab posts. `output` is the destination **the caller chose**; the producer writes
/// there and nothing else.
String encodeVideoFrameGrabRequest({required String path, required int timeMs, required String outputPath}) =>
    jsonEncode(<String, dynamic>{'path': path, 'timeMs': timeMs, 'output': outputPath});

Map<String, dynamic> _decodeWire(Object? reply, String what) {
  if (reply is! String || reply.isEmpty) {
    // A null reply is what a channel with no handler on the other side produces, and silently
    // reading it as an empty map would hand the caller a plausible, entirely invented answer.
    throw VideoFrameGrabException('the $what reply was not a JSON string (${reply.runtimeType})');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(reply);
  } catch (error) {
    throw VideoFrameGrabException('the $what reply was not valid JSON: $error');
  }
  if (decoded is! Map) {
    throw VideoFrameGrabException('the $what reply was not a JSON object');
  }
  return Map<String, dynamic>.from(decoded);
}

int? _intAt(Map<String, dynamic> wire, String key) {
  final value = wire[key];
  // `num`, not `int`: JSON has one number type, so an integral value that travelled as a double
  // (which a JSON encoder is free to do) must still be read rather than dropped as "wrong type".
  return value is num ? value.round() : null;
}

/// A string field, or null when the reply does not carry one.
///
/// `is String` rather than `toString()`: a number or a map under this key is a producer speaking a
/// different protocol, and turning it into its Dart rendering would put `{a: 1}` on a bug report as
/// if it were a pixel format. Absent and unreadable therefore give the same answer — "not stated" —
/// which is the one the empty string deliberately does not mean.
String? _stringAt(Map<String, dynamic> wire, String key) {
  final value = wire[key];
  return value is String ? value : null;
}

double? _doubleAt(Map<String, dynamic> wire, String key) {
  final value = wire[key];
  return value is num ? value.toDouble() : null;
}

bool? _boolAt(Map<String, dynamic> wire, String key) {
  final value = wire[key];
  return value is bool ? value : null;
}
