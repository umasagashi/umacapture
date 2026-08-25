// Contract test for the shared live-preview policy.
//
// The live preview used to be implemented twice, end to end and in two languages: once here in C++ (for
// Windows) and once by hand in JavaScript (web/worker.js, for the browser). Five decisions were duplicated --
// the enable gate, the expected-vs-actual pane agreement gate, the 200 ms throttle, the fit geometry and the
// staleness re-check -- and both copies carried a "keep them identical" comment, which is the shape of a rule
// that a test cannot enforce. They are now LivePreviewPolicy, once, reached by the browser through wasm
// (native/wasm/wasm_api.cpp exports setPreviewEnabled and the sink), and these cases pin all five answers.
//
// Nothing here builds a pipeline, a producer or a display surface: the policy is pure plus one relaxed atomic.
//
// NOTE ON COVERAGE. Two gaps, both deliberate and neither hidden:
//   * The golden integration suite does NOT exercise the preview at all -- it drives the CLI, which has no
//     display surface and never turns the preview on. These cases are the only automated detection this
//     behaviour has (.claude/rules/platform-parity.md, "test gap").
//   * The EMISSION itself (NativeApi::emitPreviewFrame: the pyramid pre-pass, the final INTER_AREA resize to
//     fitSize, the BGR -> BGRA conversion and the transport copy) is not reachable from this target. It lives
//     in native_api.cpp, which the test executable deliberately does not link -- that TU builds the whole
//     recognition pipeline. What IS pinned here is every decision that function consults; binding fitSize to
//     the pixel dimensions actually emitted would need emitPreviewFrame split into its own translation unit.

#include <doctest/doctest.h>

#include <chrono>

#include "core/native_api.h"
#include "types/shape.h"

