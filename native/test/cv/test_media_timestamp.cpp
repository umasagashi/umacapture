// Tests for MonotonicMediaClock, the media-time stamping rule shared by the two offline producers that read an
// arbitrary container: the CLI's `video` path (cv/video_loader.h) and the browser's video import
// (native/wasm/wasm_api.cpp's pushOfflineFrame).
//
// Why it is worth pinning. Every gate in the recognition pipeline advances on Frame::timestamp() and none of
// them counts frames -- the 200 ms scene-begin dwell, the 1000 ms scene-end debounce, the 250 ms switch/reset
// monitors, StationaryFrameCatcher's 200 ms. So a stamp that rewinds does not merely look wrong: it un-does a
// debounce that was nearly satisfied, and the scene never ends. The web export previously did a bare
// static_cast<uint64> of the raw double -- no rounding, no clamp, no validation -- while its own comment claimed
// it stamped a clip exactly as the CLI did. The point of a shared class is that such a claim becomes structural;
// the point of these tests is that the shared behaviour is the CORRECT one on both sides at once.

#include <doctest/doctest.h>

#include <cmath>
#include <limits>

#include "cv/media_timestamp.h"

namespace uma::media {
namespace {

TEST_CASE("a fresh clock starts at zero") {
    MonotonicMediaClock clock;

    CHECK(clock.last() == 0);
}

TEST_CASE("an increasing clip passes through, rounded to whole milliseconds") {
    MonotonicMediaClock clock;

    // Rounded, not truncated. Truncation biases every stamp down by up to 1 ms, which at 30 fps is ~3 % of a
    // frame interval, systematically and in one direction.
    CHECK(clock.advance(0.0).value() == 0);
    CHECK(clock.advance(33.4).value() == 33);
    CHECK(clock.advance(66.7).value() == 67);
    CHECK(clock.advance(100.5).value() == 101);
    CHECK(clock.last() == 101);
}

TEST_CASE("a mid-stream zero cannot rewind the clip") {
    // The case cv/video_loader.h names: some containers/codecs report POS_MSEC == 0 mid-stream. Without the
    // clamp the scene-end debounce is thrown back to the start of the clip on every such frame.
    MonotonicMediaClock clock;
    REQUIRE(clock.advance(500.0).value() == 500);

    CHECK(clock.advance(0.0).value() == 500);
    CHECK(clock.advance(250.0).value() == 500);
    // ...and the clip resumes climbing from where it actually is, not from where the spurious frame put it.
    CHECK(clock.advance(600.0).value() == 600);
}

TEST_CASE("a negative timestamp is clamped rather than converted") {
    // The stamp ends up in an unsigned integer. A negative double converts there with undefined behaviour, so it
    // must not survive this far -- which the monotonic clamp already guarantees, since the floor is 0.
    MonotonicMediaClock clock;

    CHECK(clock.advance(-1.0).value() == 0);
    CHECK(clock.advance(-1.0e9).value() == 0);
    REQUIRE(clock.advance(400.0).value() == 400);
    CHECK(clock.advance(-5.0).value() == 400);
}

TEST_CASE("NaN and infinity are refused, not stamped") {
    // llround is undefined for these too, so they are rejected BEFORE any conversion. Refused rather than
    // coerced to 0: a 0 would look exactly like the legitimate first frame of a clip, and would then be clamped
    // away invisibly. A caller that gets nullopt can drop the frame and say why.
    MonotonicMediaClock clock;
    REQUIRE(clock.advance(120.0).value() == 120);

    CHECK_FALSE(clock.advance(std::numeric_limits<double>::quiet_NaN()).has_value());
    CHECK_FALSE(clock.advance(std::numeric_limits<double>::infinity()).has_value());
    CHECK_FALSE(clock.advance(-std::numeric_limits<double>::infinity()).has_value());
    // A refusal leaves the clock untouched, so the next good frame continues the clip normally.
    CHECK(clock.last() == 120);
    CHECK(clock.advance(150.0).value() == 150);
}

TEST_CASE("an absurdly large timestamp is bounded instead of overflowing") {
    // A value beyond the destination's range makes llround undefined, so the bound is applied first. Nothing
    // real reaches it; what matters is that a garbage container value produces a number rather than UB.
    MonotonicMediaClock clock;

    const auto huge = clock.advance(1.0e300);
    REQUIRE(huge.has_value());
    CHECK(huge.value() > 0);
    // Far enough below int64's ceiling that a caller's own additions (VideoLoader's head_ts, for a concatenated
    // batch) cannot overflow on top of it.
    CHECK(huge.value() < std::numeric_limits<int64_t>::max() / 4);
}

TEST_CASE("reset starts the next clip from the beginning") {
    // A process-lifetime clock -- which is what the wasm export holds, since the export is free-standing and
    // owns no session object -- must be reset when a new import begins. Without it, every frame of the second
    // clip is clamped up to the first clip's last stamp, collapsing the whole clip onto a single instant and
    // leaving no delta for any dwell in the pipeline to advance on.
    MonotonicMediaClock clock;
    REQUIRE(clock.advance(90000.0).value() == 90000);

    clock.reset();

    CHECK(clock.last() == 0);
    CHECK(clock.advance(0.0).value() == 0);
    CHECK(clock.advance(33.0).value() == 33);
}

}  // namespace
}  // namespace uma::media
