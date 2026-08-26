// Tests for DetailCropReportThrottle, the rate limit on the detail-crop calibration notification.
//
// Three rules are pinned here, each of which the settings page depends on: the plain interval, the
// deliberate bypass on a change of `latched` (the final frozen value must never be dropped), and the reset
// at session start (without it a session begun shortly after the previous one loses its first report, and
// the tracker's own change-dedup then keeps the page on a stale value indefinitely).
//
// The clock is injected, so none of this waits on real time.

#include <doctest/doctest.h>

#include <chrono>

#include "core/detail_crop_report_throttle.h"

namespace uma::app {
namespace {

using std::chrono::milliseconds;
using clock = DetailCropReportThrottle::clock;

constexpr auto kInterval = milliseconds(1000);

// An arbitrary but fixed origin, deliberately NOT clock::time_point{}: a throttle must not depend on how
// far the clock's epoch happens to be from "now".
const clock::time_point kStart = clock::time_point{} + std::chrono::hours(3);

TEST_CASE("the first report always passes") {
    DetailCropReportThrottle throttle(kInterval);

    CHECK(throttle.shouldReport(false, kStart));
}

TEST_CASE("a second report within the interval is dropped, and one past it is not") {
    DetailCropReportThrottle throttle(kInterval);
    REQUIRE(throttle.shouldReport(false, kStart));

    CHECK_FALSE(throttle.shouldReport(false, kStart + milliseconds(1)));
    CHECK_FALSE(throttle.shouldReport(false, kStart + milliseconds(999)));
    // THE BOUNDARY ITSELF, pinned in the same style as test_native_api_preview.cpp does for the preview rate
    // limit. 999 and 1001 alone leave one instant undecided, and it is exactly the instant that separates the
    // implementation from its likeliest mutation: `elapsed < interval` drops and `elapsed <= interval` drops
    // one more, and both agree everywhere except here. An elapsed interval is over, so this one reports.
    CHECK(throttle.shouldReport(false, kStart + kInterval));
    // ...and that one restarts the window.
    CHECK_FALSE(throttle.shouldReport(false, kStart + kInterval + milliseconds(1)));
    CHECK(throttle.shouldReport(false, kStart + kInterval + kInterval));
}

TEST_CASE("a dropped report does not restart the window") {
    // Otherwise a per-frame stream of changing rects would push the next allowed report out forever.
    DetailCropReportThrottle throttle(kInterval);
    REQUIRE(throttle.shouldReport(false, kStart));

    for (int ms = 100; ms < 1000; ms += 100) {
        CHECK_FALSE(throttle.shouldReport(false, kStart + milliseconds(ms)));
    }
    CHECK(throttle.shouldReport(false, kStart + milliseconds(1001)));
}

TEST_CASE("a change of latched bypasses the interval, in both directions") {
    DetailCropReportThrottle throttle(kInterval);
    REQUIRE(throttle.shouldReport(false, kStart));

    // The latch: the value the user is waiting for, arriving immediately after the last measurement.
    CHECK(throttle.shouldReport(true, kStart + milliseconds(1)));
    // Still throttled while it stays latched.
    CHECK_FALSE(throttle.shouldReport(true, kStart + milliseconds(2)));
    // And the release back to unlatched is just as much a state change.
    CHECK(throttle.shouldReport(false, kStart + milliseconds(3)));
}

TEST_CASE("reset lets the next report through whatever its timing and latch state") {
    // This is the session-start behaviour: a new session's first report must never be dropped for having
    // landed within an interval of the previous session's last one.
    DetailCropReportThrottle throttle(kInterval);
    REQUIRE(throttle.shouldReport(false, kStart));
    REQUIRE_FALSE(throttle.shouldReport(false, kStart + milliseconds(10)));

    throttle.reset();

    CHECK(throttle.shouldReport(false, kStart + milliseconds(11)));
}

TEST_CASE("reset also clears the remembered latch state") {
    DetailCropReportThrottle throttle(kInterval);
    REQUIRE(throttle.shouldReport(true, kStart));

    throttle.reset();

    // A fresh session starts unlatched; that first report passes on its own merits, not because the latch
    // appears to have changed.
    CHECK(throttle.shouldReport(true, kStart + milliseconds(1)));
}

}  // namespace
}  // namespace uma::app
