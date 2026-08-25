/// The web leg of `video_frame_grab.dart`.
///
/// **The contract is the one stated in `video_frame_grab_ops.dart` and it does not vary here.** A grab at
/// time `T` returns *the frame a player would be showing at `T`* — the last frame whose media timestamp is at
/// or before `T` — and the times are milliseconds with no frame ordinal anywhere. Only the demuxer differs
/// from the io leg: Windows reaches that sentence through `cv::VideoCapture`
/// (`native/src/cv/video_frame_grabber.h`), web reaches it through mediabunny's `VideoSampleSink.getSample`,
/// measured to return a sample starting at or before `T` on 4800 random reads across twelve clips and both
/// containers, and never one starting after it.
///
/// **Why that one difference is forced, in the terms `.claude/rules/platform-parity.md` asks for.** This leg
/// does not merely prefer a different demuxer: it cannot reach the io leg's. `native/wasm/build.sh` links
/// `libopencv_core` / `imgproc` / `imgcodecs` and nothing else, so there is no `opencv_videoio` in the
/// Emscripten build and `cv::VideoCapture` does not exist there — including `video_frame_grabber.h` from a
/// wasm translation unit is a link error by design — and a browser has no file path to hand it if it did,
/// only an opaque `File`. The exchange does not run the other way either: the vendored mediabunny is a
/// *browser* build that decodes through `VideoDecoder`, and the Windows runner is a C++ process with no
/// JavaScript engine and no WebCodecs. So the *contract* is shared and only the demuxer under it differs;
/// the constraint is stated at length beside the C++ half, at `native/src/cv/video_frame_grabber.h`, and
/// the linker list it names is `native/wasm/build.sh`.
///
/// **Why mediabunny and not a `<video>` element.** mediabunny is the decoder this front end's *import* runs
/// (`web/video_import.mjs`), so the reported pixels are the pixels this front end's recogniser saw. A
/// `<video>` element — or any canvas — interposes its own colour conversion and would document a frame the
/// pipeline never had.
///
/// **Why the PNG is encoded in the core and not here.** The frame is copied out of the decoder in its own
/// pixel format and handed to the wasm export `encodeDecodedFramePng`, which runs `color::decodedFrameToBgr`
/// (the conversion `pushOfflineFrame` runs, BT.601 limited range, the CLI's), the shared rotation, the shared
/// producer shaping, and `cv::imencode(".png", ...)` — the same call `Frame::save` makes, hence the same call
/// the Windows report makes. Drawing to a canvas instead would be a second, different conversion: a canvas is
/// a colour-managed surface whose output is sRGB by declaration. There is deliberately **no canvas fallback**
/// for a core that lacks the export; the worker refuses, because a fallback would silently substitute the
/// wrong pixels, which is the defect this whole path exists to remove.
///
/// **The work happens in the wasm worker.** The core module lives there and the clip is handed over as a
/// `File` by structured clone, never read into an `ArrayBuffer` on this side — a screen recording is
/// routinely gigabytes and mediabunny range-reads it. Neither query takes a capture-session claim or touches
/// the pipeline, so a grab is allowed while a live capture or an import is running; that is on purpose,
/// since refusing would make the report unavailable in exactly the situation a user most wants to file one.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import '/src/core/path_entity.dart';
import '/src/core/video_file_dialog_web.dart';
import '/src/core/video_frame_grab_ops.dart';
import '/src/core/wasm_worker_client.dart';

/// Whether this browser can pull a frame out of a clip.
///
/// **The same predicate the import gates on** (`WasmWorkerClient.isVideoImportSupported`: a real
/// `VideoDecoder` constructor plus cross-origin isolation), deliberately and not by coincidence — the two
/// need the identical capabilities, WebCodecs to decode and isolation for the core module the encode runs in.
/// Tying them together is what keeps a clip the user could import from being one this report cannot re-open.
///
/// Feature detection only. Whether *this clip's* codec can be decoded is answered per file, in the worker,
/// with a message naming the codec, rather than hidden behind a control that is simply absent.
bool get videoFrameGrabAvailable => WasmWorkerClient().isVideoImportSupported;

/// A clip this front end can be asked for frames of: on web, the browser `File` the dialog produced.
///
/// **A handle, never bytes**, for the same reason its io twin holds a path: the worker hands it straight to
/// mediabunny's ranged `BlobSource`, so nothing on this side ever holds the encoded clip. Reading it into
/// memory first is precisely how the removed import implementation ran out of it.
///
/// Deliberately without a `close()`, matching the io leg: each call opens the clip, answers, and disposes the
/// demuxer, so there is no session to leak and no state that can disagree with the file.
@immutable
class VideoFrameSource {
  const VideoFrameSource.forFile(this.file);

  /// The chosen clip, as the picker returned it.
  final web.File file;

  /// The file's own name, for a label. Already a leaf on this platform — a browser `File` carries no
  /// directory — so unlike the io leg there is nothing to split off.
  String get name => file.name;
}

