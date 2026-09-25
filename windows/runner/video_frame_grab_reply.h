#pragma once

#include "cv/video_frame_grabber.h"
#include "util/json_util.h"

namespace uma::windows {

// The success answer to a video frame grab, in the shape the method channel carries back to Dart
// (VideoFrameGrabService::serveGrab dumps it; lib/src/core/video_frame_grab_ops.dart parses it on both front ends).
//
// Kept free of any Flutter type, like runner/method_argument.h, so the wire shape is unit tested
// (native/test/runner/test_video_frame_grab_reply.cpp) instead of only being compiled into the runner.
//
// mediaTsMs is in the answer because it is what a report must quote. The requested time and the frame's own time
// differ by up to one frame interval by construction -- "the frame displayed at T" is the last frame at or before
// T -- and by more when the request was out of range and the grabber clamped it.
//
// nextMediaTsMs is in the answer because it is the ONE neighbour the contract cannot express. "The previous frame"
// is grabAt(mediaTsMs - 1) on an integer-millisecond wire and needs no field; "the next frame" is not derivable from
// any answer at all (video_frame_grabber.h's class comment states the asymmetry in full), so the producer states it.
// The key is OMITTED, never sent as 0 or null, when the frame is the clip's last: that is the same
// absent-means-not-there convention seekBackoffMs / decodedFrames already use on the web leg, and
// lib/src/core/video_frame_grab_ops.dart reads an absent field as null on both.
[[nodiscard]] inline json_util::Json videoFrameGrabReply(const video::GrabbedFrame &grabbed) {
    json_util::Json reply{
        {"mediaTsMs", grabbed.media_ts_ms},
        {"seekBackoffMs", grabbed.seek_backoff_ms},
        {"decodedFrames", grabbed.decoded_frames},
    };
    if (grabbed.next_media_ts_ms.has_value()) {
        reply["nextMediaTsMs"] = grabbed.next_media_ts_ms.value();
    }
    return reply;
}

}  // namespace uma::windows
