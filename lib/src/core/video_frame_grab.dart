/// Compile-time-selected "one frame out of a video file" front end.
///
/// This is the part of the **video-import error report** that gets the evidence: the user could not
/// show the developer the moment the recogniser got it wrong the way live capture lets them (there
/// is no screen to point at), so they scrub the clip and pick the frame themselves. What crosses to
/// Sentry afterwards is that one PNG, not the clip.
///
/// Mirrors `video_import.dart` and `platform_channel.dart`: the stub stays as the **default** leg —
/// what an environment matching neither condition gets — `dart.library.io` resolves to the Windows
/// implementation over the method channel, and `dart.library.js_interop` to the web one. The split is
/// a conditional export rather than a `kIsWeb` branch so neither build compiles the other's glue.
///
/// **The surface every leg exposes**, and which the shared UI is written against:
///
/// ```dart
/// bool get videoFrameGrabAvailable;
/// Future<VideoFrameSource?> pickVideoFrameSource();
/// Future<VideoFrameTimeline> probeVideoFrames(VideoFrameSource source);
/// Future<GrabbedVideoFrame> grabVideoFrame({
///   required VideoFrameSource source,
///   required int timeMs,
///   required FilePath destination,
/// });
/// class VideoFrameSource { String get name; }
/// ```
///
/// The two operations are the ones this feature needs; [VideoFrameSource] and the picker exist
/// because **what a clip *is* differs by platform and nothing else here may**. On io a clip is an
/// absolute path (the runner opens it with `cv::VideoCapture`); in a browser it is a `File` handle
/// (mediabunny reads it through a ranged `BlobSource`). Neither can be spelled in shared code, and
/// neither may be materialised into bytes — a screen recording is routinely gigabytes. So the handle
/// is opaque and leg-defined, exactly as `PlatformChannel` itself is, and the only way to obtain one
/// is the leg's own dialog. That also keeps the settled rule ("the dialog always asks the user to
/// pick a file") from needing any retained clip state anywhere.
///
/// **Both operations are asynchronous because they are slow, not because a channel happens to be.**
/// One grab costs 60-450 ms on the clips measured here, and a probe additionally opens the file
/// (19-127 ms). A front end therefore drives this from a debounced control, never per slider frame.
///
/// **A front end has two ways of choosing a time, and they must be throttled differently.** The
/// dialog's slider is the debounced one above: a drag emits a position every ~16 ms, and only the
/// last one within the debounce is asked for, because the intermediate positions name places the
/// user has already scrolled past. Its frame-step buttons are not debounced and must not be
/// coalesced: a press means "one frame on from the frame I am looking at", the time to ask for is
/// only known once the previous reply has landed (it travels as
/// [GrabbedVideoFrame.nextMediaTsMs]), and collapsing presses would perform one step for three of
/// them. Presses are therefore queued and issued one grab at a time — still never more than one in
/// flight, which is the property this paragraph is really about.
///
/// The value types, the wire format and the contract they all obey live in
/// `video_frame_grab_ops.dart`, outside the export, because the shared UI holds them.
library;

export 'video_frame_grab_stub.dart'
    if (dart.library.io) 'video_frame_grab_io.dart'
    if (dart.library.js_interop) 'video_frame_grab_web.dart';