/// How [pickVideoFrameSource] obtains the clip.
///
/// A replaceable function rather than a direct call, mirroring `video_frame_grab_io.dart`'s seam and for the
/// same reason: the real dialog is a user gesture on a live DOM element, so a test can never drive the
/// default.
typedef VideoFrameSourcePicker = Future<web.File?> Function();

/// The picker [pickVideoFrameSource] calls. Replaced by tests.
///
/// The shared browser dialog (`video_file_dialog_web.dart`), not a private copy: it is the same dialog and
/// the same container list video import opens, so a clip the user could import is one this report can
/// re-open.
VideoFrameSourcePicker videoFrameSourcePicker = pickVideoFileFromBrowser;

/// Opens the browser's file dialog and returns what the user chose, or null when they dismissed it.
Future<VideoFrameSource?> pickVideoFrameSource() async {
  final file = await videoFrameSourcePicker();
  if (file == null) {
    return null; // Cancelled.
  }
  return VideoFrameSource.forFile(file);
}

/// The clip's time axis, read off its own decoded frames by the worker. See [VideoFrameTimeline].
///
/// Slow enough to need saying, as on io: it opens the file, decodes its first frame for the size, walks
/// packets to establish whether the clip's timestamps advance at all, and — only for a container that
/// declares no duration — scans the packet index for one. Call it once per chosen file, not per redraw.
Future<VideoFrameTimeline> probeVideoFrames(VideoFrameSource source) async {
  final reply = await _invoke(() => WasmWorkerClient().probeVideoFrameTimeline(source.file), 'probe ${source.name}');
  return videoFrameTimelineFromWire(reply);
}

/// Writes the frame displayed at [timeMs] to [destination] as a PNG and reports which frame it was.
///
/// **[destination] is the caller's, unchanged**, exactly as on io — the caller owns the file, and its
/// deletion, from before the call is even made. The one thing that differs is *who writes it*: on Windows the
/// runner writes the PNG and answers with metadata only, because the pixels would otherwise be copied through
/// the platform thread; here the bytes are already on the main thread when the worker's reply lands, so this
/// side writes them to the same [FilePath] (which on web is a path in the OPFS-backed VFS). The bytes
/// themselves are the core's either way.
///
/// The wire is parsed **before** the file is written, so a reply this facade refuses — one carrying no media
/// timestamp, say — leaves no orphan file behind for a caller that is about to be told the grab failed.
///
/// [timeMs] should already have been put through [VideoFrameTimeline.clampToSelectable]; the producer clamps
/// as well — on this side too, and that is measured rather than defensive. mediabunny answers `null`, not the
/// first frame, for any time strictly below a clip's first timestamp, and the probe reports that timestamp in
/// whole milliseconds: `.notes/player_standard_2.mp4` starts at 50.033 ms, so a selector sitting on its own
/// published minimum of 50 asked for a time the clip refuses. Headless Chrome 151 refused it while Windows
/// answered the identical request with the first frame, so the web producer clamps up exactly as
/// `clampIntoClip` does. An out-of-range time therefore returns the nearest frame rather than failing, and
/// [GrabbedVideoFrame.mediaTsMs] is then what says which frame that was.
Future<GrabbedVideoFrame> grabVideoFrame({
  required VideoFrameSource source,
  required int timeMs,
  required FilePath destination,
}) async {
  final what = 'grab ${source.name} at ${timeMs}ms';
  final grabbed = await _invoke(() => WasmWorkerClient().grabVideoFramePng(source.file, timeMs), what);
  final frame = grabbedVideoFrameFromWire(grabbed.json, png: destination, requestedMs: timeMs);
  try {
    await destination.writeAsBytes(grabbed.png);
  } catch (error) {
    throw VideoFrameGrabException('$what: writing the PNG to ${destination.name} failed: $error');
  }
  return frame;
}

/// Runs one worker query, turning every way it can fail into the one type this facade throws.
///
/// **Not a table of causes**, exactly as on io: the worker's message is passed through verbatim, because the
/// side that knows why the decode failed is the side that wrote it. [what] names the request so a log line
/// says which call failed without the caller having to add that itself.
///
/// The unsupported-browser branch is here rather than left to the worker so a caller that ignored
/// [videoFrameGrabAvailable] fails the same way it would on io, with a sentence that says "this front end has
/// no such thing" instead of an error from three layers down.
Future<T> _invoke<T>(Future<T> Function() call, String what) async {
  if (!videoFrameGrabAvailable) {
    throw VideoFrameGrabException('$what: this browser has no video frame grabber');
  }
  try {
    return await call();
  } on VideoFrameGrabException {
    rethrow;
  } catch (error) {
    // Every worker-side refusal arrives here as a `StateError` carrying the worker's own sentence, and
    // `'$error'` on a StateError prints exactly that sentence with a `Bad state: ` prefix. Flattened into one
    // type on purpose: a dialog callback that let an unforeseen error escape across an async boundary would
    // become an unhandled zone error and the user would see nothing at all.
    throw VideoFrameGrabException('$what: $error');
  }
}
