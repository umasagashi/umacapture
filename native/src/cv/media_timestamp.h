#pragma once

#include <cmath>
#include <cstdint>
#include <optional>

namespace uma::media {

// The media-time stamping rule every OFFLINE producer that reads an arbitrary container must follow, in one
// place so the CLI's `video` path and the browser's video import cannot drift apart.
//
// WHY IT IS SHARED RATHER THAN RESTATED. .claude/rules/platform-parity.md's "share, don't port": web reaches
// this by compiling the same core to wasm, so a clip that stamps one way on the CLI stamps the same way in the
// browser. The web export used to spell it `static_cast<uint64>(ms)` -- no rounding, no clamp, no validation --
// while claiming in its own comment to stamp "exactly as video_loader.h". It did not, and the difference was
// exactly the class of clip this class exists for.
//
// WHAT IT ENFORCES, and why each part is load-bearing rather than defensive:
//
//   * MONOTONIC. Some containers/codecs report a timestamp of 0 (or a lower one) mid-stream. Every gate
//     downstream advances on Frame::timestamp() and nothing counts frames -- the 200 ms scene-begin dwell, the
//     1000 ms scene-end debounce, the 250 ms switch/reset monitors, StationaryFrameCatcher's 200 ms -- so a
//     rewind un-does a debounce that was nearly satisfied, and the scene never ends. Clamping loses nothing a
//     rewind was going to deliver: the frames still arrive, in order, and are still separated by the deltas the
//     clip actually has once it resumes climbing.
//   * ROUNDED, not truncated. The pipeline's unit is a whole millisecond; truncation biases every stamp
//     downward by up to 1 ms, which at 30 fps is ~3 % of a frame interval, systematically.
//   * VALIDATED. The stamp ends up in an unsigned integer. A negative double converts with undefined behaviour
//     there, and NaN/infinity is undefined for llround as well, so both are handled BEFORE the conversion
//     rather than after -- a caller cannot inspect a value that has already gone through UB.
//
// WHAT IT DELIBERATELY DOES NOT DO: invent a stride for a clip whose every frame reports 0. The clamp collapses
// such a clip to a single instant and the debounce never advances, so the clip is unsupported -- loudly, as a
// capture that produces nothing, rather than quietly as a wrong record. Synthesizing a stride from the declared
// frame rate would be a way to support it, and is not attempted here because no such clip is in use.
//
// NOT USED BY Ffv1Reader, on purpose. That reader replays a container THIS PROJECT WROTE, whose PTS is
// monotonic by construction; it floors a negative PTS at 0 and states that reason at its own call site. The
// symmetry that matters between the two offline CLI producers is the shaping contract, and this changes none
// of it.
class MonotonicMediaClock {
public:
    // Rounds `ms` to whole milliseconds and clamps the result to be non-decreasing across calls. Returns the
    // stamp to use, or nullopt when `ms` cannot be a media time at all (NaN or infinity) -- which is a broken
    // container or a caller defect, and is worth refusing the frame over rather than papering into 0.
    [[nodiscard]] std::optional<int64_t> advance(const double ms) {
        if (!std::isfinite(ms)) {
            return std::nullopt;
        }
        // Bounded BEFORE llround, which is undefined for a value outside the destination's range. The ceiling is
        // ~31,700 years of milliseconds: unreachable by any clip, and far enough inside int64 that the later
        // additions a caller may make (VideoLoader's head_ts, for a concatenated batch) cannot overflow either.
        const double bounded = ms < 0.0 ? 0.0 : (ms > kMaxMilliseconds ? kMaxMilliseconds : ms);
        const auto rounded = static_cast<int64_t>(std::llround(bounded));
        if (rounded > last_) {
            last_ = rounded;
        }
        return last_;
    }

    // The highest stamp issued so far; 0 before the first one.
    [[nodiscard]] int64_t last() const { return last_; }

    // Back to the start of a clip. A process-lifetime clock (the wasm export holds one) must do this when a new
    // import begins, or the second clip's stamps would all be clamped up to the first clip's last one and every
    // dwell in the pipeline would see a single frozen instant.
    void reset() { last_ = 0; }

private:
    static constexpr double kMaxMilliseconds = 1.0e15;

    int64_t last_ = 0;
};

}  // namespace uma::media