namespace uma::app {

namespace {

using Clock = LivePreviewPolicy::Clock;

// ---------------------------------------------------------------------------
// Decision 1: the enable gate.
// ---------------------------------------------------------------------------

TEST_CASE("nothing is emitted while the preview is off, whatever else agrees") {
    LivePreviewPolicy policy;
    const auto now = Clock::now();

    // Default state: off. Both pane states, and a throttle window that has long since elapsed.
    CHECK_FALSE(policy.shouldEmit(policy.state(), false, now));
    CHECK_FALSE(policy.shouldEmit(policy.state(), true, now));

    // Explicitly off, with the cropped bit set: still off. The enable bit is the only term that can open it.
    policy.set(false, true);
    CHECK_FALSE(policy.shouldEmit(policy.state(), true, now));
    CHECK_FALSE(LivePreviewPolicy::isEnabled(policy.state()));

    policy.set(true, false);
    CHECK(policy.shouldEmit(policy.state(), false, now));
}

TEST_CASE("the packed state carries both bits independently") {
    CHECK_FALSE(LivePreviewPolicy::isEnabled(LivePreviewPolicy::pack(false, false)));
    CHECK_FALSE(LivePreviewPolicy::expectsCropped(LivePreviewPolicy::pack(false, false)));
    CHECK(LivePreviewPolicy::isEnabled(LivePreviewPolicy::pack(true, false)));
    CHECK_FALSE(LivePreviewPolicy::expectsCropped(LivePreviewPolicy::pack(true, false)));
    CHECK_FALSE(LivePreviewPolicy::isEnabled(LivePreviewPolicy::pack(false, true)));
    CHECK(LivePreviewPolicy::expectsCropped(LivePreviewPolicy::pack(false, true)));
    CHECK(LivePreviewPolicy::isEnabled(LivePreviewPolicy::pack(true, true)));
    CHECK(LivePreviewPolicy::expectsCropped(LivePreviewPolicy::pack(true, true)));

    // The four packings must be four distinct tokens: the staleness check compares the packed value, so an
    // aliasing pack() would make a real preference change look like no change at all.
    CHECK(LivePreviewPolicy::pack(false, false) != LivePreviewPolicy::pack(true, false));
    CHECK(LivePreviewPolicy::pack(false, false) != LivePreviewPolicy::pack(false, true));
    CHECK(LivePreviewPolicy::pack(true, false) != LivePreviewPolicy::pack(true, true));
    CHECK(LivePreviewPolicy::pack(false, true) != LivePreviewPolicy::pack(true, true));
}

// ---------------------------------------------------------------------------
// Decision 2: the expected-vs-actual pane agreement gate.
// ---------------------------------------------------------------------------

TEST_CASE("a frame whose pane state disagrees with the UI's expectation is not emitted") {
    LivePreviewPolicy policy;
    const auto now = Clock::now();

    // The UI expects a full frame; the producer has latched and is sending pane pixels.
    policy.set(true, false);
    CHECK_FALSE(policy.shouldEmit(policy.state(), true, now));

    // The UI expects the pane; the producer has released and is sending the whole capture.
    policy.set(true, true);
    CHECK_FALSE(policy.shouldEmit(policy.state(), false, now));

    // Agreement, either way round.
    CHECK(policy.shouldEmit(policy.state(), true, now));
    policy.set(true, false);
    CHECK(policy.shouldEmit(policy.state(), false, now));
}

TEST_CASE("a disagreeing frame does not consume the throttle window") {
    LivePreviewPolicy policy;
    policy.set(true, true);
    const auto now = Clock::now();

    // A mismatch is a drop, not an emission: nothing calls noteEmitted, so the very next agreeing frame -- at
    // the SAME instant -- still publishes. Charging the window to a mismatch would make the preview wait out a
    // 200 ms window that showed nothing, once per latch transition.
    REQUIRE_FALSE(policy.shouldEmit(policy.state(), false, now));
    CHECK(policy.shouldEmit(policy.state(), true, now));
}

// ---------------------------------------------------------------------------
// Decision 3: the throttle (drop semantics, never a queue).
// ---------------------------------------------------------------------------

TEST_CASE("the first frame of a session is never made to wait") {
    LivePreviewPolicy policy;
    policy.set(true, false);
    // The emission clock is default-constructed, i.e. no emission has ever happened. A policy that compared
    // against "now minus nothing" would swallow the first frame and leave the tile blank for 200 ms.
    CHECK(policy.shouldEmit(policy.state(), false, Clock::now()));
}

TEST_CASE("emissions are throttled to one per interval, dropping everything in between") {
    LivePreviewPolicy policy;
    policy.set(true, false);
    const auto start = Clock::now();
    REQUIRE(policy.shouldEmit(policy.state(), false, start));
    policy.noteEmitted(start);

    // Inside the window: dropped, including at the exact boundary (the comparison is strictly greater).
    CHECK_FALSE(policy.shouldEmit(policy.state(), false, start));
    CHECK_FALSE(policy.shouldEmit(policy.state(), false, start + std::chrono::milliseconds(1)));
    CHECK_FALSE(policy.shouldEmit(policy.state(), false, start + LivePreviewPolicy::interval));

    // Past the window: published, and the window then restarts from THAT instant rather than from the
    // previous one -- so a late frame does not immediately license a second emission.
    const auto next = start + LivePreviewPolicy::interval + std::chrono::milliseconds(1);
    CHECK(policy.shouldEmit(policy.state(), false, next));
    policy.noteEmitted(next);
    CHECK_FALSE(policy.shouldEmit(policy.state(), false, next + std::chrono::milliseconds(1)));
    CHECK(policy.shouldEmit(policy.state(), false, next + LivePreviewPolicy::interval + std::chrono::milliseconds(1)));
}

TEST_CASE("the emission cadence is 200 ms") {
    // Pinned deliberately: this number used to be written twice (here and as PREVIEW_INTERVAL_MS in
    // web/worker.js), and a silent divergence would give the two platforms different preview frame rates.
    CHECK(LivePreviewPolicy::interval == std::chrono::milliseconds(200));
}

// ---------------------------------------------------------------------------
// Decision 4: the fit geometry.
// ---------------------------------------------------------------------------

TEST_CASE("the preview box is 576 x 320 and is defined exactly once") {
    CHECK(LivePreviewPolicy::max_width == 576);
    CHECK(LivePreviewPolicy::target_height == 320);
}

TEST_CASE("a source that already fits is never upscaled") {
    // Strictly smaller on both axes, and exactly the box, and smaller on one axis only.
    CHECK(LivePreviewPolicy::fitSize({100, 100}) == Size<int>{100, 100});
    CHECK(LivePreviewPolicy::fitSize({576, 320}) == Size<int>{576, 320});
    CHECK(LivePreviewPolicy::fitSize({576, 1}) == Size<int>{576, 1});
    CHECK(LivePreviewPolicy::fitSize({1, 320}) == Size<int>{1, 320});
}

TEST_CASE("a downscale preserves the aspect ratio and binds on whichever axis is tighter") {
    // Portrait: the height binds. This is the measured shape from the cost probe in native_api.cpp.
    CHECK(LivePreviewPolicy::fitSize({737, 1310}) == Size<int>{180, 320});
    // Landscape 16:9: the height still binds (576 is just above 16:9 at 320 px), so the width lands under the
    // cap rather than on it.
    CHECK(LivePreviewPolicy::fitSize({1920, 1080}) == Size<int>{569, 320});
    // Wider than 16:9: the width cap binds instead. This is the case the cap exists for -- a full-frame
    // landscape preview before pane mode latches.
    CHECK(LivePreviewPolicy::fitSize({3840, 1080}) == Size<int>{576, 162});
    // Square: the height binds, and the output stays square.
    CHECK(LivePreviewPolicy::fitSize({1000, 1000}) == Size<int>{320, 320});

    // Neither axis may ever exceed the box.
    for (const Size<int> source : {Size<int>{737, 1310}, Size<int>{1920, 1080}, Size<int>{3840, 1080},
                                   Size<int>{1000, 1000}, Size<int>{4000, 3}, Size<int>{3, 4000}}) {
        const auto fit = LivePreviewPolicy::fitSize(source);
        CHECK(fit.width() <= LivePreviewPolicy::max_width);
        CHECK(fit.height() <= LivePreviewPolicy::target_height);
        CHECK(fit.width() >= 1);
        CHECK(fit.height() >= 1);
    }
}

TEST_CASE("an extreme aspect ratio is clamped to at least one pixel on the bound axis") {
    // 100000 x 1 scales its height to 0.00576 px. Rounding that to 0 would produce an empty image, which is
    // neither something OpenCV can resize into nor something the transport can carry.
    CHECK(LivePreviewPolicy::fitSize({100000, 1}) == Size<int>{576, 1});
    CHECK(LivePreviewPolicy::fitSize({1, 100000}) == Size<int>{1, 320});
}

TEST_CASE("a degenerate source size is returned untouched rather than turned into a scale by zero") {
    CHECK(LivePreviewPolicy::fitSize({0, 0}) == Size<int>{0, 0});
    CHECK(LivePreviewPolicy::fitSize({0, 1000}) == Size<int>{0, 1000});
    CHECK(LivePreviewPolicy::fitSize({1000, 0}) == Size<int>{1000, 0});
}

// ---------------------------------------------------------------------------
// Decision 5: the staleness re-check.
// ---------------------------------------------------------------------------

TEST_CASE("a result built for a state that no longer holds is stale") {
    LivePreviewPolicy policy;
    policy.set(true, false);
    const auto observed = policy.state();
    CHECK(policy.isCurrent(observed));

    // Turned off mid-build.
    policy.set(false, false);
    CHECK_FALSE(policy.isCurrent(observed));

    // Turned back on with the SAME expectation: not stale. The pixels still answer the question being asked,
    // and dropping them would cost a frame for nothing.
    policy.set(true, false);
    CHECK(policy.isCurrent(observed));

    // The expectation flipped mid-build: stale, even though the preview is still on.
    policy.set(true, true);
    CHECK_FALSE(policy.isCurrent(observed));
}

// ---------------------------------------------------------------------------
// The five decisions together, over the sequence a real session produces.
// ---------------------------------------------------------------------------

TEST_CASE("a latch transition suppresses the preview and then resumes it without losing a window") {
    // The sequence that used to be reproduced by hand in JavaScript, walked end to end: the preview is on and
    // agreeing, the producer latches a pane, the UI's expectation catches up one beat later.
    LivePreviewPolicy policy;
    policy.set(true, false);
    const auto t0 = Clock::now();

    // A full frame, as expected: published.
    REQUIRE(policy.shouldEmit(policy.state(), false, t0));
    policy.noteEmitted(t0);

    // The producer latches. The UI still expects a full frame, so every frame is suppressed -- for as long as
    // the disagreement lasts, and without ever consuming a window.
    const auto t1 = t0 + std::chrono::milliseconds(300);
    CHECK_FALSE(policy.shouldEmit(policy.state(), true, t1));
    CHECK_FALSE(policy.shouldEmit(policy.state(), true, t1 + std::chrono::milliseconds(33)));

    // The UI catches up. The very next frame publishes: the throttle is still measured from t0, which really
    // did publish something.
    policy.set(true, true);
    const auto t2 = t1 + std::chrono::milliseconds(66);
    CHECK(policy.shouldEmit(policy.state(), true, t2));
    policy.noteEmitted(t2);

    // And the emission that was in flight across the UI's change is stale, so it is dropped rather than
    // published as a pane frame the UI would lay out as a full one.
    CHECK_FALSE(policy.isCurrent(LivePreviewPolicy::pack(true, false)));
    CHECK(policy.isCurrent(LivePreviewPolicy::pack(true, true)));
}

}  // namespace

}  // namespace uma::app
