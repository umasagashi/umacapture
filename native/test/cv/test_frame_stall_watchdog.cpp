// Behavioral tests for the FrameStallWatchdog stall-decision debounce.
//
// The watchdog polls a steady clock on a worker thread and fires a callback once the frame stream stops
// for longer than the timeout. The timing-sensitive latch logic -- fire once on the transition into a
// stall, rearm only after frames resume -- is factored into the static shouldFire() so it can be driven
// here with synthetic elapsed durations, deterministically and without spinning up the poll thread or
// waiting on the real clock.

#include <doctest/doctest.h>

#include <chrono>

#include "cv/frame_stall_watchdog.h"

namespace uma::distributor {
namespace {

using namespace std::chrono_literals;
using Watchdog = FrameStallWatchdog;

TEST_CASE("shouldFire stays quiet while frames keep arriving under the timeout") {
    bool stalled = false;
    CHECK_FALSE(Watchdog::shouldFire(50ms, 100ms, stalled));
    CHECK_FALSE(stalled);
}

TEST_CASE("shouldFire fires once on the transition into a stall, then stays latched") {
    bool stalled = false;

    // First over-timeout poll fires and latches.
    CHECK(Watchdog::shouldFire(150ms, 100ms, stalled));
    CHECK(stalled);

    // Subsequent over-timeout polls do not re-fire while still stalled.
    CHECK_FALSE(Watchdog::shouldFire(150ms, 100ms, stalled));
    CHECK_FALSE(Watchdog::shouldFire(500ms, 100ms, stalled));
    CHECK(stalled);
}

TEST_CASE("shouldFire rearms once frames resume, then can fire again") {
    bool stalled = false;
    REQUIRE(Watchdog::shouldFire(150ms, 100ms, stalled));  // stalled

    // A sub-timeout gap means frames resumed: rearm without firing.
    CHECK_FALSE(Watchdog::shouldFire(10ms, 100ms, stalled));
    CHECK_FALSE(stalled);

    // A fresh stall after rearming fires again.
    CHECK(Watchdog::shouldFire(150ms, 100ms, stalled));
    CHECK(stalled);
}

TEST_CASE("shouldFire treats an exactly-timeout gap as a stall") {
    bool stalled = false;
    CHECK(Watchdog::shouldFire(100ms, 100ms, stalled));  // elapsed >= timeout
    CHECK(stalled);
}

}  // namespace
}  // namespace uma::distributor
