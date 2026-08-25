import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '/src/core/path_entity.dart';
// The io leg of `platform_channel.dart`, imported directly rather than through that facade: this
// file is itself an io leg, so naming the concrete transport is a fact rather than a choice.
import '/src/core/platform_channel_io.dart';
import '/src/core/video_file_dialog_io.dart';
import '/src/core/video_frame_grab_ops.dart';

/// Whether this front end can pull a frame out of a clip: **Windows only**, not "any non-web build".
///
/// The conditional export in `video_frame_grab.dart` sends every non-web target here — macOS, Linux,
/// Android, iOS — and none of them has the runner that does the decoding
/// (`windows/runner/video_frame_grab_service.h`). So the platform test is made here rather than in
/// the export condition, where `dart.library.io` cannot express it, exactly as
/// `video_import_io.dart`'s [videoImportAvailable] does. There is no second, runtime capability
/// question the way there is for import: the runner links its decoder statically, so a build with
/// the path has the decoder.
bool get videoFrameGrabAvailable => Platform.isWindows;

/// A clip this front end can be asked for frames of: on io, an absolute path on disk.
///
/// **A handle, never bytes.** The runner opens the file with `cv::VideoCapture` and Dart never reads
/// it at all; a screen recording is routinely gigabytes, so any layer that materialised it would be
/// the layer that ran out of memory. Its web twin wraps a `File` for the same reason.
///
/// Deliberately without a `close()`. Each call opens the clip, answers, and closes it, so there is
/// no session to leak, nothing holding the user's file between two scrubs of a slider, and no state
/// that can disagree with the file on disk. The cost of that choice is one file open per grab
/// (19-127 ms measured), which is small against the grab itself (60-450 ms).
@immutable
class VideoFrameSource {
  const VideoFrameSource.forPath(this.path);

  /// The clip's absolute path, as the dialog returned it and as the runner will open it.
  final String path;

  /// The last segment of [path], for a label.
  ///
  /// Split on both separators rather than with `package:path`: the runner is given the path verbatim
  /// and this is only ever a label, so a Windows path that arrived with forward slashes (a dropped
  /// file, a path typed into the dialog) must still name the file rather than the whole string.
  String get name {
    final segments = path.split(RegExp(r'[/\\]')).where((segment) => segment.isNotEmpty);
    return segments.isEmpty ? path : segments.last;
  }
}

/// How [pickVideoFrameSource] obtains the clip's absolute path.
///
/// A replaceable function rather than a direct call, for the same reason `video_import_io.dart`'s
/// seam exists and not as a convenience: the real dialog reaches `GetOpenFileNameW` through
/// `package:file_picker`'s Windows backend, so calling it from a test would open a modal window on
/// the machine running the suite and wait for a human. Every test drives this seam, never the
/// default.
typedef VideoFrameSourcePicker = Future<String?> Function();

/// The picker [pickVideoFrameSource] calls. Replaced by tests.
VideoFrameSourcePicker videoFrameSourcePicker = pickVideoFile;

/// Opens the clip dialog and returns what the user chose, or null when they dismissed it.
///
/// The same dialog and the same container list video import opens (`video_file_dialog_io.dart`),
/// which is what keeps a clip the import accepted from being one this report cannot re-open.
Future<VideoFrameSource?> pickVideoFrameSource() async {
  final path = await videoFrameSourcePicker();
  if (path == null) {
    return null; // Cancelled.
  }
  return VideoFrameSource.forPath(path);
}

/// The clip's time axis, read off its decoded frames by the runner. See [VideoFrameTimeline].
///
/// Slow enough to need saying: it opens the file and decodes its head, and for a clip whose frames
/// never advance in time it decodes the whole clip once to establish that (which is the answer
/// [VideoFrameTimeline.hasMediaTimeline] carries). Call it once per chosen file, not per redraw.
Future<VideoFrameTimeline> probeVideoFrames(VideoFrameSource source) async {
  final reply = await _invoke(
    () => PlatformChannel.probeVideoFrames(encodeVideoFrameProbeRequest(source.path)),
    'probe ${source.name}',
  );
  return videoFrameTimelineFromWire(reply);
}

/// Writes the frame displayed at [timeMs] to [destination] as a PNG and reports which frame it was.
///
/// [destination] is chosen by the caller and the runner writes exactly there — the shape
/// `takeScreenshot` already has on both front ends. The caller therefore owns the file, and its
/// deletion, from before the call is even made.
///
/// [timeMs] should already have been put through [VideoFrameTimeline.clampToSelectable]; the
/// producer clamps as well, so an out-of-range time returns the nearest frame rather than failing,
/// and [GrabbedVideoFrame.mediaTsMs] is then what says which frame that was.
Future<GrabbedVideoFrame> grabVideoFrame({
  required VideoFrameSource source,
  required int timeMs,
  required FilePath destination,
}) async {
  final reply = await _invoke(
    () => PlatformChannel.grabVideoFrame(
      encodeVideoFrameGrabRequest(path: source.path, timeMs: timeMs, outputPath: destination.path),
    ),
    'grab ${source.name} at ${timeMs}ms',
  );
  return grabbedVideoFrameFromWire(reply, png: destination, requestedMs: timeMs);
}

/// Runs one channel call, turning every way it can fail into the one type this facade throws.
///
/// **Not a table of causes.** The runner's message is passed through verbatim, because the side that
/// knows why the decode failed is the side that wrote it; a Dart-side classification would be a
/// second list that stops matching the first the next time a cause is added. [what] names the
/// request so a log line says which call failed without the caller having to add that itself.
///
/// The non-Windows branch is here rather than left to the channel: on a target with no handler the
/// invocation ends in `MissingPluginException`, which reads as "the app is broken" rather than as
/// "this platform has no such thing". [videoFrameGrabAvailable] answers false there, and this makes
/// a caller that ignored it fail the same way.
Future<Object?> _invoke(Future<Object?> Function() call, String what) async {
  if (!videoFrameGrabAvailable) {
    throw VideoFrameGrabException('$what: this platform has no video frame grabber');
  }
  try {
    return await call();
  } on VideoFrameGrabException {
    rethrow;
  } on PlatformException catch (error) {
    throw VideoFrameGrabException('$what: ${error.message ?? error.code}');
  } catch (error) {
    throw VideoFrameGrabException('$what: $error');
  }
}
