/// Default-leg stub of `video_frame_grab.dart`: this front end cannot pull a frame out of a clip, so
/// the video-import error report offers nothing at all here. A real answer read at runtime, not a
/// placeholder — the same rule `video_import_stub.dart` and `capture_capability_stub.dart` state.
///
/// **Which targets actually land here is narrower than "desktop".** The conditional export sends
/// anything with `dart.library.io` to `video_frame_grab_io.dart`, which answers `Platform.isWindows`,
/// and web to `video_frame_grab_web.dart`. This leg is the default one — an environment matching
/// neither condition — and the io leg answers exactly the same "no" on every non-Windows io target.
///
/// The three operations **throw [UnsupportedError]** rather than returning something empty. There is
/// no empty value that is not a lie: a timeline has to state a size and a grab has to name a file
/// that exists, and inventing either would send the developer a report about pixels nobody ever
/// decoded. [UnsupportedError] and not [UnimplementedError], which is what the web leg throws while
/// it is being written: this leg is not unfinished, it is a front end that has no such capability.
library;

import 'package:flutter/foundation.dart';

import '/src/core/path_entity.dart';
import '/src/core/video_frame_grab_ops.dart';

/// Stub: nothing here can decode a clip.
bool get videoFrameGrabAvailable => false;

/// A clip this front end could be asked for frames of, if it could decode one.
///
/// Present only so this leg keeps the same API surface as the other two, which is what lets the
/// shared UI be written once against one spelling.
@immutable
class VideoFrameSource {
  const VideoFrameSource.unsupported(this.name);

  /// The chosen file's name, for a label.
  final String name;
}

/// Stub: there is no dialog to open, because nothing could be done with the answer.
Future<VideoFrameSource?> pickVideoFrameSource() {
  throw UnsupportedError('this front end has no video frame grabber');
}

/// Stub: see [pickVideoFrameSource].
Future<VideoFrameTimeline> probeVideoFrames(VideoFrameSource source) {
  throw UnsupportedError('this front end has no video frame grabber');
}

/// Stub: see [pickVideoFrameSource].
Future<GrabbedVideoFrame> grabVideoFrame({
  required VideoFrameSource source,
  required int timeMs,
  required FilePath destination,
}) {
  throw UnsupportedError('this front end has no video frame grabber');
}
