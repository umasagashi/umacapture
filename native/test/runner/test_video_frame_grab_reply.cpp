// Tests for the Windows runner's video frame grab answer (windows/runner/video_frame_grab_reply.h): which fields of a
// grabbed frame go on the method channel, under which keys, and when a key is left out.
//
// The report dialog's forward step is enabled by `nextMediaTsMs` and asks for exactly that time, so a reply that
// drops or renames the key disables the button on Windows only, and a reply that states the key at the clip's
// tail offers a step into nothing. Which frame the grabber picks is test_video_frame_grabber.cpp's subject; this
// file starts from a GrabbedFrame and pins only the wire shape built from it.

#include <doctest/doctest.h>

#include <optional>

#include "runner/video_frame_grab_reply.h"

namespace uma::windows {
namespace {

video::GrabbedFrame grabbedAt(const int64 media_ts_ms, const std::optional<int64> next_media_ts_ms) {
    video::GrabbedFrame grabbed;
    grabbed.status = video::GrabStatus::Ok;
    grabbed.media_ts_ms = media_ts_ms;
    grabbed.next_media_ts_ms = next_media_ts_ms;
    grabbed.seek_backoff_ms = 2000;
    grabbed.decoded_frames = 61;
    return grabbed;
}

TEST_CASE("a grab with a successor states the successor's time under nextMediaTsMs") {
    // 116 -> 1421 is the 1305 ms variable-frame-rate gap the Dart dialog test steps across: the value has to be
    // the stated stamp itself, not anything derived from the frame on screen.
    const auto reply = videoFrameGrabReply(grabbedAt(116, 1421));

    REQUIRE(reply.contains("nextMediaTsMs"));
    CHECK(reply.at("nextMediaTsMs").get<int64>() == 1421);
    CHECK(reply.at("mediaTsMs").get<int64>() == 116);
    CHECK(reply.at("seekBackoffMs").get<int64>() == 2000);
    CHECK(reply.at("decodedFrames").get<int>() == 61);
    CHECK(reply.size() == 4);
}

TEST_CASE("a grab of the clip's last frame omits nextMediaTsMs rather than sending null or 0") {
    const auto reply = videoFrameGrabReply(grabbedAt(1454, std::nullopt));

    CHECK_FALSE(reply.contains("nextMediaTsMs"));
    CHECK(reply.at("mediaTsMs").get<int64>() == 1454);
    CHECK(reply.at("seekBackoffMs").get<int64>() == 2000);
    CHECK(reply.at("decodedFrames").get<int>() == 61);
    CHECK(reply.size() == 3);
}

TEST_CASE("a successor at 0 ms is still stated: presence follows the optional, not the value") {
    // Guards the omission from being written as a zero test. The grabber never produces a successor at or
    // below mediaTsMs, so this pins the rule rather than a reachable clip.
    const auto reply = videoFrameGrabReply(grabbedAt(0, 0));

    REQUIRE(reply.contains("nextMediaTsMs"));
    CHECK(reply.at("nextMediaTsMs").get<int64>() == 0);
}

}  // namespace
}  // namespace uma::windows
